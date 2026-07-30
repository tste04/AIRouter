import Foundation

/// Konfigurierbare Retry-Strategie fuer transiente Cloud-Fehler (HTTP 429/5xx).
/// Der Backoff ist exponentiell: `baseDelay * 2^(versuch-1)`.
public struct RetryPolicy: Sendable, Codable {
    public let maxTransientRetries: Int
    public let baseDelay: TimeInterval

    public init(maxTransientRetries: Int = 2, baseDelay: TimeInterval = 1.0) {
        self.maxTransientRetries = max(0, maxTransientRetries)
        self.baseDelay = max(0, baseDelay)
    }

    public static let `default` = RetryPolicy()
}
