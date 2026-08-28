import Foundation
import CoreAudio
import AudioToolbox
import os.lock

/// Direct HAL output. AVAudioEngine can fail to initialize reliably when several
/// engines select different devices, especially a 16-channel virtual device.
final class DeviceAudioPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.canontalk.playback", qos: .userInteractive)
    private let ring = FloatRingBuffer(capacity: 24_000 * 20)
    private let scratchCapacity = 8_192
    private let scratch: UnsafeMutablePointer<Float>
    private var unit: AudioUnit?
    private var targetSampleRate = 48_000.0
    private var clientChannels: UInt32 = 2
    private var acceptingAudio = false

    init() {
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
    }

    deinit {
        stop()
        scratch.deinitialize(count: scratchCapacity)
        scratch.deallocate()
    }

    func start(deviceID: AudioDeviceID) throws {
        stop()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CoreAudioError.unavailable("No se encontró la unidad HAL de salida.")
        }
        var created: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &created))
        guard let created else {
            throw CoreAudioError.unavailable("No se pudo crear la unidad HAL de salida.")
        }

        do {
            var enabled: UInt32 = 1
            try Self.check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                0, &enabled, UInt32(MemoryLayout<UInt32>.size)
            ))

            var disabled: UInt32 = 0
            try Self.check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                1, &disabled, UInt32(MemoryLayout<UInt32>.size)
            ))

            var selectedID = deviceID
            try Self.check(AudioUnitSetProperty(
                created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                0, &selectedID, UInt32(MemoryLayout<AudioDeviceID>.size)
            ))

            targetSampleRate = try Self.nominalSampleRate(deviceID)
            clientChannels = UInt32(max(2, try Self.outputChannelCount(deviceID)))
            var format = AudioStreamBasicDescription(
                mSampleRate: targetSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian,
                mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
                mChannelsPerFrame: clientChannels,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            try Self.check(AudioUnitSetProperty(
                created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input,
                0, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            ))

            var callback = AURenderCallbackStruct(
                inputProc: Self.renderCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(
                created, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))

            try Self.check(AudioUnitInitialize(created))
            ring.clear()
            unit = created
            acceptingAudio = true
            try Self.check(AudioOutputUnitStart(created))
        } catch {
            AudioUnitUninitialize(created)
            AudioComponentInstanceDispose(created)
            unit = nil
            acceptingAudio = false
            throw error
        }
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.acceptingAudio else { return }
            self.ring.write(self.resample(data))
        }
    }

    func clear() {
        ring.clear()
    }

    func stop() {
        acceptingAudio = false
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        ring.clear()
    }

    private func resample(_ data: Data) -> [Float] {
        var source: [Float] = []
        source.reserveCapacity(data.count / MemoryLayout<Int16>.size)
        data.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Int16.self) {
                source.append(Float(value) / Float(Int16.max))
            }
        }
        guard source.count > 1 else { return source }

        let ratio = targetSampleRate / PCM16.sampleRate
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

    private func render(frameCount: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let frames = Int(frameCount)
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard frames <= scratchCapacity else {
            for buffer in buffers where buffer.mData != nil {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }
            return noErr
        }

        ring.read(into: scratch, count: frames)
        for (index, buffer) in buffers.enumerated() {
            guard let destination = buffer.mData else { continue }
            if index < 2 {
                memcpy(destination, scratch, min(Int(buffer.mDataByteSize), frames * MemoryLayout<Float>.size))
            } else {
                memset(destination, 0, Int(buffer.mDataByteSize))
            }
        }
        return noErr
    }

    private static let renderCallback: AURenderCallback = { reference, _, _, _, frames, ioData in
        let playback = Unmanaged<DeviceAudioPlayback>.fromOpaque(reference).takeUnretainedValue()
        return playback.render(frameCount: frames, ioData: ioData)
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

    private static func outputChannelCount(_ deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
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

private final class FloatRingBuffer: @unchecked Sendable {
    private var lock = os_unfair_lock_s()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: capacity)
    }

    func write(_ values: [Float]) {
        os_unfair_lock_lock(&lock)
        for value in values {
            if available == storage.count {
                readIndex = (readIndex + 1) % storage.count
                available -= 1
            }
            storage[writeIndex] = value
            writeIndex = (writeIndex + 1) % storage.count
            available += 1
        }
        os_unfair_lock_unlock(&lock)
    }

    func read(into destination: UnsafeMutablePointer<Float>, count requested: Int) {
        os_unfair_lock_lock(&lock)
        let readable = min(requested, available)
        for index in 0..<readable {
            destination[index] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
        }
        available -= readable
        os_unfair_lock_unlock(&lock)
        if readable < requested {
            destination.advanced(by: readable).initialize(repeating: 0, count: requested - readable)
        }
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        writeIndex = 0
        available = 0
        os_unfair_lock_unlock(&lock)
    }
}
