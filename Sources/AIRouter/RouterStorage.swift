import Foundation

/// Persistierter Budget-Zustand einer Stunde. Wird von ``RouterStorage``
/// gespeichert/geladen, damit Budgetzaehler einen App-Neustart ueberleben.
public struct PersistedBudgetState: Codable, Sendable {
    public let tokensUsed: Int
    public let costUSD: Double
    public let throttled: Int
    public let hourStarted: Date

    public init(tokensUsed: Int, costUSD: Double, throttled: Int, hourStarted: Date) {
        self.tokensUsed = tokensUsed
        self.costUSD = costUSD
        self.throttled = throttled
        self.hourStarted = hourStarted
    }
}

/// Persistenz-Hook des Routers. Die Implementierung entscheidet ueber das
/// Speichermedium (UserDefaults, Datei, Datenbank, ...). Alle Aufrufe sind
/// fire-and-forget aus Router-Sicht; Fehlerbehandlung liegt beim Storage.
public protocol RouterStorage: Sendable {
    /// Laedt den zuletzt gespeicherten Budget-Zustand (oder `nil`).
    func loadBudgetState() async -> PersistedBudgetState?

    /// Speichert den aktuellen Budget-Zustand.
    func saveBudgetState(_ state: PersistedBudgetState) async
}
