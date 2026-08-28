import Foundation

struct SupportedLanguage: Identifiable, Hashable, Codable, Sendable {
    let code: String
    let name: String

    var id: String { code }

    static let all: [SupportedLanguage] = [
        .init(code: "es", name: "Español"),
        .init(code: "pt", name: "Portugués"),
        .init(code: "fr", name: "Francés"),
        .init(code: "ja", name: "Japonés"),
        .init(code: "ru", name: "Ruso"),
        .init(code: "zh", name: "Chino"),
        .init(code: "de", name: "Alemán"),
        .init(code: "ko", name: "Coreano"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "id", name: "Indonesio"),
        .init(code: "vi", name: "Vietnamita"),
        .init(code: "it", name: "Italiano"),
        .init(code: "en", name: "Inglés")
    ]

    static func named(_ code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? code
    }
}
