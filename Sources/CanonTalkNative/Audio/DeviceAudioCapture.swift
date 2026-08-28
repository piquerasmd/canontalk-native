import Foundation
import AVFoundation
import AudioToolbox

final class DeviceAudioCapture: @unchecked Sendable {
    typealias PCMHandler = @Sendable (Data, Float) -> Void

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var handler: PCMHandler?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: PCM16.sampleRate,
        channels: 1,
        interleaved: false
    )!

    func start(deviceID: AudioDeviceID, handler: @escaping PCMHandler) throws {
        stop()
        self.handler = handler

        let node = engine.inputNode
        guard let unit = node.audioUnit else {
            throw CoreAudioError.unavailable("No se pudo abrir la entrada de audio.")
        }
        var selectedID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &selectedID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CoreAudioError.status(status) }

        let inputFormat = node.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CoreAudioError.unavailable("El dispositivo de entrada no tiene un formato válido.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CoreAudioError.unavailable("No se pudo crear el conversor a PCM16/24 kHz.")
        }
        self.converter = converter

        node.installTap(onBus: 0, bufferSize: 960, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        converter = nil
        handler = nil
    }

    private func convert(_ input: AVAudioPCMBuffer) {
        guard let converter, let handler else { return }
        let ratio = PCM16.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil,
              let channel = output.int16ChannelData?[0] else { return }

        let byteCount = Int(output.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channel, count: byteCount)
        handler(data, PCM16.level(data))
    }
}
