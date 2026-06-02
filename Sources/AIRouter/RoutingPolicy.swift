import Foundation

/// Routing-Policy, die bestimmt, ob eine Aufgabe lokal oder in der Cloud ausgefuehrt wird.
public enum RoutingPolicy: String, Sendable, CaseIterable, Identifiable {
    case cloudOnly
    case preferLocal
    case preferCloud
    case localOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cloudOnly: "Nur Cloud"
        case .preferCloud: "Bevorzugt Cloud"
        case .preferLocal: "Bevorzugt Lokal"
        case .localOnly: "Nur Lokal"
        }
    }
}

extension AITask {
    /// Standard-Routing-Policy fuer diese Aufgabe.
    public var routingPolicy: RoutingPolicy {
        switch self {
        case .dossierSynthesis, .documentAnalysis, .attachmentAnalysis, .bundleSynthesis:
            return .cloudOnly
        case .eventClassification, .emailRelevance, .noteRelevance, .sentimentAnalysis,
             .entityExtraction, .transcriptPolishing, .memoryFactExtraction,
             .openLoopDetection, .readoutCompression, .meetingProfiling,
             .bundleEntityExtraction, .bundleChangelog, .relevanceAssessment:
            return .preferLocal
        case .advisorRealtime, .coachRealtime, .copilotRealtime, .meetingSummary, .daySynthesis,
             .reflection, .memorySynthesis, .factCheck, .memoryQuery:
            // memoryQuery ist eine interaktive Nutzeranfrage (Chat), kein Hintergrund-
            // Enrichment. Sie gehoert daher auf die Cloud-Seite des Mischmodus (Volle Kraft),
            // bleibt in Offline aber automatisch lokal.
            return .preferCloud
        case .contradictionCheck, .cognitiveProfile, .causalExtraction:
            return .preferLocal
        }
    }
}
