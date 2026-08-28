import Foundation
import AVFoundation
import AudioToolbox

final class DeviceAudioPlayback: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.canontalk.playback", qos: .userInteractive)
    private let sourceFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: PCM16.sampleRate,
        channels: 1,
        interleaved: false
    )!
    private var running = false

    func start(deviceID: AudioDeviceID) throws {
        stop()
        guard let unit = engine.outputNode.audioUnit else {
            throw CoreAudioError.unavailable("No se pudo abrir la salida de audio.")
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

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: sourceFormat)
        engine.prepare()
        try engine.start()
        player.play()
        running = true
    }

    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: self.sourceFormat, frameCapacity: frameCount),
                  let destination = buffer.int16ChannelData?[0] else { return }
            buffer.frameLength = frameCount
            _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: destination, count: Int(frameCount)))
            self.player.scheduleBuffer(buffer)
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.player.stop()
            self.player.reset()
            self.player.play()
        }
    }

    func stop() {
        queue.sync {
            if player.engine != nil {
                player.stop()
                engine.disconnectNodeOutput(player)
                engine.detach(player)
            }
            if engine.isRunning { engine.stop() }
            engine.reset()
            running = false
        }
    }
}
