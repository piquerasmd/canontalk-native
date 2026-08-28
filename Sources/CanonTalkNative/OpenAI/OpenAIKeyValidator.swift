import Foundation

enum OpenAIKeyValidationError: LocalizedError, Equatable {
    case invalidKey
    case forbidden
    case modelUnavailable
    case rateLimited
    case server(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "La API key de OpenAI no es válida. Revisa que no tenga espacios y vuelve a guardarla."
        case .forbidden:
            return "La API key es válida, pero no tiene permisos para consultar el modelo."
        case .modelUnavailable:
            return "gpt-realtime-translate no está disponible para esta cuenta o proyecto de OpenAI."
        case .rateLimited:
            return "OpenAI rechazó la solicitud por cuota o límite de uso. Revisa Billing y Limits."
        case .server(let status, let message):
            return "OpenAI devolvió HTTP \(status): \(message)"
        case .invalidResponse:
            return "OpenAI devolvió una respuesta que la aplicación no pudo interpretar."
        }
    }
}

struct OpenAIKeyValidator {
    func validate(_ apiKey: String) async throws {
        guard let url = URL(string: "https://api.openai.com/v1/models/gpt-realtime-translate") else {
            throw OpenAIKeyValidationError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIKeyValidationError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw Self.error(status: http.statusCode, data: data)
        }
    }

    static func error(status: Int, data: Data) -> OpenAIKeyValidationError {
        switch status {
        case 401: return .invalidKey
        case 403: return .forbidden
        case 404: return .modelUnavailable
        case 429: return .rateLimited
        default:
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let details = object?["error"] as? [String: Any]
            let message = details?["message"] as? String ?? HTTPURLResponse.localizedString(forStatusCode: status)
            return .server(status, message)
        }
    }
}
