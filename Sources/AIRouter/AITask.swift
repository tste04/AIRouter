import Foundation

/// Logische KI-Aufgabe. Jede Aufgabe besitzt ein Standardmodell, ein Token-Budget,
/// eine Prioritaet und eine Routing-Policy (siehe ``AITask/routingPolicy``).
public enum AITask: String, CaseIterable, Codable, Identifiable, Sendable {
    public var id: String { rawValue }
    case eventClassification
    case meetingProfiling
    case relevanceAssessment
    case dossierSynthesis
    case readoutCompression
    case daySynthesis
    case emailRelevance
    case noteRelevance
    case documentAnalysis
    case advisorRealtime
    case coachRealtime
    case copilotRealtime
    case meetingSummary
    case transcriptPolishing
    case entityExtraction
    case factCheck
    case reflection
    case sentimentAnalysis
    case bundleEntityExtraction
    case bundleSynthesis
    case attachmentAnalysis
    case bundleChangelog
    case memoryFactExtraction
    case memorySynthesis
    case openLoopDetection
    case memoryQuery
    case contradictionCheck
    case cognitiveProfile
    case causalExtraction

    public var defaultModel: String {
        switch self {
        case .dossierSynthesis:
            return "claude-opus-4-6"
        case .meetingSummary, .daySynthesis, .documentAnalysis:
            return "gemini-2.5-flash"
        case .advisorRealtime, .coachRealtime, .copilotRealtime, .eventClassification, .meetingProfiling,
             .relevanceAssessment, .emailRelevance, .noteRelevance,
             .readoutCompression, .transcriptPolishing:
            return "gemini-2.5-flash"
        case .entityExtraction, .factCheck, .sentimentAnalysis:
            return "gemini-2.5-flash"
        case .reflection:
            return "gemini-2.5-flash"
        case .bundleEntityExtraction, .attachmentAnalysis, .bundleChangelog:
            return "gemini-2.5-flash"
        case .bundleSynthesis:
            return "gemini-2.5-pro"
        case .memoryFactExtraction, .openLoopDetection:
            return "gemini-2.5-flash"
        case .memorySynthesis:
            return "gemini-2.5-pro"
        case .memoryQuery:
            return "gemini-2.5-flash"
        case .contradictionCheck, .causalExtraction:
            return "gemini-2.5-flash"
        case .cognitiveProfile:
            return "gemini-2.5-flash"
        }
    }

    public var defaultMaxTokens: Int {
        switch self {
        case .dossierSynthesis: return 2048
        case .meetingSummary: return 1024
        case .transcriptPolishing: return 4096
        case .advisorRealtime: return 1200
        case .coachRealtime: return 512
        case .copilotRealtime: return 1500
        case .daySynthesis: return 1024
        case .readoutCompression: return 1024
        case .eventClassification, .meetingProfiling: return 512
        case .relevanceAssessment, .emailRelevance, .noteRelevance: return 256
        case .documentAnalysis: return 512
        case .entityExtraction: return 1024
        case .factCheck: return 512
        case .reflection: return 1024
        case .sentimentAnalysis: return 256
        case .bundleEntityExtraction: return 2048
        case .bundleSynthesis: return 4096
        case .attachmentAnalysis: return 1024
        case .bundleChangelog: return 2048
        case .memoryFactExtraction: return 2048
        case .memorySynthesis: return 4096
        case .openLoopDetection: return 1024
        case .memoryQuery: return 1024
        case .contradictionCheck: return 256
        case .cognitiveProfile: return 256
        case .causalExtraction: return 512
        }
    }

    public var displayName: String {
        switch self {
        case .eventClassification: return "Event-Klassifikation"
        case .meetingProfiling: return "Meeting-Profiling"
        case .relevanceAssessment: return "Relevanz-Bewertung"
        case .dossierSynthesis: return "Dossier-Synthese"
        case .readoutCompression: return "Readout-Kompression"
        case .daySynthesis: return "Tages-Synthese"
        case .emailRelevance: return "E-Mail-Relevanz"
        case .noteRelevance: return "Notiz-Relevanz"
        case .documentAnalysis: return "Dokument-Analyse"
        case .advisorRealtime: return "Live-Advisor"
        case .coachRealtime: return "Live-Coach"
        case .copilotRealtime: return "Meeting-Copilot"
        case .meetingSummary: return "Meeting-Summary"
        case .transcriptPolishing: return "Transkript-Polishing"
        case .entityExtraction: return "Entity-Extraktion"
        case .factCheck: return "Fact-Check"
        case .reflection: return "Reflection"
        case .sentimentAnalysis: return "Sentiment-Analyse"
        case .bundleEntityExtraction: return "Bundle-Entity-Extraktion"
        case .bundleSynthesis: return "Bundle-Synthese"
        case .attachmentAnalysis: return "Attachment-Analyse"
        case .bundleChangelog: return "Bundle-Changelog"
        case .memoryFactExtraction: return "Memory-Fakten-Extraktion"
        case .memorySynthesis: return "Memory-Synthese"
        case .openLoopDetection: return "Open-Loop-Erkennung"
        case .memoryQuery: return "Memory-Suche"
        case .contradictionCheck: return "Widerspruchs-Pruefung"
        case .cognitiveProfile: return "Kognitivprofil"
        case .causalExtraction: return "Kausal-Extraktion"
        }
    }
}

/// Prioritaet einer KI-Aufgabe. Beeinflusst Budget-Throttling.
public enum AITaskPriority: Int, Comparable, Sendable {
    case critical = 0
    case high = 1
    case normal = 2
    case low = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension AITask {
    public var priority: AITaskPriority {
        switch self {
        case .dossierSynthesis, .advisorRealtime, .coachRealtime, .copilotRealtime, .meetingSummary:
            return .critical
        case .daySynthesis, .readoutCompression, .meetingProfiling, .reflection:
            return .high
        case .emailRelevance, .noteRelevance, .eventClassification, .relevanceAssessment, .sentimentAnalysis:
            return .normal
        case .transcriptPolishing:
            return .normal
        case .bundleEntityExtraction, .attachmentAnalysis, .bundleChangelog,
             .bundleSynthesis, .entityExtraction, .factCheck, .documentAnalysis,
             .memoryFactExtraction, .memorySynthesis, .openLoopDetection:
            return .low
        case .memoryQuery:
            return .normal
        case .contradictionCheck, .cognitiveProfile, .causalExtraction:
            return .low
        }
    }
}
