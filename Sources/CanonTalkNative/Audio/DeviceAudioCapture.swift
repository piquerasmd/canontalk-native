import Foundation
import CoreAudio
import AudioToolbox

/// Direct HAL input. Using one AVAudioEngine per input device can block while
/// opening the second engine, so both the microphone and BlackHole are captured
/// through independent AUHAL instances instead.
final class DeviceAudioCapture: @unchecked Sendable {
    typealias PCMHandler = @Sendable (Data, Float) -> Void

    private let queue = DispatchQueue(label: "com.canontalk.capture", qos: .userInteractive)
    private let maximumFrames = 32_768
    private var unit: AudioUnit?
    private var handler: PCMHandler?
    private var sourceSampleRate = 48_000.0
    private var channelCount = 0
    private var bufferListStorage: UnsafeMutableRawPointer?
    private var channelStorage: [UnsafeMutablePointer<Float>] = []
    private var acceptingAudio = false

    deinit {
        stop()
    }

    func start(deviceID: AudioDeviceID, handler: @escaping PCMHandler) throws {
        stop()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError.unavailable("No se encontró la unidad HAL de entrada.")
        }

        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created))
        guard let created else {
            throw CoreAudioError.unavailable("No se pudo crear la unidad HAL de entrada.")
        }

        do {
            var enabled: UInt32 = 1
            try Self.check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                1, &enabled, UInt32(MemoryLayout<UInt32>.size)
            ))

            var disabled: UInt32 = 0
            try Self.check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                0, &disabled, UInt32(MemoryLayout<UInt32>.size)
            ))

            var selectedID = deviceID
            try Self.check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &selectedID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ))

            sourceSampleRate = try Self.nominalSampleRate(deviceID)
            channelCount = try Self.inputChannelCount(deviceID)
            guard channelCount > 0 else {
                throw CoreAudioError.unavailable("El dispositivo seleccionado no tiene canales de entrada.")
            }

            var format = AudioStreamBasicDescription(
                mSampleRate: sourceSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: UInt32(channelCount),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try Self.check(AudioUnitSetProperty(
                created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ))

            allocateBuffers(channelCount: channelCount)

            var callback = AURenderCallbackStruct(
                inputProc: Self.inputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
                0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))

            try Self.check(AudioUnitInitialize(created))
            unit = created
            queue.sync {
                self.handler = handler
                acceptingAudio = true
            }
            try Self.check(AudioOutputUnitStart(created))
        } catch {
            AudioOutputUnitStop(created)
            AudioUnitUninitialize(created)
            AudioComponentInstanceDispose(created)
            unit = nil
            queue.sync {
                acceptingAudio = false
                self.handler = nil
            }
            releaseBuffers()
            throw error
        }
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        queue.sync {
            acceptingAudio = false
            handler = nil
        }
        releaseBuffers()
    }

    private func capture(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard let unit, let storage = bufferListStorage else { return noErr }
        let frames = Int(frameCount)
        guard frames <= maximumFrames else { return kAudio_ParamError }

        let bufferList = storage.assumingMemoryBound(to: AudioBufferList.self)
        for index in 0..<channelCount {
            UnsafeMutableAudioBufferListPointer(bufferList)[index].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
        }

        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, bufferList)
        guard status == noErr else { return status }

        var mono = Array(repeating: Float(0), count: frames)
        let divisor = Float(channelCount)
        for channel in channelStorage {
            for index in 0..<frames {
                mono[index] += channel[index] / divisor
            }
        }
        let sampleRate = sourceSampleRate
        queue.async { [weak self] in
            guard let self, acceptingAudio, let handler else { return }
            let pcm = Self.makePCM16(Self.resample(mono, from: sampleRate, to: PCM16.sampleRate))
            handler(pcm, PCM16.level(pcm))
        }
        return noErr
    }

    private func allocateBuffers(channelCount: Int) {
        releaseBuffers()
        self.channelCount = channelCount
        let byteCount = MemoryLayout<AudioBufferList>.size
            + max(0, channelCount - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        list.pointee.mNumberBuffers = UInt32(channelCount)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for index in 0..<channelCount {
            let channel = UnsafeMutablePointer<Float>.allocate(capacity: maximumFrames)
            channel.initialize(repeating: 0, count: maximumFrames)
            channelStorage.append(channel)
            buffers[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maximumFrames * MemoryLayout<Float>.size),
                mData: channel
            )
        }
        bufferListStorage = raw
    }

    private func releaseBuffers() {
        for channel in channelStorage {
            channel.deinitialize(count: maximumFrames)
            channel.deallocate()
        }
        channelStorage.removeAll(keepingCapacity: true)
        bufferListStorage?.deallocate()
        bufferListStorage = nil
        channelCount = 0
    }

    private static func resample(_ source: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard source.count > 1, sourceRate != targetRate else { return source }
        let ratio = targetRate / sourceRate
        let outputCount = max(1, Int(Double(source.count) * ratio))
        var output = Array(repeating: Float(0), count: outputCount)
        for index in output.indices {
            let position = Double(index) / ratio
            let lower = min(Int(position), source.count - 1)
            let upper = min(lower + 1, source.count - 1)
            let fraction = Float(position - Double(lower))
            output[index] = source[lower] + (source[upper] - source[lower]) * fraction
        }
        return output
    }

    private static func makePCM16(_ samples: [Float]) -> Data {
        var values = samples.map { sample -> Int16 in
            let clamped = max(-1, min(1, sample))
            return Int16(clamped * Float(Int16.max))
        }
        return values.withUnsafeMutableBytes { Data($0) }
    }

    private static let inputCallback: AURenderCallback = { reference, flags, timestamp, _, frames, _ in
        let capture = Unmanaged<DeviceAudioCapture>.fromOpaque(reference).takeUnretainedValue()
        return capture.capture(flags: flags, timestamp: timestamp, frameCount: frames)
    }

    private static func nominalSampleRate(_ deviceID: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value))
        return value
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size))
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, list))
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CoreAudioError.status(status) }
    }
}
