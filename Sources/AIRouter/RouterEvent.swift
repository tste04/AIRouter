import Foundation

/// Maschinenlesbares Routing-/Governance-Ereignis. Ergaenzt das Text-Log um
/// einen Hook, den Apps fuer Metriken, Dashboards oder Alarme auswerten
/// koennen (``AIRouter/setEventCallback(_:)``).
public enum RouterEvent: Sendable, Equatable {
    /// Lokaler Aufruf fehlgeschlagen, Wechsel auf den Cloud-Pfad.
    case cloudFallback(task: String)
    /// Cloud-Budget erschoepft, Wechsel auf das lokale Backend.
    case localFallback(task: String)
    /// Aufruf am Token- oder Kosten-Budget gedrosselt.
    case budgetThrottled(label: String)
    /// Circuit-Breaker fuer ein Modell geoeffnet (Fehlerserie).
    case breakerOpened(model: String)
    /// Circuit-Breaker nach Cooldown wieder geschlossen.
    case breakerClosed(model: String)
    /// Wechsel auf das Fallback-Modell der Katalog-Kette — bei HTTP 404 oder
    /// weil der Circuit-Breaker das urspruengliche Modell meidet.
    case modelFallback(from: String, to: String)
    /// Transienter Fehler, Wiederholungsversuch folgt.
    case retrying(model: String, attempt: Int)
    /// Antwort aus dem Cache bedient — kein Backend-Aufruf.
    case cacheHit(task: String)
}
