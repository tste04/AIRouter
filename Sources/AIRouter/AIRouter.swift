import Foundation

/// Nutzungs-Telemetrie eines einzelnen KI-Aufrufs.
public struct AIUsageInfo: Sendable {
    public let task: AITask?
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let timestamp: Date
    public let durationMs: Int
    /// `true`, wenn die Token-Zahlen geschaetzt sind (z. B. lokales Streaming ohne
    /// exakte Zaehler), statt vom Anbieter gemeldet.
    public let isEstimated: Bool

    public init(
        task: AITask?,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        timestamp: Date,
        durationMs: Int,
        isEstimated: Bool = false
    ) {
        self.task = task
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.isEstimated = isEstimated
    }
}

/// Zentraler Router, der KI-Aufgaben anhand von Energiemodus, Routing-Policy und
/// Token-Budget auf Cloud-Modelle (Vertex AI: Anthropic/Google) oder lokale
/// Modelle (In-Process-Provider oder Ollama-HTTP) verteilt.
///
/// Standalone, projektunabhaengig:
/// - Die lokale In-Process-Inferenz ist hinter ``LocalInferenceProvider`` abstrahiert.
/// - Der HTTP-Transport ist ueber ``HTTPTransport`` injizierbar (testbar ohne Netz).
/// - Die Vertex-Authentifizierung wird ausschliesslich ueber den injizierbaren
///   ``AccessTokenProvider`` bereitgestellt; es ist keine Auth-Strategie fest verdrahtet.
/// - Bekannte Modelle stehen im ``ModelCatalog``; unbekannte Modelle fuehren zu
///   einem Fehler statt zu stiller Fehl-Zuordnung.
public actor AIRouter {
    /// Liefert ein OAuth2-Access-Token (inkl. Ablaufzeitpunkt) fuer Vertex AI.
    public typealias AccessTokenProvider = @Sendable () async throws -> AccessToken

    private let vertexRegion: String
    private let vertexProject: String
    private let taskModels: [AITask: String]
    private let taskRoutingPolicies: [AITask: RoutingPolicy]
    private let accessTokenProvider: AccessTokenProvider?
    private let transport: HTTPTransport
    private let localTransport: HTTPTransport
    private var catalog: ModelCatalog

    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private var usageCallback: (@Sendable (AIUsageInfo) -> Void)?

    private var localLLMEndpoint: String = ""
    private var localLLMModel: String = ""
    private var localLLMNumCtx: Int = 4096
    private let localLLMKeepAlive: String = "24h"
    private var airplaneMode: Bool = false
    private var energyMode: EnergyMode = .fullPower
    private var localProvider: LocalInferenceProvider?

    private let cloudTimeout: TimeInterval = 60
    private let localTimeout: TimeInterval = 120

    /// Dedizierte, gepoolte Session fuer lokale Inferenz (HTTP keep-alive zu localhost).
    private static let ollamaSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 120
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Budget

    private var hourlyTokenBudget: Int = 200_000
    private var tokensUsedThisHour: Int = 0
    private var reservedTokens: Int = 0
    private var currentHourStart: Date = Date()
    private var throttledTasks: Int = 0

    /// - Parameters:
    ///   - vertexRegion: Vertex-AI-Region (z. B. `us-central1`).
    ///   - vertexProject: GCP-Projekt-ID.
    ///   - taskModels: Optionale Modell-Overrides pro Task.
    ///   - taskRoutingPolicies: Optionale Policy-Overrides pro Task.
    ///   - accessTokenProvider: Liefert das OAuth2-Token fuer Vertex AI. Wird fuer
    ///     Cloud-Aufrufe benoetigt; `nil` ist nur fuer reine Lokal-Nutzung zulaessig.
    ///   - transport: HTTP-Transport fuer Cloud-Aufrufe (Default: `URLSession.shared`).
    ///   - additionalModels: Eigene Modelle, die dem Standardkatalog hinzugefuegt
    ///     bzw. die Defaults ueberschreiben.
    public init(
        vertexRegion: String,
        vertexProject: String,
        taskModels: [AITask: String] = [:],
        taskRoutingPolicies: [AITask: RoutingPolicy] = [:],
        accessTokenProvider: AccessTokenProvider? = nil,
        transport: HTTPTransport? = nil,
        additionalModels: [String: ModelDescriptor] = [:]
    ) {
        self.vertexRegion = vertexRegion
        self.vertexProject = vertexProject
        self.taskModels = taskModels
        self.taskRoutingPolicies = taskRoutingPolicies
        self.accessTokenProvider = accessTokenProvider
        self.transport = transport ?? URLSessionTransport()
        self.localTransport = transport ?? URLSessionTransport(session: AIRouter.ollamaSession)
        var catalog = ModelCatalog.default
        catalog.merge(additionalModels)
        self.catalog = catalog
    }

    // MARK: - Configuration

    public func configureLocalLLM(endpoint: String, model: String, numCtx: Int = 4096) async {
        self.localLLMEndpoint = endpoint
        self.localLLMNumCtx = max(512, numCtx)

        // Kein Modell gewaehlt -> automatisch ein installiertes Ollama-Modell entdecken.
        var resolved = model
        if resolved.isEmpty && !endpoint.isEmpty {
            let available = await OllamaService.shared.fetchModels(endpoint: endpoint)
            resolved = available.first(where: { $0.name.lowercased().contains("gemma") })?.name
                ?? available.first(where: { $0.name.lowercased().contains("qwen") })?.name
                ?? available.first?.name
                ?? ""
            if !resolved.isEmpty {
                DebugLog.write("[AIRouter] Kein localLLMModel gesetzt -> automatisch gewaehlt: \(resolved)")
            }
        }
        self.localLLMModel = resolved

        if !endpoint.isEmpty {
            DebugLog.write("[AIRouter] Local LLM konfiguriert: \(endpoint) (\(resolved.isEmpty ? "kein Modell" : resolved), num_ctx=\(self.localLLMNumCtx))")
        }
    }

    /// Konfiguriert einen In-Process-Anbieter lokaler Inferenz.
    public func configureLocalProvider(_ provider: LocalInferenceProvider) {
        self.localProvider = provider
        DebugLog.write("[AIRouter] LocalInferenceProvider konfiguriert")
    }

    public func isLocalModelReady() async -> Bool {
        if let provider = localProvider, await provider.isReady { return true }
        return !localLLMEndpoint.isEmpty
    }

    public func localLLMEndpointValue() -> String {
        localLLMEndpoint
    }

    public func setUsageCallback(_ callback: @escaping @Sendable (AIUsageInfo) -> Void) {
        self.usageCallback = callback
    }

    public func setEnergyMode(_ mode: EnergyMode) {
        energyMode = mode
        airplaneMode = mode == .offline
        DebugLog.write("[AIRouter] Energiemodus: \(mode.displayName) (offline=\(airplaneMode), maxCloud=\(mode == .maxCloud))")
    }

    public func setAirplaneMode(_ enabled: Bool) {
        airplaneMode = enabled
    }

    public func setHourlyBudget(_ tokens: Int) {
        hourlyTokenBudget = max(10_000, tokens)
    }

    public func warmup() async {
        _ = try? await getAccessToken()
    }

    // MARK: - Public API

    public func send(task: AITask, system: String, user: String, maxTokens: Int? = nil) async throws -> String {
        let model = resolveModel(for: task)
        let tokens = effectiveMaxTokens(task: task, requested: maxTokens)
        let estimate = tokens * 4
        let policy = taskRoutingPolicies[task] ?? task.routingPolicy

        // preferLocal: erst lokal, bei Fehler (ausser Cancellation) Cloud-Fallback.
        if isLocalTag(model) && policy == .preferLocal {
            do {
                return try await callLocal(model: model, system: system, user: user, maxTokens: tokens, task: task).text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.write("[AIRouter] Local fehlgeschlagen fuer \(task.rawValue), Fallback zu Cloud: \(String(describing: error).prefix(80))")
                return try await runCloud(task: task, model: task.defaultModel, system: system, user: user, maxTokens: tokens, estimate: estimate)
            }
        }

        // Rein lokal (kein Budget).
        if isLocalTag(model) {
            return try await callLocal(model: model, system: system, user: user, maxTokens: tokens, task: task).text
        }

        // Cloud mit Budget; bei Budget-Erschoepfung optional lokal.
        do {
            return try await runCloud(task: task, model: model, system: system, user: user, maxTokens: tokens, estimate: estimate)
        } catch let error as AIRouterError {
            if case .budgetExhausted = error, localProvider != nil || !localLLMEndpoint.isEmpty {
                DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), Fallback zu lokal")
                return try await callLocal(model: localModelTag, system: system, user: user, maxTokens: tokens, task: task).text
            }
            throw error
        }
    }

    public func send(model: String, system: String, user: String, maxTokens: Int) async throws -> String {
        let effectiveModel = airplaneMode ? localModelTag : model
        if isLocalTag(effectiveModel) {
            return try await callLocal(model: effectiveModel, system: system, user: user, maxTokens: maxTokens, task: nil).text
        }
        return try await callVertex(model: effectiveModel, system: system, user: user, maxTokens: maxTokens, task: nil).text
    }

    public func resolvedModelName(for task: AITask) -> String {
        resolveModel(for: task)
    }

    public func sendStreaming(task: AITask, system: String, user: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let model = self.resolveModel(for: task)
                let tokens = self.effectiveMaxTokens(task: task, requested: maxTokens)

                // In-Process-Provider streamt direkt (schnellster lokaler Pfad).
                if let provider = self.localProvider, await provider.isReady {
                    do {
                        try await self.streamLocalProvider(provider: provider, system: system, user: user, maxTokens: tokens, task: task, continuation: continuation)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // Ollama nativ /api/chat streamt token-weise.
                let endpoint = self.localLLMEndpointValue()
                if self.isLocalTag(model) && !endpoint.isEmpty {
                    do {
                        try await self.streamOllama(model: model, system: system, user: user, maxTokens: tokens, task: task, continuation: continuation)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // Cloud: kein natives Streaming -> Vollantwort ueber send() (inkl. Budget).
                do {
                    let response = try await self.send(task: task, system: system, user: user, maxTokens: maxTokens)
                    continuation.yield(response)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public struct BudgetStatus: Sendable {
        public let tokensUsed: Int
        public let tokensReserved: Int
        public let tokenBudget: Int
        public let throttledCount: Int
        public let hourStarted: Date
        public var remaining: Int { max(0, tokenBudget - tokensUsed - tokensReserved) }
        public var utilization: Double { tokenBudget > 0 ? Double(tokensUsed + tokensReserved) / Double(tokenBudget) : 0 }
        public var minutesUntilReset: Int { max(0, Int((3600 - Date().timeIntervalSince(hourStarted)) / 60)) }
    }

    public func budgetStatus() -> BudgetStatus {
        resetHourIfNeeded()
        return BudgetStatus(
            tokensUsed: tokensUsedThisHour,
            tokensReserved: reservedTokens,
            tokenBudget: hourlyTokenBudget,
            throttledCount: throttledTasks,
            hourStarted: currentHourStart
        )
    }

    // MARK: - Cloud orchestration with budget

    private func runCloud(task: AITask, model: String, system: String, user: String, maxTokens: Int, estimate: Int) async throws -> String {
        try reserveBudget(task: task, estimatedTokens: estimate)
        do {
            let result = try await callVertex(model: model, system: system, user: user, maxTokens: maxTokens, task: task)
            settleBudget(reserved: estimate, actual: result.inputTokens + result.outputTokens)
            return result.text
        } catch {
            releaseReservation(estimate)
            throw error
        }
    }

    // MARK: - Model resolution

    private func effectiveMaxTokens(task: AITask, requested: Int?) -> Int {
        let base = requested ?? task.defaultMaxTokens
        return energyMode == .maxCloud ? Int((Double(base) * 1.5 / 100).rounded() * 100) : base
    }

    private var localModelTag: String {
        localLLMModel.isEmpty ? "local" : "local:\(localLLMModel)"
    }

    private func isLocalTag(_ model: String) -> Bool {
        model == "local" || model.hasPrefix("local:")
    }

    private func resolveModel(for task: AITask) -> String {
        if let override = taskModels[task] { return override }
        if airplaneMode { return localModelTag }

        let policy = taskRoutingPolicies[task] ?? task.routingPolicy
        let localAvailable = localProvider != nil || !localLLMEndpoint.isEmpty

        switch energyMode {
        case .maxCloud:
            return upgradeModel(task.defaultModel)
        case .offline:
            return localModelTag
        case .powerSave:
            switch policy {
            case .localOnly:
                return localModelTag
            case .preferLocal, .preferCloud, .cloudOnly:
                return task.defaultModel
            }
        case .fullPower:
            switch policy {
            case .cloudOnly:
                return task.defaultModel
            case .localOnly:
                return localModelTag
            case .preferLocal:
                return localAvailable ? localModelTag : task.defaultModel
            case .preferCloud:
                return task.defaultModel
            }
        }
    }

    private func upgradeModel(_ model: String) -> String {
        catalog.descriptor(for: model)?.upgradesTo ?? model
    }

    private func descriptor(for model: String) throws -> ModelDescriptor {
        if isLocalTag(model) { return ModelDescriptor(provider: .local) }
        guard let descriptor = catalog.descriptor(for: model) else {
            throw AIRouterError.notConfigured("Unbekanntes Modell '\(model)'. Registriere es ueber 'additionalModels' im Initializer.")
        }
        return descriptor
    }

    // MARK: - Vertex AI

    private struct CallResult {
        let text: String
        let inputTokens: Int
        let outputTokens: Int
    }

    private func vertexEndpoint(model: String, provider: ModelDescriptor.Provider) throws -> URL {
        guard let encodedModel = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw AIRouterError.invalidEndpoint
        }
        let region = vertexRegion
        let project = vertexProject
        let endpoint: String
        switch provider {
        case .anthropic:
            endpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/anthropic/models/\(encodedModel):rawPredict"
        case .google:
            endpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(encodedModel):generateContent"
        case .local:
            throw AIRouterError.invalidEndpoint
        }
        guard let url = URL(string: endpoint) else {
            throw AIRouterError.invalidEndpoint
        }
        return url
    }

    private static func vertexBody(provider: ModelDescriptor.Provider, system: String, user: String, maxTokens: Int) -> [String: Any] {
        switch provider {
        case .anthropic:
            return [
                "anthropic_version": "vertex-2023-10-16",
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]]
            ]
        case .google:
            return [
                "contents": [["role": "user", "parts": [["text": user]]]],
                "systemInstruction": ["parts": [["text": system]]],
                "generationConfig": ["maxOutputTokens": maxTokens]
            ]
        case .local:
            return [:]
        }
    }

    private func callVertex(model: String, system: String, user: String, maxTokens: Int, task: AITask?) async throws -> CallResult {
        if isLocalTag(model) {
            return try await callLocal(model: model, system: system, user: user, maxTokens: maxTokens, task: task)
        }

        guard !vertexProject.isEmpty else {
            DebugLog.write("[AIRouter] Vertex AI Project nicht konfiguriert")
            throw AIRouterError.notConfigured("Vertex AI Project nicht konfiguriert")
        }

        var currentModel = model
        var transientAttempts = 0
        var tokenRefreshed = false
        let maxTransientRetries = 2
        let clock = ContinuousClock()

        while true {
            try Task.checkCancellation()

            let descriptor = try descriptor(for: currentModel)
            let url = try vertexEndpoint(model: currentModel, provider: descriptor.provider)
            let accessToken = try await getAccessToken()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = cloudTimeout
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: Self.vertexBody(provider: descriptor.provider, system: system, user: user, maxTokens: maxTokens))

            let start = clock.now
            let (data, http) = try await transport.data(for: request)
            let elapsed = clock.now - start

            switch http.statusCode {
            case 200...299:
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
                let body = String(data: data, encoding: .utf8) ?? ""
                if let fallback = descriptor.fallsBackTo, fallback != currentModel {
                    DebugLog.write("[AIRouter] Modell \(currentModel) nicht gefunden, Fallback zu \(fallback)")
                    currentModel = fallback
                    continue
                }
                throw AIRouterError.apiError(404, body)

            case 500...599 where transientAttempts < maxTransientRetries:
                transientAttempts += 1
                let body = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[AIRouter] HTTP \(http.statusCode) for \(currentModel) (retry \(transientAttempts)): \(body.prefix(120))")
                try await Task.sleep(for: .seconds(pow(2.0, Double(transientAttempts - 1))))
                continue

            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[AIRouter] HTTP \(http.statusCode) for \(currentModel): \(body.prefix(200))")
                throw AIRouterError.apiError(http.statusCode, body)
            }
        }
    }

    private static func parseVertex(data: Data, provider: ModelDescriptor.Provider) throws -> CallResult {
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
                  let parts = content["parts"] as? [[String: Any]],
                  let firstPart = parts.first,
                  let text = firstPart["text"] as? String else {
                throw AIRouterError.unexpectedResponse
            }
            let meta = json["usageMetadata"] as? [String: Any]
            return CallResult(
                text: text,
                inputTokens: meta?["promptTokenCount"] as? Int ?? 0,
                outputTokens: meta?["candidatesTokenCount"] as? Int ?? 0
            )
        case .local:
            throw AIRouterError.unexpectedResponse
        }
    }

    // MARK: - Local inference

    private func callLocal(model modelTag: String = "local", system: String, user: String, maxTokens: Int, task: AITask?) async throws -> CallResult {
        if let provider = localProvider, await provider.isReady {
            return try await callLocalProvider(provider: provider, system: system, user: user, maxTokens: maxTokens, task: task)
        }
        return try await callOllama(modelTag: modelTag, system: system, user: user, maxTokens: maxTokens, task: task)
    }

    private func callLocalProvider(provider: LocalInferenceProvider, system: String, user: String, maxTokens: Int, task: AITask?) async throws -> CallResult {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await provider.generate(system: system, user: user, maxTokens: maxTokens)
        let elapsed = clock.now - start
        emitUsage(task: task, model: "local-provider", input: result.inputTokens, output: result.outputTokens, elapsed: elapsed)
        return CallResult(text: result.text, inputTokens: result.inputTokens, outputTokens: result.outputTokens)
    }

    private func ollamaChatBody(model: String, system: String, user: String, maxTokens: Int, stream: Bool) -> [String: Any] {
        [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "stream": stream,
            "keep_alive": localLLMKeepAlive,
            "options": [
                "num_ctx": localLLMNumCtx,
                "num_predict": maxTokens,
                "num_batch": 512,
                "num_gpu": 999,
                "temperature": 0.3,
                "top_k": 20,
                "top_p": 0.9
            ]
        ]
    }

    private func resolveLocalModel(_ modelTag: String) throws -> String {
        if modelTag.hasPrefix("local:") {
            let stripped = String(modelTag.dropFirst(6))
            if !stripped.isEmpty { return stripped }
        }
        if !localLLMModel.isEmpty { return localLLMModel }
        throw AIRouterError.notConfigured("Kein lokales Modell konfiguriert. Rufe configureLocalLLM(endpoint:model:) auf.")
    }

    private func ollamaURL(path: String) throws -> URL {
        guard !localLLMEndpoint.isEmpty else {
            throw AIRouterError.notConfigured("Weder ein lokaler Provider noch Ollama verfuegbar. Konfiguriere einen LocalInferenceProvider oder einen Ollama-Endpoint.")
        }
        let base = localLLMEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)\(path)") else {
            throw AIRouterError.invalidEndpoint
        }
        return url
    }

    private func callOllama(modelTag: String = "local", system: String, user: String, maxTokens: Int, task: AITask?) async throws -> CallResult {
        let url = try ollamaURL(path: "/api/chat")
        let model = try resolveLocalModel(modelTag)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = localTimeout
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ollamaChatBody(model: model, system: system, user: user, maxTokens: maxTokens, stream: false))

        let clock = ContinuousClock()
        let start = clock.now
        let (data, http) = try await localTransport.data(for: request)
        let elapsed = clock.now - start

        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIRouterError.apiError(http.statusCode, body)
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

    // MARK: - Streaming

    private func streamLocalProvider(provider: LocalInferenceProvider, system: String, user: String, maxTokens: Int, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let clock = ContinuousClock()
        let start = clock.now
        var charCount = 0
        let stream = provider.generateStream(system: system, user: user, maxTokens: maxTokens)
        for try await chunk in stream {
            charCount += chunk.count
            continuation.yield(chunk)
        }
        let elapsed = clock.now - start
        // Lokales Streaming liefert keine exakten Token-Zaehler -> grobe Schaetzung.
        emitUsage(task: task, model: "local-provider", input: 0, output: charCount / 4, elapsed: elapsed, isEstimated: true)
        continuation.finish()
    }

    private func streamOllama(model modelTag: String, system: String, user: String, maxTokens: Int, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let url = try ollamaURL(path: "/api/chat")
        let model = try resolveLocalModel(modelTag)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = localTimeout
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ollamaChatBody(model: model, system: system, user: user, maxTokens: maxTokens, stream: true))

        let clock = ContinuousClock()
        let start = clock.now
        let (lines, http) = try await localTransport.lines(for: request)
        guard (200...299).contains(http.statusCode) else {
            throw AIRouterError.apiError(http.statusCode, "Streaming request failed")
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
        continuation.finish()
    }

    // MARK: - Budget internals

    private func reserveBudget(task: AITask, estimatedTokens: Int) throws {
        resetHourIfNeeded()
        if task.priority == .critical {
            reservedTokens += estimatedTokens
            return
        }
        let projected = tokensUsedThisHour + reservedTokens + estimatedTokens
        let ceiling: Int
        switch task.priority {
        case .low:
            ceiling = hourlyTokenBudget * 3 / 4
        case .normal:
            ceiling = hourlyTokenBudget * 9 / 10
        default:
            ceiling = hourlyTokenBudget
        }
        guard projected <= ceiling else {
            throttledTasks += 1
            DebugLog.write("[AIRouter] Budget-Throttle: \(task.rawValue) aufgeschoben (projected: \(projected), ceiling: \(ceiling))")
            throw AIRouterError.budgetExhausted(task: task.rawValue)
        }
        reservedTokens += estimatedTokens
    }

    private func settleBudget(reserved estimatedTokens: Int, actual: Int) {
        reservedTokens = max(0, reservedTokens - estimatedTokens)
        tokensUsedThisHour += actual
    }

    private func releaseReservation(_ estimatedTokens: Int) {
        reservedTokens = max(0, reservedTokens - estimatedTokens)
    }

    private func resetHourIfNeeded() {
        if Date().timeIntervalSince(currentHourStart) >= 3600 {
            tokensUsedThisHour = 0
            reservedTokens = 0
            currentHourStart = Date()
            throttledTasks = 0
        }
    }

    // MARK: - Auth

    private func getAccessToken() async throws -> String {
        if let token = cachedToken, let expires = tokenExpiresAt, Date() < expires {
            return token
        }
        guard let provider = accessTokenProvider else {
            throw AIRouterError.notConfigured("Kein accessTokenProvider gesetzt. Uebergib im Initializer einen accessTokenProvider, um Cloud-Aufrufe zu authentifizieren.")
        }
        let token = try await provider()
        guard !token.value.isEmpty else { throw AIRouterError.authFailed }
        cachedToken = token.value
        tokenExpiresAt = token.expiresAt
        return token.value
    }

    private func invalidateToken() {
        cachedToken = nil
        tokenExpiresAt = nil
    }

    // MARK: - Telemetry helper

    private func emitUsage(task: AITask?, model: String, input: Int, output: Int, elapsed: Duration, isEstimated: Bool = false) {
        guard let callback = usageCallback else { return }
        callback(AIUsageInfo(
            task: task,
            model: model,
            inputTokens: input,
            outputTokens: output,
            timestamp: Date(),
            durationMs: Self.milliseconds(elapsed),
            isEstimated: isEstimated
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}
