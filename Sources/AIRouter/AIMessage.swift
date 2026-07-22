import Foundation

/// Eine Nachricht in einer Multi-Turn-Konversation.
///
/// Der Router unterstuetzt neben dem einfachen `system`+`user`-Paar auch
/// vollstaendige Konversationsverlaeufe. Cloud-Backends (Anthropic/Google)
/// und Ollama erhalten die Nachrichten nativ; ein ``LocalInferenceProvider``
/// bekommt den Verlauf zu einem einzelnen Prompt zusammengefasst, da sein
/// Protokoll bewusst minimal gehalten ist.
public struct AIMessage: Sendable, Equatable, Hashable {
    public enum Role: String, Sendable, Equatable, Hashable {
        case user
        case assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    public static func user(_ content: String) -> AIMessage {
        AIMessage(role: .user, content: content)
    }

    public static func assistant(_ content: String) -> AIMessage {
        AIMessage(role: .assistant, content: content)
    }
}

/// Sampling-/Generierungs-Optionen pro Aufruf. Nicht gesetzte Werte (`nil`)
/// ueberlassen die Wahl dem jeweiligen Backend bzw. dessen Defaults.
public struct GenerationOptions: Sendable, Equatable, Hashable {
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var stopSequences: [String]
    /// Strukturierte JSON-Ausgabe anfordern, sofern das Backend es unterstuetzt
    /// (Google: `responseMimeType`, OpenAI-kompatibel: `response_format`,
    /// Ollama: `format: json`). Anthropic hat keinen nativen JSON-Mode; dort
    /// wird die Option ignoriert.
    public var jsonMode: Bool
    /// Request-Deadline in Sekunden fuer diesen Aufruf; `nil` nutzt die
    /// Router-Defaults (Cloud 60 s, lokal 120 s).
    public var requestTimeout: TimeInterval?

    public init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        stopSequences: [String] = [],
        jsonMode: Bool = false,
        requestTimeout: TimeInterval? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.stopSequences = stopSequences
        self.jsonMode = jsonMode
        self.requestTimeout = requestTimeout
    }

    public static let `default` = GenerationOptions()
}
