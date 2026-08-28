import Foundation
import CoreAudio

@MainActor
final class AudioDeviceService: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var lastError: String?

    var inputDevices: [AudioDevice] { devices.filter(\.supportsInput) }
    var outputDevices: [AudioDevice] { devices.filter(\.supportsOutput) }

    init() {
        refresh()
        installDeviceListener()
    }

    func refresh() {
        do {
            devices = try Self.readDevices().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            lastError = nil
        } catch {
            devices = []
            lastError = error.localizedDescription
        }
    }

    func device(uid: String) -> AudioDevice? {
        devices.first(where: { $0.uid == uid })
    }

    func suggestedBlackHoleCapture() -> AudioDevice? {
        inputDevices.first { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }
    }

    func suggestedBlackHoleInjection(excluding uid: String? = nil) -> AudioDevice? {
        outputDevices.first {
            $0.uid != uid && $0.name.localizedCaseInsensitiveContains("BlackHole 16ch")
        }
    }

    private func installDeviceListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refresh()
        }
    }

    private static func readDevices() throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ))

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = Array(repeating: AudioDeviceID(0), count: count)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ))

        return ids.compactMap { id in
            guard
                let uid = try? stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                let name = try? stringProperty(id, selector: kAudioObjectPropertyName)
            else { return nil }

            let inputs = (try? channelCount(id, scope: kAudioDevicePropertyScopeInput)) ?? 0
            let outputs = (try? channelCount(id, scope: kAudioDevicePropertyScopeOutput)) ?? 0
            guard inputs > 0 || outputs > 0 else { return nil }
            let rate = (try? sampleRate(id)) ?? 0
            return AudioDevice(
                objectID: id,
                uid: uid,
                name: name,
                inputChannels: inputs,
                outputChannels: outputs,
                nominalSampleRate: rate
            )
        }
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        guard let value else { throw CoreAudioError.unavailable("Propiedad de dispositivo vacía.") }
        return value.takeUnretainedValue() as String
    }

    private static func sampleRate(_ id: AudioDeviceID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value))
        return value
    }

    private static func channelCount(
        _ id: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size))
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        try check(AudioObjectGetPropertyData(id, &address, 0, nil, &size, list))
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw CoreAudioError.status(status) }
    }
}

enum CoreAudioError: LocalizedError {
    case status(OSStatus)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .status(let status): return "Core Audio devolvió el código \(status)."
        case .unavailable(let message): return message
        }
    }
}
