import Foundation

/// Beschreibt ein Modell als Daten statt als String-Heuristik: Anbieter,
/// optionaler Upgrade-Pfad (Qualitaetssteigerung), optionaler Fallback-Pfad
/// (Degradation bei HTTP 404) sowie optionale Kosten- und Kontext-Metadaten.
public struct ModelDescriptor: Sendable, Equatable {
    public enum Provider: Sendable, Equatable {
        /// Anthropic via Vertex AI (`:rawPredict`).
        case anthropic
        /// Google via Vertex AI (`:generateContent`).
        case google
        /// Lokale Inferenz (In-Process-Provider oder Ollama).
        case local
        /// Ein per ``AIRouter/registerCloudProvider(_:)`` registrierter
        /// ``CloudInferenceProvider`` mit dieser ID (z. B. OpenAI-kompatibel
        /// oder Anthropic-direkt).
        case custom(String)
    }

    public let provider: Provider
    /// Modell, auf das in `maxCloud` hochgestuft wird (oder `nil`).
    public let upgradesTo: String?
    /// Modell, auf das bei HTTP 404 zurueckgefallen wird (oder `nil`).
    public let fallsBackTo: String?
    /// USD pro 1 Mio Input-Tokens (optional; fuer Kosten-Telemetrie).
    public let inputCostPerMTok: Double?
    /// USD pro 1 Mio Output-Tokens (optional; fuer Kosten-Telemetrie).
    public let outputCostPerMTok: Double?
    /// Maximales Kontextfenster in Tokens (optional; rein informativ).
    public let contextWindow: Int?

    public init(
        provider: Provider,
        upgradesTo: String? = nil,
        fallsBackTo: String? = nil,
        inputCostPerMTok: Double? = nil,
        outputCostPerMTok: Double? = nil,
        contextWindow: Int? = nil
    ) {
        self.provider = provider
        self.upgradesTo = upgradesTo
        self.fallsBackTo = fallsBackTo
        self.inputCostPerMTok = inputCostPerMTok
        self.outputCostPerMTok = outputCostPerMTok
        self.contextWindow = contextWindow
    }
}

/// Registry bekannter Modelle. Unbekannte Modelle fuehren bewusst zu einem
/// Fehler statt zu stiller Fehl-Zuordnung an den falschen Publisher-Endpoint.
public struct ModelCatalog: Sendable {
    private var entries: [String: ModelDescriptor]

    public init(_ entries: [String: ModelDescriptor]) {
        self.entries = entries
    }

    public func descriptor(for model: String) -> ModelDescriptor? {
        entries[model]
    }

    /// Fuegt eigene Modelle hinzu bzw. ueberschreibt Defaults.
    public mutating func merge(_ additional: [String: ModelDescriptor]) {
        entries.merge(additional) { _, new in new }
    }

    /// Standardkatalog (Google Gemini + Anthropic Claude) mit Upgrade-/Fallback-
    /// Pfaden. Die Kosten sind Listenpreis-Richtwerte (USD pro 1 Mio Tokens) und
    /// koennen ueber `additionalModels` projektspezifisch ueberschrieben werden.
    public static let `default` = ModelCatalog([
        "gemini-2.5-flash": ModelDescriptor(
            provider: .google, upgradesTo: "gemini-2.5-pro", fallsBackTo: nil,
            inputCostPerMTok: 0.30, outputCostPerMTok: 2.50, contextWindow: 1_048_576),
        "gemini-2.5-pro": ModelDescriptor(
            provider: .google, upgradesTo: "claude-opus-4-6", fallsBackTo: "gemini-2.5-flash",
            inputCostPerMTok: 1.25, outputCostPerMTok: 10.0, contextWindow: 1_048_576),
        "claude-opus-4-6": ModelDescriptor(
            provider: .anthropic, upgradesTo: nil, fallsBackTo: "claude-sonnet-4-6",
            inputCostPerMTok: 15.0, outputCostPerMTok: 75.0, contextWindow: 200_000),
        "claude-sonnet-4-6": ModelDescriptor(
            provider: .anthropic, upgradesTo: nil, fallsBackTo: nil,
            inputCostPerMTok: 3.0, outputCostPerMTok: 15.0, contextWindow: 200_000)
    ])
}
