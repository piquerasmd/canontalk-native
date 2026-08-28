import Foundation
import CoreAudio
import os

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
    private static let logger = Logger(subsystem: "com.canontalk.native", category: "startup")
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
        outputDeviceID: AudioDeviceID,
        progress: @MainActor (String) -> Void
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
        let directionLabel = direction.title
        progress("Conectando OpenAI · \(directionLabel)…")
        Self.logger.notice("Starting OpenAI session: \(directionLabel, privacy: .public)")
        await realtime.start(configuration: configuration, apiKey: apiKey)
        Self.logger.notice("OpenAI start returned: \(directionLabel, privacy: .public)")

        do {
            progress("Abriendo salida · \(directionLabel)…")
            Self.logger.notice("Opening output device: \(directionLabel, privacy: .public)")
            try playback.start(deviceID: outputDeviceID)
            Self.logger.notice("Output device ready: \(directionLabel, privacy: .public)")
            progress("Abriendo entrada · \(directionLabel)…")
            Self.logger.notice("Opening input device: \(directionLabel, privacy: .public)")
            try capture.start(deviceID: inputDeviceID) { data, level in
                let isBypassed = bypassGate.enabled
                if isBypassed { audioPlayback.enqueue(data) }
                let outbound = isBypassed ? PCM16.silence(byteCount: data.count) : data
                Task { await realtime.appendAudio(outbound) }
                Task { @MainActor in target.updateLevel(level) }
            }
            Self.logger.notice("Input device ready: \(directionLabel, privacy: .public)")
            progress("Ruta lista · \(directionLabel)")
        } catch {
            Self.logger.error("Pipeline failed: \(directionLabel, privacy: .public) · \(error.localizedDescription, privacy: .public)")
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
