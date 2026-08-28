import Foundation
import CoreAudio

private final class BypassGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var enabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

@MainActor
final class TranslationPipeline: ObservableObject {
    @Published private(set) var state: PipelineState = .idle
    @Published private(set) var inputTranscript = ""
    @Published private(set) var outputTranscript = ""
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var lastError: String?
    @Published private(set) var bypassEnabled = false

    let direction: TranslationDirection

    private let capture = DeviceAudioCapture()
    private let playback = DeviceAudioPlayback()
    private let bypass = BypassGate()
    private var realtime: RealtimeTranslationSession?
    private var levelUpdate = Date.distantPast

    init(direction: TranslationDirection) {
        self.direction = direction
    }

    func start(
        configuration: TranslationDirectionConfig,
        apiKey: String,
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID
    ) async throws {
        guard state == .idle || isFailed else { return }
        state = .validating
        lastError = nil
        inputTranscript = ""
        outputTranscript = ""

        let target = self
        let audioPlayback = playback
        let bypassGate = bypass
        let callbacks = RealtimeTranslationSession.Callbacks(
            onState: { state in
                Task { @MainActor in target.state = state }
            },
            onAudio: { data in
                guard !bypassGate.enabled else { return }
                audioPlayback.enqueue(data)
            },
            onInputTranscript: { delta in
                Task { @MainActor in target.appendInputTranscript(delta) }
            },
            onOutputTranscript: { delta in
                Task { @MainActor in target.appendOutputTranscript(delta) }
            },
            onError: { message in
                Task { @MainActor in
                    target.lastError = message
                    target.playback.clear()
                }
            }
        )
        let realtime = RealtimeTranslationSession(callbacks: callbacks)
        self.realtime = realtime
        await realtime.start(configuration: configuration, apiKey: apiKey)

        do {
            try playback.start(deviceID: outputDeviceID)
            try capture.start(deviceID: inputDeviceID) { data, level in
                let isBypassed = bypassGate.enabled
                if isBypassed { audioPlayback.enqueue(data) }
                let outbound = isBypassed ? PCM16.silence(byteCount: data.count) : data
                Task { await realtime.appendAudio(outbound) }
                Task { @MainActor in target.updateLevel(level) }
            }
        } catch {
            await realtime.stop()
            playback.stop()
            self.realtime = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    func stop() async {
        capture.stop()
        bypass.set(false)
        bypassEnabled = false
        if let realtime { await realtime.stop() }
        playback.stop()
        realtime = nil
        inputLevel = 0
        state = .idle
    }

    func setBypass(_ enabled: Bool) {
        bypass.set(enabled)
        bypassEnabled = enabled
        playback.clear()
    }

    func clearTranscripts() {
        inputTranscript = ""
        outputTranscript = ""
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func appendInputTranscript(_ delta: String) {
        inputTranscript = PCM16.trimmedTranscript(inputTranscript + delta)
    }

    private func appendOutputTranscript(_ delta: String) {
        outputTranscript = PCM16.trimmedTranscript(outputTranscript + delta)
    }

    private func updateLevel(_ value: Float) {
        let now = Date()
        guard now.timeIntervalSince(levelUpdate) >= 0.05 else { return }
        levelUpdate = now
        inputLevel = value
    }
}
