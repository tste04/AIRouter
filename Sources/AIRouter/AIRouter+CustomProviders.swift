import Foundation

extension AIRouter {
    // MARK: - Custom cloud providers

    func customProvider(for id: String) throws -> CloudInferenceProvider {
        guard let provider = customProviders[id] else {
            throw AIRouterError.notConfigured("Kein CloudInferenceProvider mit ID '\(id)' registriert. Rufe registerCloudProvider(_:) auf.")
        }
        return provider
    }

    func isTransientStatus(_ status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// Nicht-streamender Aufruf eines registrierten Providers. Router-seitig
    /// gelten Breaker, Retry-Policy, Preflight und Telemetrie wie bei Vertex.
    func callCustom(providerID: String, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
        let provider = try customProvider(for: providerID)
        let (outboundSystem, outboundMessages) = preflightedOutbound(system: system, messages: messages)

        var transientAttempts = 0
        let clock = ContinuousClock()

        while true {
            try Task.checkCancellation()

            if breakerIsOpen(model) {
                throw AIRouterError.circuitOpen(model: model)
            }

            let start = clock.now
            do {
                let response = try await provider.generate(model: model, system: outboundSystem, messages: outboundMessages, maxTokens: maxTokens, options: options)
                recordSuccess(model)
                emitUsage(task: task, model: model, input: response.inputTokens, output: response.outputTokens, elapsed: clock.now - start)
                return CallResult(text: response.text, inputTokens: response.inputTokens, outputTokens: response.outputTokens)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as AIRouterError {
                if case .apiError(let status, let body) = error, isTransientStatus(status) {
                    if transientAttempts < retryPolicy.maxTransientRetries {
                        transientAttempts += 1
                        DebugLog.write("[AIRouter] HTTP \(status) fuer \(model) via '\(providerID)' (Retry \(transientAttempts)): \(body.prefix(120))")
                        emitEvent(.retrying(model: model, attempt: transientAttempts))
                        try await Task.sleep(for: .seconds(Self.backoffDelay(policy: retryPolicy, attempt: transientAttempts)))
                        continue
                    }
                    recordFailure(model)
                }
                throw error
            } catch {
                recordFailure(model)
                throw error
            }
        }
    }

    /// Streamender Aufruf eines registrierten Providers (ohne Retries —
    /// ein teilweise konsumierter Stream ist nicht wiederholbar).
    func streamCustom(providerID: String, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws -> (input: Int, output: Int) {
        let provider = try customProvider(for: providerID)
        let (outboundSystem, outboundMessages) = preflightedOutbound(system: system, messages: messages)

        let clock = ContinuousClock()
        let start = clock.now
        var inputTokens = 0
        var outputTokens = 0
        var charCount = 0

        do {
            let events = try await provider.stream(model: model, system: outboundSystem, messages: outboundMessages, maxTokens: maxTokens, options: options)
            for try await event in events {
                try Task.checkCancellation()
                switch event {
                case .text(let text):
                    charCount += text.count
                    continuation.yield(text)
                case .usage(let input, let output):
                    inputTokens = input
                    outputTokens = output
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
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

    static func parseVertex(data: Data, provider: ModelDescriptor.Provider) throws -> CallResult {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIRouterError.unexpectedResponse
        }
        switch provider {
        case .anthropic:
            guard let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                throw AIRouterError.unexpectedResponse
            }
            let usage = json["usage"] as? [String: Any]
            return CallResult(
                text: text,
                inputTokens: usage?["input_tokens"] as? Int ?? 0,
                outputTokens: usage?["output_tokens"] as? Int ?? 0
            )
        case .google:
            guard let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                throw AIRouterError.unexpectedResponse
            }
            // Mehrteilige Antworten vollstaendig zusammensetzen statt nur parts[0].
            let texts = parts.compactMap { $0["text"] as? String }
            guard !texts.isEmpty else { throw AIRouterError.unexpectedResponse }
            let text = texts.joined()
            let meta = json["usageMetadata"] as? [String: Any]
            return CallResult(
                text: text,
                inputTokens: meta?["promptTokenCount"] as? Int ?? 0,
                outputTokens: meta?["candidatesTokenCount"] as? Int ?? 0
            )
        case .local, .custom:
            throw AIRouterError.unexpectedResponse
        }
    }
}
