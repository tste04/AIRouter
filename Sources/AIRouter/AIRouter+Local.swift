import Foundation

extension AIRouter {
    // MARK: - Local inference

    /// Fasst einen Konversationsverlauf fuer den bewusst minimalen
    /// ``LocalInferenceProvider`` (system+user-Signatur) zu einem Prompt zusammen.
    static func flattenForLocalProvider(_ messages: [AIMessage]) -> String {
        if messages.count == 1, let only = messages.first { return only.content }
        return messages.map { message in
            (message.role == .assistant ? "Assistant: " : "User: ") + message.content
        }.joined(separator: "\n\n")
    }

    func callLocal(model modelTag: String = "local", system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
        if let provider = localProvider, await provider.isReady {
            return try await callLocalProvider(provider: provider, system: system, messages: messages, maxTokens: maxTokens, task: task)
        }
        return try await callOllama(modelTag: modelTag, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task)
    }

    func callLocalProvider(provider: LocalInferenceProvider, system: String, messages: [AIMessage], maxTokens: Int, task: AITask?) async throws -> CallResult {
        let clock = ContinuousClock()
        let start = clock.now
        let user = Self.flattenForLocalProvider(messages)
        let result = try await provider.generate(system: system, user: user, maxTokens: maxTokens)
        let elapsed = clock.now - start
        emitUsage(task: task, model: "local-provider", input: result.inputTokens, output: result.outputTokens, elapsed: elapsed)
        return CallResult(text: result.text, inputTokens: result.inputTokens, outputTokens: result.outputTokens)
    }

    func ollamaChatBody(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, stream: Bool) -> [String: Any] {
        var chatMessages: [[String: String]] = [["role": "system", "content": system]]
        chatMessages += messages.map { ["role": $0.role.rawValue, "content": $0.content] }

        var modelOptions: [String: Any] = [
            "num_ctx": localLLMNumCtx,
            "num_predict": maxTokens,
            "num_batch": 512,
            "num_gpu": 999,
            "temperature": options.temperature ?? 0.3,
            "top_k": options.topK ?? 20,
            "top_p": options.topP ?? 0.9
        ]
        if !options.stopSequences.isEmpty { modelOptions["stop"] = options.stopSequences }

        var body: [String: Any] = [
            "model": model,
            "messages": chatMessages,
            "stream": stream,
            "keep_alive": localLLMKeepAlive,
            "options": modelOptions
        ]
        if options.jsonMode { body["format"] = "json" }
        return body
    }

    func resolveLocalModel(_ modelTag: String) throws -> String {
        if modelTag.hasPrefix("local:") {
            let stripped = String(modelTag.dropFirst(6))
            if !stripped.isEmpty { return stripped }
        }
        if !localLLMModel.isEmpty { return localLLMModel }
        throw AIRouterError.notConfigured("Kein lokales Modell konfiguriert. Rufe configureLocalLLM(endpoint:model:) auf.")
    }

    func ollamaURL(path: String) throws -> URL {
        guard !localLLMEndpoint.isEmpty else {
            throw AIRouterError.notConfigured("Weder ein lokaler Provider noch Ollama verfuegbar. Konfiguriere einen LocalInferenceProvider oder einen Ollama-Endpoint.")
        }
        // Defense in depth: configureLocalLLM validiert bereits, hier erneut
        // pruefen, falls der Endpoint auf anderem Weg gesetzt wurde.
        guard let base = RouterValidation.validatedCloudBase(localLLMEndpoint, allowInsecureHTTP: localAllowInsecureHTTP),
              let url = URL(string: "\(base)\(path)") else {
            throw AIRouterError.invalidEndpoint
        }
        return url
    }

    func callOllama(modelTag: String = "local", system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
        let url = try ollamaURL(path: "/api/chat")
        let model = try resolveLocalModel(modelTag)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = options.requestTimeout ?? localTimeout
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ollamaChatBody(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: false))

        let clock = ContinuousClock()
        let start = clock.now
        let (data, http) = try await localTransport.data(for: request)
        let elapsed = clock.now - start

        guard (200...299).contains(http.statusCode) else {
            throw AIRouterError.api(http.statusCode, data: data)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIRouterError.unexpectedResponse
        }

        let inputTokens = json["prompt_eval_count"] as? Int ?? 0
        let outputTokens = json["eval_count"] as? Int ?? 0
        emitUsage(task: task, model: "local:\(model)", input: inputTokens, output: outputTokens, elapsed: elapsed)
        return CallResult(text: text, inputTokens: inputTokens, outputTokens: outputTokens)
    }


    // MARK: - Streaming (lokal)

    func streamLocal(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        if let provider = localProvider, await provider.isReady {
            try await streamLocalProvider(provider: provider, system: system, messages: messages, maxTokens: maxTokens, task: task, continuation: continuation)
            return
        }
        try await streamOllama(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task, continuation: continuation)
    }

    func streamLocalProvider(provider: LocalInferenceProvider, system: String, messages: [AIMessage], maxTokens: Int, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var charCount = 0
        let user = Self.flattenForLocalProvider(messages)
        let stream = provider.generateStream(system: system, user: user, maxTokens: maxTokens)
        for try await chunk in stream {
            charCount += chunk.count
            continuation.yield(chunk)
        }
        let elapsed = clock.now - start
        // Lokales Streaming liefert keine exakten Token-Zaehler -> grobe Schaetzung.
        emitUsage(task: task, model: "local-provider", input: 0, output: charCount / 4, elapsed: elapsed, isEstimated: true)
    }

    func streamOllama(model modelTag: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let url = try ollamaURL(path: "/api/chat")
        let model = try resolveLocalModel(modelTag)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = options.requestTimeout ?? localTimeout
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ollamaChatBody(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: true))

        let clock = ContinuousClock()
        let start = clock.now
        let (lines, http) = try await localTransport.lines(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw AIRouterError.apiError(http.statusCode, "Streaming-Request fehlgeschlagen")
        }

        var inputTokens = 0
        var outputTokens = 0
        for try await line in lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                continuation.yield(content)
            }
            if let promptEval = json["prompt_eval_count"] as? Int { inputTokens = promptEval }
            if let evalCount = json["eval_count"] as? Int { outputTokens = evalCount }
            if json["done"] as? Bool == true { break }
        }
        let elapsed = clock.now - start
        emitUsage(task: task, model: "local:\(model)", input: inputTokens, output: outputTokens, elapsed: elapsed)
    }
}
