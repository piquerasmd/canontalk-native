import Foundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable, Sendable {
    let objectID: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let nominalSampleRate: Double

    var id: String { uid }
    var supportsInput: Bool { inputChannels > 0 }
    var supportsOutput: Bool { outputChannels > 0 }
    var isBlackHole: Bool { name.localizedCaseInsensitiveContains("BlackHole") }
    var displayName: String { "\(name) · \(Int(nominalSampleRate)) Hz" }
}
