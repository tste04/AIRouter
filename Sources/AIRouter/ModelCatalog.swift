import Foundation

/// Beschreibt ein Modell als Daten statt als String-Heuristik: Anbieter,
/// optionaler Upgrade-Pfad (Qualitaetssteigerung) und optionaler Fallback-Pfad
/// (Degradation bei HTTP 404).
public struct ModelDescriptor: Sendable, Equatable {
    public enum Provider: Sendable, Equatable {
        case anthropic
        case google
        case local
    }

    public let provider: Provider
    /// Modell, auf das in `maxCloud` hochgestuft wird (oder `nil`).
    public let upgradesTo: String?
    /// Modell, auf das bei HTTP 404 zurueckgefallen wird (oder `nil`).
    public let fallsBackTo: String?

    public init(provider: Provider, upgradesTo: String? = nil, fallsBackTo: String? = nil) {
        self.provider = provider
        self.upgradesTo = upgradesTo
        self.fallsBackTo = fallsBackTo
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

    /// Standardkatalog (Google Gemini + Anthropic Claude) mit Upgrade-/Fallback-Pfaden.
    public static let `default` = ModelCatalog([
        "gemini-2.5-flash": ModelDescriptor(provider: .google, upgradesTo: "gemini-2.5-pro", fallsBackTo: nil),
        "gemini-2.5-pro": ModelDescriptor(provider: .google, upgradesTo: "claude-opus-4-6", fallsBackTo: "gemini-2.5-flash"),
        "claude-opus-4-6": ModelDescriptor(provider: .anthropic, upgradesTo: nil, fallsBackTo: "claude-sonnet-4-6"),
        "claude-sonnet-4-6": ModelDescriptor(provider: .anthropic, upgradesTo: nil, fallsBackTo: nil)
    ])
}
