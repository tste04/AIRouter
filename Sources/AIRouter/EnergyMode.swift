import Foundation

/// Energiemodus, der das Routing-Verhalten zwischen Cloud- und lokalen Modellen steuert.
public enum EnergyMode: String, CaseIterable, Identifiable, Sendable, Codable {
    /// Nur Cloud-Modelle, hochwertige Modelle, kurze Intervalle.
    case maxCloud
    /// Cloud + lokale KI, Hintergrund-Enrichment aktiv.
    case fullPower
    /// Nur lokale KI, kein Netzwerk noetig.
    case offline
    /// KI nur bei Anfrage, kein Hintergrund, maximale Laufzeit.
    case powerSave

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .maxCloud: return "Max Cloud"
        case .fullPower: return "Volle Kraft"
        case .offline: return "Offline"
        case .powerSave: return "Stromsparen"
        }
    }

    public var description: String {
        switch self {
        case .maxCloud: return "Nur Cloud-Modelle, hochwertige Modelle, kurze Intervalle"
        case .fullPower: return "Cloud + lokale KI, Hintergrund-Enrichment aktiv"
        case .offline: return "Nur lokale KI, kein Netzwerk noetig"
        case .powerSave: return "KI nur bei Anfrage, kein Hintergrund, maximale Laufzeit"
        }
    }

    public var icon: String {
        switch self {
        case .maxCloud: return "cloud.bolt.fill"
        case .fullPower: return "bolt.fill"
        case .offline: return "wifi.slash"
        case .powerSave: return "battery.25"
        }
    }
}
