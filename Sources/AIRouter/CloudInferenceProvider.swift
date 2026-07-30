import Foundation

/// Antwort eines Cloud-Providers auf eine (nicht-streamende) Anfrage.
public struct CloudResponse: Sendable {
    public let text: String
    public let inputTokens: Int
    public let outputTokens: Int

    public init(text: String, inputTokens: Int, outputTokens: Int) {
        self.text = text
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Ereignis eines streamenden Cloud-Providers.
public enum CloudStreamEvent: Sendable {
    /// Ein Text-Fragment der Antwort.
    case text(String)
    /// Vom Anbieter gemeldete Token-Zaehler (typischerweise am Ende des Streams).
    case usage(input: Int, output: Int)
}

/// Abstraktion eines Cloud-Backends jenseits von Vertex AI.
///
/// Modelle, deren ``ModelDescriptor`` `provider: .custom("<id>")` traegt, werden
/// an den unter dieser ID registrierten Provider geleitet
/// (``AIRouter/registerCloudProvider(_:)``). Budget, Circuit-Breaker,
/// Retry-Policy, Preflight-Hook und Kosten-Telemetrie wendet der Router an —
/// der Provider implementiert nur Transport, Auth und Parsing.
public protocol CloudInferenceProvider: Sendable {
    /// Eindeutige ID, auf die `ModelDescriptor.provider = .custom(id)` verweist.
    var id: String { get }

    /// Nicht-streamende Generierung.
    func generate(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> CloudResponse

    /// Streamende Generierung. Der Stream liefert Text-Fragmente und (sofern
    /// vom Anbieter gemeldet) am Ende die Token-Zaehler.
    func stream(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> AsyncThrowingStream<CloudStreamEvent, Error>
}

// MARK: - OpenAI-kompatibler Provider

/// ``CloudInferenceProvider`` fuer jede OpenAI-kompatible Chat-Completions-API
/// (`POST <baseURL>/chat/completions`): OpenAI, Azure OpenAI, Groq, Together,
/// vLLM, LM Studio u. a.
///
/// Auth und Transport sind injizierbar; es ist nichts fest verdrahtet.
public struct OpenAICompatibleProvider: CloudInferenceProvider {
    /// Feldname fuer das Token-Limit: OpenAI hat `max_tokens` zugunsten von
    /// `max_completion_tokens` deprecated (o-Serie lehnt `max_tokens` ab);
    /// viele kompatible Server (vLLM, Groq, LM Studio) erwarten weiterhin
    /// `max_tokens`.
    public enum TokenLimitField: Sendable {
        case maxTokens
        case maxCompletionTokens
    }

    public let id: String
    private let baseURL: String
    private let apiKeyProvider: @Sendable () async throws -> String
    private let transport: HTTPTransport
    private let timeout: TimeInterval
    private let extraHeaders: [String: String]
    private let tokenLimitField: TokenLimitField
    private let allowInsecureHTTP: Bool

    /// - Parameters:
    ///   - id: Provider-ID fuer `ModelDescriptor.provider = .custom(id)`.
    ///   - baseURL: API-Basis inkl. Versionspfad, z. B. `https://api.openai.com/v1`.
    ///     `http://` ist nur fuer Loopback-/private Hosts zulaessig, sofern nicht
    ///     `allowInsecureHTTP` gesetzt ist (Keys nie im Klartext an fremde Hosts).
    ///   - apiKeyProvider: Liefert den Bearer-Key pro Request (rotierbar).
    ///   - transport: Injizierbarer HTTP-Transport (testbar ohne Netz).
    ///   - extraHeaders: Zusaetzliche Header (z. B. `api-key` fuer Azure).
    ///   - tokenLimitField: `.maxTokens` (Default, breite Kompatibilitaet) oder
    ///     `.maxCompletionTokens` (aktuelles OpenAI-Feld, noetig fuer o-Serie).
    ///   - allowInsecureHTTP: Erlaubt `http://` auch fuer nicht-private Hosts.
    public init(
        id: String = "openai",
        baseURL: String,
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        transport: HTTPTransport = URLSessionTransport(),
        timeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:],
        tokenLimitField: TokenLimitField = .maxTokens,
        allowInsecureHTTP: Bool = false
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
        self.timeout = timeout
        self.extraHeaders = extraHeaders
        self.tokenLimitField = tokenLimitField
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    private func makeRequest(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, stream: Bool) async throws -> URLRequest {
        guard let base = RouterValidation.validatedCloudBase(baseURL, allowInsecureHTTP: allowInsecureHTTP),
              let url = URL(string: "\(base)/chat/completions") else {
            throw AIRouterError.invalidEndpoint
        }

        var chatMessages: [[String: String]] = [["role": "system", "content": system]]
        chatMessages += messages.map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "messages": chatMessages
        ]
        switch tokenLimitField {
        case .maxTokens: body["max_tokens"] = maxTokens
        case .maxCompletionTokens: body["max_completion_tokens"] = maxTokens
        }
        if let temperature = options.temperature { body["temperature"] = temperature }
        if let topP = options.topP { body["top_p"] = topP }
        if !options.stopSequences.isEmpty { body["stop"] = options.stopSequences }
        if options.jsonMode { body["response_format"] = ["type": "json_object"] }
        if stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.requestTimeout ?? timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = try await apiKeyProvider()
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Hinweis: `GenerationOptions.topK` wird von Chat-Completions-APIs nicht
    /// unterstuetzt und daher ignoriert; alle uebrigen Optionen werden gemappt.
    public func generate(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> CloudResponse {
        let request = try await makeRequest(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: false)
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw AIRouterError.api(http.statusCode, data: data)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIRouterError.unexpectedResponse
        }
        let usage = json["usage"] as? [String: Any]
        return CloudResponse(
            text: text,
            inputTokens: usage?["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage?["completion_tokens"] as? Int ?? 0
        )
    }

    public func stream(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> AsyncThrowingStream<CloudStreamEvent, Error> {
        let request = try await makeRequest(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: true)
        let (lines, http) = try await transport.lines(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw AIRouterError.apiError(http.statusCode, "Streaming-Request fehlgeschlagen")
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let json = SSE.jsonPayload(from: line) else { continue }
                        if let choices = json["choices"] as? [[String: Any]],
                           let delta = choices.first?["delta"] as? [String: Any],
                           let text = delta["content"] as? String, !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                        if let usage = json["usage"] as? [String: Any] {
                            continuation.yield(.usage(
                                input: usage["prompt_tokens"] as? Int ?? 0,
                                output: usage["completion_tokens"] as? Int ?? 0
                            ))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Anthropic-Direkt-Provider

/// ``CloudInferenceProvider`` fuer die Anthropic-API ohne Vertex-Umweg
/// (`POST <baseURL>/v1/messages`, `x-api-key`-Auth).
public struct AnthropicDirectProvider: CloudInferenceProvider {
    public let id: String
    private let baseURL: String
    private let apiKeyProvider: @Sendable () async throws -> String
    private let transport: HTTPTransport
    private let timeout: TimeInterval
    private let apiVersion: String

    public init(
        id: String = "anthropic",
        baseURL: String = "https://api.anthropic.com",
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        transport: HTTPTransport = URLSessionTransport(),
        timeout: TimeInterval = 60,
        apiVersion: String = "2023-06-01"
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
        self.timeout = timeout
        self.apiVersion = apiVersion
    }

    private func makeRequest(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, stream: Bool) async throws -> URLRequest {
        guard let base = RouterValidation.validatedCloudBase(baseURL),
              let url = URL(string: "\(base)/v1/messages") else {
            throw AIRouterError.invalidEndpoint
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        ]
        if let temperature = options.temperature { body["temperature"] = temperature }
        if let topP = options.topP { body["top_p"] = topP }
        if let topK = options.topK { body["top_k"] = topK }
        if !options.stopSequences.isEmpty { body["stop_sequences"] = options.stopSequences }
        if stream { body["stream"] = true }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.requestTimeout ?? timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(try await apiKeyProvider(), forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func generate(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> CloudResponse {
        let request = try await makeRequest(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: false)
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw AIRouterError.api(http.statusCode, data: data)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String else {
            throw AIRouterError.unexpectedResponse
        }
        let usage = json["usage"] as? [String: Any]
        return CloudResponse(
            text: text,
            inputTokens: usage?["input_tokens"] as? Int ?? 0,
            outputTokens: usage?["output_tokens"] as? Int ?? 0
        )
    }

    public func stream(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> AsyncThrowingStream<CloudStreamEvent, Error> {
        let request = try await makeRequest(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: true)
        let (lines, http) = try await transport.lines(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw AIRouterError.apiError(http.statusCode, "Streaming-Request fehlgeschlagen")
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var inputTokens = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        guard let json = SSE.jsonPayload(from: line) else { continue }
                        let event = AnthropicStreamEvent(json: json)
                        if let text = event.text {
                            continuation.yield(.text(text))
                        }
                        if let input = event.inputTokens {
                            inputTokens = input
                        }
                        if let output = event.outputTokens {
                            continuation.yield(.usage(input: inputTokens, output: output))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
