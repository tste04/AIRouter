import Foundation

/// Fehler, die der ``AIRouter`` werfen kann.
public enum AIRouterError: LocalizedError {
    case notConfigured(String)
    case invalidEndpoint
    case noResponse
    case apiError(Int, String)
    case unexpectedResponse
    case authFailed
    case budgetExhausted(task: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return msg
        case .invalidEndpoint: return "Ungueltiger Vertex AI Endpoint"
        case .noResponse: return "Keine Antwort von Vertex AI"
        case .apiError(let code, let msg): return "KI-API Fehler (\(code)): \(msg.prefix(200))"
        case .unexpectedResponse: return "Unerwartete Vertex AI Antwort"
        case .authFailed: return "Authentifizierung fehlgeschlagen. Der accessTokenProvider lieferte kein gueltiges Token."
        case .budgetExhausted(let task): return "AI-Budget erschoepft fuer Task '\(task)'. Wird im naechsten Stundenzyklus ausgefuehrt."
        }
    }
}
