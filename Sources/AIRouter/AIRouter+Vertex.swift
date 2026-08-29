import Foundation

extension AIRouter {
    // MARK: - Vertex AI

    struct CallResult {
        let text: String
        let inputTokens: Int
        let outputTokens: Int
    }

    func vertexEndpoint(model: String, provider: ModelDescriptor.Provider, streaming: Bool = false) throws -> URL {
        // Strikte Allowlists: Region landet im HOSTNAMEN, Projekt und Modell im
        // PFAD des Requests. Ohne Validierung koennte ein manipulierter Wert den
        // Request samt Bearer-Token auf einen fremden Host umleiten.
        guard RouterValidation.isValidRegion(vertexRegion) else {
            throw AIRouterError.notConfigured("Ungueltige Vertex-Region '\(vertexRegion)' (erlaubt: a-z, 0-9, '-').")
        }
        guard RouterValidation.isValidProject(vertexProject) else {
            throw AIRouterError.notConfigured("Ungueltige Vertex-Projekt-ID (erlaubt: a-z, 0-9, '-', '.', ':').")
        }
        guard RouterValidation.isValidModelName(model),
              let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw AIRouterError.notConfigured("Ungueltiger Modellname '\(model)' (erlaubt: Buchstaben, Ziffern, '-', '.', '_', '@').")
        }
        let region = vertexRegion
        let project = vertexProject
        let endpoint: String
        switch provider {
        case .anthropic:
            let method = streaming ? "streamRawPredict" : "rawPredict"
            endpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/anthropic/models/\(encodedModel):\(method)"
        case .google:
            let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"
            endpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(encodedModel):\(method)"
        case .local, .custom:
            throw AIRouterError.invalidEndpoint
        }
        guard let url = URL(string: endpoint) else {
            throw AIRouterError.invalidEndpoint
        }
        return url
    }

    /// Baut den kompletten Vertex-Request (Endpoint, Auth, Header, Body) —
    /// eine Stelle fuer den synchronen und den streamenden Pfad.
    func vertexRequest(model: String, provider: ModelDescriptor.Provider, streaming: Bool, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> URLRequest {
        let url = try vertexEndpoint(model: model, provider: provider, streaming: streaming)
        let accessToken = try await getAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.requestTimeout ?? cloudTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.vertexBody(provider: provider, system: system, messages: messages, maxTokens: maxTokens, options: options, stream: streaming && provider == .anthropic))
        return request
    }

    static func vertexBody(provider: ModelDescriptor.Provider, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, stream: Bool = false) -> [String: Any] {
        switch provider {
        case .anthropic:
            var body: [String: Any] = [
                "anthropic_version": "vertex-2023-10-16",
                "max_tokens": maxTokens,
                "system": system,
                "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }
            ]
            if let temperature = options.temperature { body["temperature"] = temperature }
            if let topP = options.topP { body["top_p"] = topP }
            if let topK = options.topK { body["top_k"] = topK }
            if !options.stopSequences.isEmpty { body["stop_sequences"] = options.stopSequences }
            if stream { body["stream"] = true }
            return body
        case .google:
            var generationConfig: [String: Any] = ["maxOutputTokens": maxTokens]
            if let temperature = options.temperature { generationConfig["temperature"] = temperature }
            if let topP = options.topP { generationConfig["topP"] = topP }
            if let topK = options.topK { generationConfig["topK"] = topK }
            if !options.stopSequences.isEmpty { generationConfig["stopSequences"] = options.stopSequences }
            if options.jsonMode { generationConfig["responseMimeType"] = "application/json" }
            return [
                "contents": messages.map {
                    ["role": $0.role == .assistant ? "model" : "user", "parts": [["text": $0.content]]]
                },
                "systemInstruction": ["parts": [["text": system]]],
                "generationConfig": generationConfig
            ]
        case .local, .custom:
            return [:]
        }
    }

    func callVertex(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
        if isLocalTag(model) {
            return try await callLocal(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task)
        }

        // Modelle mit .custom-Provider gehen an den registrierten
        // CloudInferenceProvider statt an Vertex.
        if case .custom(let providerID) = try descriptor(for: model).provider {
            return try await callCustom(providerID: providerID, model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task)
        }

        guard !vertexProject.isEmpty else {
            DebugLog.write("[AIRouter] Vertex AI Project nicht konfiguriert")
            throw AIRouterError.notConfigured("Vertex AI Project nicht konfiguriert")
        }

        // Preflight (z. B. PII-Redaktion) einmalig vor dem Versand anwenden.
        let (outboundSystem, outboundMessages) = preflightedOutbound(system: system, messages: messages)

        var currentModel = model
        var transientAttempts = 0
        var tokenRefreshed = false
        var fallbacksVisited: Set<String> = []
        let clock = ContinuousClock()

        while true {
            try Task.checkCancellation()

            // Circuit-Breaker: wiederholt fehlschlagende Modelle temporaer meiden.
            if breakerIsOpen(currentModel) {
                let desc = try descriptor(for: currentModel)
                if let fallback = desc.fallsBackTo, fallback != currentModel, !breakerIsOpen(fallback) {
                    DebugLog.write("[AIRouter] Circuit-Breaker: \(currentModel) gemieden, nutze \(fallback)")
                    currentModel = fallback
                    continue
                }
                throw AIRouterError.circuitOpen(model: currentModel)
            }

            let descriptor = try descriptor(for: currentModel)
            let request = try await vertexRequest(model: currentModel, provider: descriptor.provider, streaming: false, system: outboundSystem, messages: outboundMessages, maxTokens: maxTokens, options: options)

            let start = clock.now
            let (data, http): (Data, HTTPURLResponse)
            do {
                (data, http) = try await transport.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where Self.isTransientURLError(error) && transientAttempts < retryPolicy.maxTransientRetries {
                // Timeouts/Verbindungsabbrueche sind genauso transient wie 5xx.
                transientAttempts += 1
                DebugLog.write("[AIRouter] Transportfehler fuer \(currentModel) (Retry \(transientAttempts)): URLError \(error.code.rawValue)")
                try await Task.sleep(for: .seconds(Self.backoffDelay(policy: retryPolicy, attempt: transientAttempts)))
                continue
            } catch {
                recordFailure(currentModel)
                throw error
            }
            let elapsed = clock.now - start

            switch http.statusCode {
            case 200...299:
                recordSuccess(currentModel)
                let parsed = try Self.parseVertex(data: data, provider: descriptor.provider)
                emitUsage(task: task, model: currentModel, input: parsed.inputTokens, output: parsed.outputTokens, elapsed: elapsed)
                return parsed

            case 401 where !tokenRefreshed:
                // Token-Refresh verbraucht KEINEN transienten Retry.
                invalidateToken()
                tokenRefreshed = true
                continue

            case 404:
                // Modell-Fallback verbraucht KEINEN transienten Retry.
                // Zyklus-Schutz: jede Kette wird pro Modell nur einmal betreten.
                fallbacksVisited.insert(currentModel)
                if let fallback = descriptor.fallsBackTo, !fallbacksVisited.contains(fallback) {
                    DebugLog.write("[AIRouter] Modell \(currentModel) nicht gefunden, Fallback zu \(fallback)")
                    currentModel = fallback
                    continue
                }
                throw AIRouterError.api(404, data: data)

            case 429 where transientAttempts < retryPolicy.maxTransientRetries,
                 500...599 where transientAttempts < retryPolicy.maxTransientRetries:
                transientAttempts += 1
                let body = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[AIRouter] HTTP \(http.statusCode) fuer \(currentModel) (Retry \(transientAttempts)): \(body.prefix(120))")
                emitEvent(.retrying(model: currentModel, attempt: transientAttempts))
                try await Task.sleep(for: .seconds(Self.backoffDelay(policy: retryPolicy, attempt: transientAttempts)))
                continue

            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[AIRouter] HTTP \(http.statusCode) fuer \(currentModel): \(body.prefix(200))")
                if isTransientStatus(http.statusCode) {
                    recordFailure(currentModel)
                }
                throw AIRouterError.api(http.statusCode, data: data)
            }
        }
    }

    /// Netzwerkfehler, die einen Retry rechtfertigen (analog zu HTTP 429/5xx).
    static func isTransientURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Oeffnet den SSE-Stream. Ein 401 wird wie im synchronen Pfad einmal per
    /// Token-Refresh wiederholt — ein gerade abgelaufenes Cache-Token darf den
    /// Stream nicht hart scheitern lassen.
    func openVertexStream(model: String, provider: ModelDescriptor.Provider, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> AsyncThrowingStream<String, Error> {
        var tokenRefreshed = false
        while true {
            let request = try await vertexRequest(model: model, provider: provider, streaming: true, system: system, messages: messages, maxTokens: maxTokens, options: options)
            let (lines, http): (AsyncThrowingStream<String, Error>, HTTPURLResponse)
            do {
                (lines, http) = try await transport.lines(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                recordFailure(model)
                throw error
            }
            switch http.statusCode {
            case 200...299:
                return lines
            case 401 where !tokenRefreshed:
                invalidateToken()
                tokenRefreshed = true
            case 429, 500...599:
                recordFailure(model)
                throw AIRouterError.apiError(http.statusCode, "Streaming-Request fehlgeschlagen")
            default:
                throw AIRouterError.apiError(http.statusCode, "Streaming-Request fehlgeschlagen")
            }
        }
    }

    /// Natives Cloud-Streaming via SSE. Liefert die gemeldeten Token-Zaehler;
    /// fehlt der Output-Zaehler, wird grob aus der Zeichenzahl geschaetzt.
    func streamVertex(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws -> (input: Int, output: Int) {
        if breakerIsOpen(model) {
            throw AIRouterError.circuitOpen(model: model)
        }
        let desc = try descriptor(for: model)
        guard desc.provider != .local else { throw AIRouterError.invalidEndpoint }

        // Modelle mit .custom-Provider streamen ueber den registrierten
        // CloudInferenceProvider statt ueber Vertex.
        if case .custom(let providerID) = desc.provider {
            return try await streamCustom(providerID: providerID, model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task, continuation: continuation)
        }

        guard !vertexProject.isEmpty else {
            throw AIRouterError.notConfigured("Vertex AI Project nicht konfiguriert")
        }

        let (outboundSystem, outboundMessages) = preflightedOutbound(system: system, messages: messages)

        let clock = ContinuousClock()
        let start = clock.now
        let lines = try await openVertexStream(model: model, provider: desc.provider, system: outboundSystem, messages: outboundMessages, maxTokens: maxTokens, options: options)

        var inputTokens = 0
        var outputTokens = 0
        var charCount = 0

        do {
            for try await line in lines {
                try Task.checkCancellation()
                guard let json = SSE.jsonPayload(from: line) else { continue }
                switch desc.provider {
                case .anthropic:
                    let event = AnthropicStreamEvent(json: json)
                    if let text = event.text {
                        charCount += text.count
                        continuation.yield(text)
                    }
                    if let input = event.inputTokens { inputTokens = input }
                    if let output = event.outputTokens { outputTokens = output }
                case .google:
                    if let candidates = json["candidates"] as? [[String: Any]],
                       let first = candidates.first,
                       let content = first["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        // Alle Parts eines Chunks yielden, nicht nur den ersten.
                        let text = parts.compactMap { $0["text"] as? String }.joined()
                        if !text.isEmpty {
                            charCount += text.count
                            continuation.yield(text)
                        }
                    }
                    if let meta = json["usageMetadata"] as? [String: Any] {
                        inputTokens = meta["promptTokenCount"] as? Int ?? inputTokens
                        outputTokens = meta["candidatesTokenCount"] as? Int ?? outputTokens
                    }
                case .local, .custom:
                    // .custom wird oben an streamCustom dispatcht; hier unerreichbar.
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Abbrueche MITTEN im Stream zaehlen fuer Breaker und Statistik.
            recordFailure(model)
            throw error
        }

        recordSuccess(model)
        let elapsed = clock.now - start
        let estimated = outputTokens == 0 && charCount > 0
        if estimated { outputTokens = charCount / 4 }
        emitUsage(task: task, model: model, input: inputTokens, output: outputTokens, elapsed: elapsed, isEstimated: estimated)
        return (inputTokens, outputTokens)
    }
}
