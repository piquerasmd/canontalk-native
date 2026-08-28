import Foundation
import AVFoundation
import Combine

@MainActor
final class AppViewModel: ObservableObject {
    let settings = AppSettings()
    let devices = AudioDeviceService()
    let localToRemote = TranslationPipeline(direction: .localToRemote)
    let remoteToLocal = TranslationPipeline(direction: .remoteToLocal)

    @Published var apiKey = ""
    @Published private(set) var hasStoredAPIKey = false
    @Published private(set) var isRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var startupStatus = ""
    @Published var errorMessage: String?
    @Published private(set) var sessionStartedAt: Date?

    private let keychain = KeychainCredentialStore()
    private let keyValidator = OpenAIKeyValidator()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        do {
            if let stored = try keychain.load() {
                apiKey = stored
                hasStoredAPIKey = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        applyDeviceSuggestions()

        devices.$devices
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyDeviceSuggestions()
                self.enforceSelectedDevicesStillExist()
            }
            .store(in: &cancellables)
    }

    func saveAPIKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try keychain.delete()
                hasStoredAPIKey = false
            } else {
                try keychain.save(trimmed)
                apiKey = trimmed
                hasStoredAPIKey = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteAPIKey() {
        apiKey = ""
        saveAPIKey()
    }

    func start() async {
        guard !isBusy else { return }
        isBusy = true
        startupStatus = "Validando configuración…"
        defer {
            isBusy = false
            startupStatus = ""
        }

        do {
            try validateConfiguration()
            saveAPIKey()
            startupStatus = "Validando API key con OpenAI…"
            try await keyValidator.validate(apiKey)
            startupStatus = "Esperando permiso del micrófono…"
            try await requestMicrophonePermission()

            guard
                let mic = devices.device(uid: settings.microphoneUID),
                let headphones = devices.device(uid: settings.headphonesUID),
                let capture = devices.device(uid: settings.remoteCaptureUID),
                let injection = devices.device(uid: settings.translatedMicUID)
            else { throw ConfigurationError.missingDevice("audio") }

            let outbound = TranslationDirectionConfig(
                sourceLanguage: settings.localLanguage,
                targetLanguage: settings.remoteLanguage,
                inputDeviceUID: mic.uid,
                outputDeviceUID: injection.uid,
                direction: .localToRemote
            )
            let inbound = TranslationDirectionConfig(
                sourceLanguage: settings.remoteLanguage,
                targetLanguage: settings.localLanguage,
                inputDeviceUID: capture.uid,
                outputDeviceUID: headphones.uid,
                direction: .remoteToLocal
            )

            startupStatus = "Abriendo traducción hacia la llamada…"
            try await localToRemote.start(
                configuration: outbound,
                apiKey: apiKey,
                inputDeviceID: mic.objectID,
                outputDeviceID: injection.objectID
            )
            do {
                startupStatus = "Abriendo traducción hacia tus auriculares…"
                try await remoteToLocal.start(
                    configuration: inbound,
                    apiKey: apiKey,
                    inputDeviceID: capture.objectID,
                    outputDeviceID: headphones.objectID
                )
            } catch {
                await localToRemote.stop()
                throw error
            }

            isRunning = true
            sessionStartedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
            sessionStartedAt = nil
        }
    }

    func stop() async {
        guard !isBusy else { return }
        isBusy = true
        await localToRemote.stop()
        await remoteToLocal.stop()
        localToRemote.clearTranscripts()
        remoteToLocal.clearTranscripts()
        isRunning = false
        sessionStartedAt = nil
        isBusy = false
    }

    func validateConfiguration() throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.missingAPIKey
        }
        guard settings.localLanguage != settings.remoteLanguage else {
            throw ConfigurationError.sameLanguage
        }
        let roles: [(String, String, Bool)] = [
            (settings.microphoneUID, "micrófono físico", true),
            (settings.headphonesUID, "auriculares", false),
            (settings.remoteCaptureUID, "captura BlackHole 2ch", true),
            (settings.translatedMicUID, "inyección BlackHole 16ch", false)
        ]
        for (uid, role, needsInput) in roles {
            guard !uid.isEmpty, let device = devices.device(uid: uid) else {
                throw ConfigurationError.missingDevice(role)
            }
            guard needsInput ? device.supportsInput : device.supportsOutput else {
                throw ConfigurationError.invalidDevice(role)
            }
        }
        guard settings.remoteCaptureUID != settings.translatedMicUID else {
            throw ConfigurationError.blackHoleRolesOverlap
        }
        guard devices.device(uid: settings.remoteCaptureUID)?.isBlackHole == true else {
            throw ConfigurationError.invalidDevice("captura BlackHole 2ch")
        }
        guard devices.device(uid: settings.translatedMicUID)?.isBlackHole == true else {
            throw ConfigurationError.invalidDevice("inyección BlackHole 16ch")
        }
    }

    private func applyDeviceSuggestions() {
        if devices.device(uid: settings.microphoneUID) == nil {
            settings.microphoneUID = devices.inputDevices.first(where: { !$0.isBlackHole })?.uid ?? ""
        }
        if devices.device(uid: settings.headphonesUID) == nil {
            settings.headphonesUID = devices.outputDevices.first(where: { !$0.isBlackHole })?.uid ?? ""
        }
        if devices.device(uid: settings.remoteCaptureUID) == nil {
            settings.remoteCaptureUID = devices.suggestedBlackHoleCapture()?.uid ?? ""
        }
        if devices.device(uid: settings.translatedMicUID) == nil {
            settings.translatedMicUID = devices.suggestedBlackHoleInjection(
                excluding: settings.remoteCaptureUID
            )?.uid ?? ""
        }
    }

    private func enforceSelectedDevicesStillExist() {
        guard isRunning else { return }
        let selected = [
            settings.microphoneUID,
            settings.headphonesUID,
            settings.remoteCaptureUID,
            settings.translatedMicUID
        ]
        guard selected.allSatisfy({ devices.device(uid: $0) != nil }) else {
            errorMessage = "Se desconectó un dispositivo seleccionado. La sesión se detuvo para evitar fugas de audio."
            Task { await stop() }
            return
        }
    }

    private func requestMicrophonePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw MicrophonePermissionError.denied
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                let gate = PermissionContinuationGate(continuation)
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    gate.resume(returning: granted)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
                    gate.resume(returning: false)
                }
            }
            guard granted else {
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    throw MicrophonePermissionError.timedOut
                }
                throw MicrophonePermissionError.denied
            }
        @unknown default:
            throw MicrophonePermissionError.denied
        }
    }
}

private final class PermissionContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Bool) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(returning: value)
    }
}

enum MicrophonePermissionError: LocalizedError {
    case denied
    case timedOut

    var errorDescription: String? {
        switch self {
        case .denied:
            return "CanonTalk no tiene permiso para usar el micrófono. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Micrófono."
        case .timedOut:
            return "macOS no respondió a la solicitud del micrófono en 20 segundos. Restablece el permiso de CanonTalk y vuelve a intentarlo."
        }
    }
}
