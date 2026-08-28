import XCTest
@testable import CanonTalkNative

final class CoreTests: XCTestCase {
    func testSupportedLanguagesAreTheOfficialThirteenTargets() {
        XCTAssertEqual(SupportedLanguage.all.count, 13)
        XCTAssertEqual(Set(SupportedLanguage.all.map(\.code)).count, 13)
        XCTAssertTrue(SupportedLanguage.all.contains(where: { $0.code == "es" }))
        XCTAssertTrue(SupportedLanguage.all.contains(where: { $0.code == "en" }))
    }

    func testPCM16SilenceHasRequestedLengthAndZeroLevel() {
        let silence = PCM16.silence(byteCount: 960)
        XCTAssertEqual(silence.count, 960)
        XCTAssertEqual(PCM16.level(silence), 0)
    }

    func testPCM16LevelRecognizesSignal() {
        var samples: [Int16] = [0, Int16.max, Int16.min + 1, 0]
        let data = samples.withUnsafeMutableBytes { Data($0) }
        XCTAssertGreaterThan(PCM16.level(data), 0.6)
        XCTAssertLessThanOrEqual(PCM16.level(data), 1)
    }

    func testTranscriptIsBoundedFromTheEnd() {
        let source = String(repeating: "a", count: 100) + "final"
        let result = PCM16.trimmedTranscript(source, limit: 20)
        XCTAssertEqual(result.count, 20)
        XCTAssertTrue(result.hasSuffix("final"))
    }

    func testConfigurationErrorsAreActionable() {
        XCTAssertNotNil(ConfigurationError.missingAPIKey.errorDescription)
        XCTAssertNotNil(ConfigurationError.sameLanguage.errorDescription)
        XCTAssertNotNil(ConfigurationError.blackHoleRolesOverlap.errorDescription)
    }

    func testOpenAIKeyErrorMapping() {
        XCTAssertEqual(OpenAIKeyValidator.error(status: 401, data: Data()), .invalidKey)
        XCTAssertEqual(OpenAIKeyValidator.error(status: 403, data: Data()), .forbidden)
        XCTAssertEqual(OpenAIKeyValidator.error(status: 404, data: Data()), .modelUnavailable)
        XCTAssertEqual(OpenAIKeyValidator.error(status: 429, data: Data()), .rateLimited)
    }

    @MainActor
    func testBlackHole16HALPlaybackWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["RUN_AUDIO_HARDWARE_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_AUDIO_HARDWARE_TESTS=1 to exercise installed audio hardware.")
        }
        let service = AudioDeviceService()
        guard let device = service.outputDevices.first(where: {
            $0.name.localizedCaseInsensitiveContains("BlackHole 16ch")
        }) else {
            throw XCTSkip("BlackHole 16ch is not installed.")
        }
        let playback = DeviceAudioPlayback()
        let started = Date()
        try playback.start(deviceID: device.objectID)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        playback.stop()
    }
}
