import Foundation

actor RealtimeTranslationSession {
    typealias StateHandler = @Sendable (PipelineState) -> Void
    typealias AudioHandler = @Sendable (Data) -> Void
    typealias TranscriptHandler = @Sendable (String) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    struct Callbacks: Sendable {
        let onState: StateHandler
        let onAudio: AudioHandler
        let onInputTranscript: TranscriptHandler
        let onOutputTranscript: TranscriptHandler
        let onError: ErrorHandler
    }

    private let callbacks: Callbacks
    private var socket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var desiredRunning = false
    private var currentState: PipelineState = .idle
    private var configuration: TranslationDirectionConfig?
    private var apiKey = ""
    private var reconnectAttempt = 0

    init(callbacks: Callbacks) {
        self.callbacks = callbacks
    }

    func start(configuration: TranslationDirectionConfig, apiKey: String) async {
        guard !desiredRunning else { return }
        self.configuration = configuration
        self.apiKey = apiKey
        desiredRunning = true
        reconnectAttempt = 0
        await connect(reconnecting: false)
    }

    func appendAudio(_ pcm16: Data) async {
        guard desiredRunning, currentState == .active, let socket else { return }
        do {
            try await sendJSON([
                "type": "session.input_audio_buffer.append",
                "audio": pcm16.base64EncodedString()
            ], over: socket)
        } catch {
            await handleConnectionLoss(error)
        }
    }

    func stop() async {
        guard socket != nil || desiredRunning else {
            emit(.idle)
            return
        }
        desiredRunning = false
        emit(.stopping)
        if let socket {
            try? await sendJSON(["type": "session.close"], over: socket)
        }

        let deadline = Date().addingTimeInterval(5)
        while currentState == .stopping && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        closeTransport()
        emit(.idle)
    }

    private func connect(reconnecting: Bool) async {
        guard desiredRunning, let configuration else { return }
        emit(reconnecting ? .reconnecting(attempt: reconnectAttempt) : .connecting)

        var components = URLComponents(string: "wss://api.openai.com/v1/realtime/translations")!
        components.queryItems = [URLQueryItem(name: "model", value: "gpt-realtime-translate")]
        guard let url = components.url else {
            emit(.failed("URL de OpenAI no válida"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.safetyIdentifier, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        request.timeoutInterval = 15

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        urlSession = session
        socket = task
        task.resume()

        do {
            try await sendJSON([
                "type": "session.update",
                "session": [
                    "audio": [
                        "input": [
                            "transcription": [
                                "model": "gpt-realtime-whisper",
                                "language": configuration.sourceLanguage
                            ]
                        ],
                        "output": ["language": configuration.targetLanguage]
                    ]
                ]
            ], over: task)
            reconnectAttempt = 0
            emit(.active)
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(task: task)
            }
        } catch {
            await handleConnectionLoss(error)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        do {
            while socket === task {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    handle(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(text) }
                @unknown default:
                    break
                }
                if currentState == .idle { break }
            }
        } catch {
            if socket === task { await handleConnectionLoss(error) }
        }
    }

    private func handle(_ text: String) {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String
        else { return }

        switch type {
        case "session.output_audio.delta":
            if let delta = object["delta"] as? String, let audio = Data(base64Encoded: delta) {
                callbacks.onAudio(audio)
            }
        case "session.input_transcript.delta":
            if let delta = object["delta"] as? String { callbacks.onInputTranscript(delta) }
        case "session.output_transcript.delta":
            if let delta = object["delta"] as? String { callbacks.onOutputTranscript(delta) }
        case "session.closed":
            closeTransport()
            emit(.idle)
        case "error":
            let details = object["error"] as? [String: Any]
            let message = details?["message"] as? String ?? "OpenAI devolvió un error desconocido."
            callbacks.onError(message)
            emit(.failed(message))
        default:
            break
        }
    }

    private func handleConnectionLoss(_ error: Error) async {
        closeTransport()
        guard desiredRunning else {
            emit(.idle)
            return
        }
        reconnectAttempt += 1
        guard reconnectAttempt <= 5 else {
            let message = "No se pudo restablecer la traducción: \(error.localizedDescription)"
            callbacks.onError(message)
            emit(.failed(message))
            desiredRunning = false
            return
        }

        emit(.reconnecting(attempt: reconnectAttempt))
        let delays: [UInt64] = [500, 1_000, 2_000, 5_000, 10_000]
        try? await Task.sleep(nanoseconds: delays[reconnectAttempt - 1] * 1_000_000)
        await connect(reconnecting: true)
    }

    private func sendJSON(_ object: [String: Any], over task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await task.send(.string(text))
    }

    private func emit(_ state: PipelineState) {
        currentState = state
        callbacks.onState(state)
    }

    private func closeTransport() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private static var safetyIdentifier: String {
        let key = "com.canontalk.native.safety-id"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
