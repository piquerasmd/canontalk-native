import Foundation

enum TranslationDirection: String, Codable, Sendable {
    case localToRemote
    case remoteToLocal

    var title: String {
        switch self {
        case .localToRemote: return "Tú → Persona remota"
        case .remoteToLocal: return "Persona remota → Tú"
        }
    }
}

enum PipelineState: Equatable, Sendable {
    case idle
    case validating
    case connecting
    case active
    case reconnecting(attempt: Int)
    case stopping
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Detenido"
        case .validating: return "Validando"
        case .connecting: return "Conectando"
        case .active: return "Traduciendo"
        case .reconnecting(let attempt): return "Reconectando (\(attempt))"
        case .stopping: return "Finalizando"
        case .failed(let message): return "Error: \(message)"
        }
    }
}

struct TranslationDirectionConfig: Sendable {
    let sourceLanguage: String
    let targetLanguage: String
    let inputDeviceUID: String
    let outputDeviceUID: String
    let direction: TranslationDirection
}

enum ConfigurationError: LocalizedError, Equatable {
    case missingAPIKey
    case sameLanguage
    case missingDevice(String)
    case invalidDevice(String)
    case blackHoleRolesOverlap

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Introduce una API key de OpenAI."
        case .sameLanguage:
            return "Elige dos idiomas diferentes."
        case .missingDevice(let role):
            return "Selecciona el dispositivo para: \(role)."
        case .invalidDevice(let role):
            return "El dispositivo seleccionado no admite el rol: \(role)."
        case .blackHoleRolesOverlap:
            return "La captura y la inyección deben usar dispositivos BlackHole distintos."
        }
    }
}
