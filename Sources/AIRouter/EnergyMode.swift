import Foundation

/// Energiemodus, der das Routing-Verhalten zwischen Cloud- und lokalen Modellen steuert.
public enum EnergyMode: String, CaseIterable, Identifiable, Sendable {
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
        case .maxCloud: "Max Cloud"
        case .fullPower: "Volle Kraft"
        case .offline: "Offline"
        case .powerSave: "Stromsparen"
        }
    }

    public var description: String {
        switch self {
        case .maxCloud: "Nur Cloud-Modelle, hochwertige Modelle, kurze Intervalle"
        case .fullPower: "Cloud + lokale KI, Hintergrund-Enrichment aktiv"
        case .offline: "Nur lokale KI, kein Netzwerk noetig"
        case .powerSave: "KI nur bei Anfrage, kein Hintergrund, maximale Laufzeit"
        }
    }

    public var icon: String {
        switch self {
        case .maxCloud: "cloud.bolt.fill"
        case .fullPower: "bolt.fill"
        case .offline: "wifi.slash"
        case .powerSave: "battery.25"
        }
    }
}
