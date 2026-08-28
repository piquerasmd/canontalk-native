import Foundation

enum PCM16 {
    static let sampleRate = 24_000.0
    static let bytesPerSample = 2

    static func silence(byteCount: Int) -> Data {
        Data(repeating: 0, count: byteCount)
    }

    static func level(_ data: Data) -> Float {
        guard data.count >= bytesPerSample else { return 0 }
        var sum = Double(0)
        var count = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let normalized = Double(sample) / Double(Int16.max)
                sum += normalized * normalized
                count += 1
            }
        }
        guard count > 0 else { return 0 }
        return Float(min(1, sqrt(sum / Double(count))))
    }

    static func trimmedTranscript(_ value: String, limit: Int = 4_000) -> String {
        guard value.count > limit else { return value }
        return String(value.suffix(limit))
    }
}
