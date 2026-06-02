import Foundation

/// Abstraktion fuer einen In-Process-Anbieter lokaler Inferenz (z. B. ein
/// On-Device-Sprachmodell). Der ``AIRouter`` bevorzugt einen konfigurierten
/// Provider vor dem Ollama-HTTP-Pfad.
///
/// Durch die Protokoll-Abstraktion bleibt der Router standalone und ohne harte
/// Abhaengigkeit zu einem konkreten Inferenz-Framework nutzbar.
public protocol LocalInferenceProvider: Sendable {
    /// Ob ein Modell geladen und einsatzbereit ist.
    var isReady: Bool { get async }

    /// Synchrone (nicht-streamende) Generierung. Liefert Text und Token-Zaehler.
    func generate(system: String, user: String, maxTokens: Int) async throws
        -> (text: String, inputTokens: Int, outputTokens: Int)

    /// Token-weises Streaming.
    func generateStream(system: String, user: String, maxTokens: Int)
        -> AsyncThrowingStream<String, Error>
}
