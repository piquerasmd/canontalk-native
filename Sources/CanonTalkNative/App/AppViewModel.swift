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
    @Published var errorMessage: String?
    @Published private(set) var sessionStartedAt: Date?

    private let keychain = KeychainCredentialStore()
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
        defer { isBusy = false }

        do {
            try validateConfiguration()
            guard await requestMicrophonePermission() else {
                throw CoreAudioError.unavailable("Concede acceso al micrófono en Ajustes del Sistema.")
            }
            saveAPIKey()

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

            try await localToRemote.start(
                configuration: outbound,
                apiKey: apiKey,
                inputDeviceID: mic.objectID,
                outputDeviceID: injection.objectID
            )
            do {
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

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
