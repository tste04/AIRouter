import Foundation

/// Ein OAuth2-Access-Token mit explizitem Ablaufzeitpunkt. Der ``AIRouter``
/// cached anhand von ``expiresAt`` statt eines festen Intervalls, damit kurz-
/// lebige Tokens nicht stale serviert werden.
public struct AccessToken: Sendable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }

    /// Bequemer Konstruktor: Token mit relativer Lebensdauer ab jetzt.
    public init(value: String, lifetime: TimeInterval) {
        self.value = value
        self.expiresAt = Date().addingTimeInterval(lifetime)
    }
}
