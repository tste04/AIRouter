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
    case circuitOpen(model: String)
    case responseTooLarge(limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return msg
        case .invalidEndpoint: return "Ungueltiger Vertex AI Endpoint"
        case .noResponse: return "Keine Antwort von Vertex AI"
        case .apiError(let code, let msg): return "KI-API Fehler (\(code)): \(msg.prefix(200))"
        case .unexpectedResponse: return "Unerwartete Vertex AI Antwort"
        case .authFailed: return "Authentifizierung fehlgeschlagen. Der accessTokenProvider lieferte kein gueltiges Token."
        case .budgetExhausted(let task): return "AI-Budget erschoepft fuer Task '\(task)'. Wird im naechsten Stundenzyklus ausgefuehrt."
        case .circuitOpen(let model): return "Modell '\(model)' ist nach wiederholten Fehlern temporaer deaktiviert (Circuit-Breaker)."
        case .responseTooLarge(let limit): return "Antwort ueberschreitet das Groessenlimit von \(limit) Bytes."
        }
    }
}
