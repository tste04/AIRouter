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
    public let id: String
    private let baseURL: String
    private let apiKeyProvider: @Sendable () async throws -> String
    private let transport: HTTPTransport
    private let timeout: TimeInterval
    private let extraHeaders: [String: String]

    /// - Parameters:
    ///   - id: Provider-ID fuer `ModelDescriptor.provider = .custom(id)`.
    ///   - baseURL: API-Basis inkl. Versionspfad, z. B. `https://api.openai.com/v1`.
    ///   - apiKeyProvider: Liefert den Bearer-Key pro Request (rotierbar).
    ///   - transport: Injizierbarer HTTP-Transport (testbar ohne Netz).
    ///   - extraHeaders: Zusaetzliche Header (z. B. `api-key` fuer Azure).
    public init(
        id: String = "openai",
        baseURL: String,
        apiKeyProvider: @escaping @Sendable () async throws -> String,
        transport: HTTPTransport = URLSessionTransport(),
        timeout: TimeInterval = 60,
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
        self.timeout = timeout
        self.extraHeaders = extraHeaders
    }

    private func makeRequest(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, stream: Bool) async throws -> URLRequest {
        guard let base = RouterValidation.validatedHTTPBase(baseURL),
              let url = URL(string: "\(base)/chat/completions") else {
            throw AIRouterError.invalidEndpoint
        }

        var chatMessages: [[String: String]] = [["role": "system", "content": system]]
        chatMessages += messages.map { ["role": $0.role.rawValue, "content": $0.content] }

        var body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
            "max_tokens": maxTokens
        ]
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

    public func generate(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> CloudResponse {
        let request = try await makeRequest(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: false)
        let (data, http) = try await transport.data(for: request)
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIRouterError.apiError(http.statusCode, String(body.prefix(500)))
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
            throw AIRouterError.apiError(http.statusCode, "Streaming request failed")
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
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
        guard let base = RouterValidation.validatedHTTPBase(baseURL),
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
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIRouterError.apiError(http.statusCode, String(body.prefix(500)))
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
            throw AIRouterError.apiError(http.statusCode, "Streaming request failed")
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var inputTokens = 0
                    for try await line in lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard !payload.isEmpty,
                              let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        switch json["type"] as? String {
                        case "content_block_delta":
                            if let delta = json["delta"] as? [String: Any],
                               let text = delta["text"] as? String, !text.isEmpty {
                                continuation.yield(.text(text))
                            }
                        case "message_start":
                            if let message = json["message"] as? [String: Any],
                               let usage = message["usage"] as? [String: Any],
                               let input = usage["input_tokens"] as? Int {
                                inputTokens = input
                            }
                        case "message_delta":
                            if let usage = json["usage"] as? [String: Any],
                               let output = usage["output_tokens"] as? Int {
                                continuation.yield(.usage(input: inputTokens, output: output))
                            }
                        default:
                            break
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
