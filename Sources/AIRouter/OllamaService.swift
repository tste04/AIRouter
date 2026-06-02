import Foundation

/// Beschreibt ein lokal installiertes Ollama-Modell.
public struct OllamaModel: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let size: Int64
    public let parameterSize: String

    public init(name: String, size: Int64, parameterSize: String) {
        self.name = name
        self.size = size
        self.parameterSize = parameterSize
    }

    public var displayName: String {
        let parts = name.split(separator: ":")
        let base = String(parts.first ?? Substring(name))
        let tag = parts.count > 1 ? String(parts.last!) : "latest"
        return tag == "latest" ? base : "\(base) (\(tag))"
    }

    public var sizeLabel: String {
        let gb = Double(size) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(size) / 1_048_576)
    }
}

/// Minimaler Ollama-Client zur Modell-Discovery (`/api/tags`).
///
/// Die eigentliche Inferenz wird vom ``AIRouter`` direkt gegen `/api/chat`
/// gesprochen; dieser Service dient nur der Auto-Erkennung installierter Modelle.
public actor OllamaService {
    public static let shared = OllamaService()

    private var cachedModels: [OllamaModel] = []
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 60

    public init() {}

    /// Laedt die Liste installierter Modelle vom Ollama-Endpoint. Ergebnisse
    /// werden fuer 60 Sekunden gecached. Bei Fehlern wird ein leeres Array geliefert.
    public func fetchModels(endpoint: String) async -> [OllamaModel] {
        if let ts = cacheTimestamp, Date().timeIntervalSince(ts) < cacheTTL, !cachedModels.isEmpty {
            return cachedModels
        }

        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/tags") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return []
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                return []
            }

            cachedModels = models.compactMap { dict -> OllamaModel? in
                guard let name = dict["name"] as? String else { return nil }
                let size = dict["size"] as? Int64 ?? 0
                let details = dict["details"] as? [String: Any]
                let parameterSize = details?["parameter_size"] as? String ?? ""
                return OllamaModel(name: name, size: size, parameterSize: parameterSize)
            }
            cacheTimestamp = Date()
            return cachedModels
        } catch {
            return []
        }
    }
}
