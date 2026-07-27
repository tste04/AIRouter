import Foundation

/// Gemeinsame Helfer fuer Server-Sent-Events — genutzt vom Vertex-Streaming
/// und den Direkt-Providern (Anthropic, OpenAI-kompatibel).
enum SSE {
    /// Extrahiert das JSON-Objekt einer `data:`-Zeile. Liefert `nil` fuer
    /// leere Zeilen, fremde SSE-Felder und das `[DONE]`-Sentinel.
    static func jsonPayload(from line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]",
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}

/// Ein dekodiertes Anthropic-Streaming-Event. Das Format ist auf Vertex
/// (`:streamRawPredict`) und der direkten API (`/v1/messages`) identisch.
struct AnthropicStreamEvent {
    var text: String?
    var inputTokens: Int?
    var outputTokens: Int?

    init(json: [String: Any]) {
        switch json["type"] as? String {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let deltaText = delta["text"] as? String, !deltaText.isEmpty {
                text = deltaText
            }
        case "message_start":
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any] {
                inputTokens = usage["input_tokens"] as? Int
            }
        case "message_delta":
            if let usage = json["usage"] as? [String: Any] {
                outputTokens = usage["output_tokens"] as? Int
            }
        default:
            break
        }
    }
}
