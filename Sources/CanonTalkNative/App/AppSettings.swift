import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var localLanguage: String { didSet { save() } }
    @Published var remoteLanguage: String { didSet { save() } }
    @Published var microphoneUID: String { didSet { save() } }
    @Published var headphonesUID: String { didSet { save() } }
    @Published var remoteCaptureUID: String { didSet { save() } }
    @Published var translatedMicUID: String { didSet { save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        localLanguage = defaults.string(forKey: "localLanguage") ?? "es"
        remoteLanguage = defaults.string(forKey: "remoteLanguage") ?? "en"
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        headphonesUID = defaults.string(forKey: "headphonesUID") ?? ""
        remoteCaptureUID = defaults.string(forKey: "remoteCaptureUID") ?? ""
        translatedMicUID = defaults.string(forKey: "translatedMicUID") ?? ""
    }

    func swapLanguages() {
        (localLanguage, remoteLanguage) = (remoteLanguage, localLanguage)
    }

    private func save() {
        defaults.set(localLanguage, forKey: "localLanguage")
        defaults.set(remoteLanguage, forKey: "remoteLanguage")
        defaults.set(microphoneUID, forKey: "microphoneUID")
        defaults.set(headphonesUID, forKey: "headphonesUID")
        defaults.set(remoteCaptureUID, forKey: "remoteCaptureUID")
        defaults.set(translatedMicUID, forKey: "translatedMicUID")
    }
}
