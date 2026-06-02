import Foundation

/// Nutzungs-Telemetrie eines einzelnen KI-Aufrufs.
public struct AIUsageInfo: Sendable {
    public let task: AITask?
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let timestamp: Date
    public let durationMs: Int

    public init(task: AITask?, model: String, inputTokens: Int, outputTokens: Int, timestamp: Date, durationMs: Int) {
        self.task = task
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.timestamp = timestamp
        self.durationMs = durationMs
    }
}

/// Zentraler Router, der KI-Aufgaben anhand von Energiemodus, Routing-Policy und
/// Token-Budget auf Cloud-Modelle (Vertex AI: Anthropic/Google) oder lokale
/// Modelle (In-Process-Provider oder Ollama-HTTP) verteilt.
///
/// Standalone, projektunabhaengig:
/// - Die lokale In-Process-Inferenz ist hinter ``LocalInferenceProvider`` abstrahiert.
/// - Die Vertex-Authentifizierung wird ausschliesslich ueber den injizierbaren
///   ``AccessTokenProvider`` bereitgestellt. Es ist keine Auth-Strategie fest
///   verdrahtet.
public actor AIRouter {
    /// Liefert einen OAuth2-Access-Token fuer Vertex AI.
    public typealias AccessTokenProvider = @Sendable () async throws -> String

    private let vertexRegion: String
    private let vertexProject: String
    private let taskModels: [String: String]
    private let taskRoutingPolicies: [String: String]
    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private var usageCallback: (@Sendable (AIUsageInfo) -> Void)?
    private let accessTokenProvider: AccessTokenProvider?

    private var localLLMEndpoint: String = ""
    private var localLLMModel: String = ""
    private var localLLMNumCtx: Int = 4096
    private let localLLMKeepAlive: String = "24h"
    private var airplaneMode: Bool = false
    private var energyMode: EnergyMode = .fullPower
    private var localProvider: LocalInferenceProvider?

    /// Dedizierte, gepoolte Session fuer lokale Inferenz (HTTP keep-alive zu localhost).
    private static let ollamaSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 120
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    private var hourlyTokenBudget: Int = 200_000
    private var tokensUsedThisHour: Int = 0
    private var currentHourStart: Date = Date()
    private var throttledTasks: Int = 0

    /// - Parameters:
    ///   - vertexRegion: Vertex-AI-Region (z. B. `us-central1`).
    ///   - vertexProject: GCP-Projekt-ID.
    ///   - taskModels: Optionale Modell-Overrides pro Task (`AITask.rawValue` -> Modellname).
    ///   - taskRoutingPolicies: Optionale Policy-Overrides pro Task (`AITask.rawValue` -> `RoutingPolicy.rawValue`).
    ///   - accessTokenProvider: Liefert das OAuth2-Token fuer Vertex AI. Wird fuer
    ///     Cloud-Aufrufe benoetigt; `nil` ist nur fuer reine Lokal-Nutzung (Ollama/
    ///     LocalInferenceProvider) zulaessig.
    public init(
        vertexRegion: String,
        vertexProject: String,
        taskModels: [String: String] = [:],
        taskRoutingPolicies: [String: String] = [:],
        accessTokenProvider: AccessTokenProvider? = nil
    ) {
        self.vertexRegion = vertexRegion
        self.vertexProject = vertexProject
        self.taskModels = taskModels
        self.taskRoutingPolicies = taskRoutingPolicies
        self.accessTokenProvider = accessTokenProvider
    }

    public func configureLocalLLM(endpoint: String, model: String, numCtx: Int = 4096) async {
        self.localLLMEndpoint = endpoint
        self.localLLMNumCtx = max(512, numCtx)

        // Kein Modell gewaehlt -> automatisch ein installiertes Ollama-Modell entdecken,
        // damit lokale Tasks nicht an einem nicht existierenden Default scheitern.
        var resolved = model
        if resolved.isEmpty && !endpoint.isEmpty {
            let available = await OllamaService.shared.fetchModels(endpoint: endpoint)
            // Bevorzuge ein gemma/qwen-Instruct-Modell, sonst das erste verfuegbare.
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

    public func send(task: AITask, system: String, user: String, maxTokens: Int? = nil) async throws -> String {
        let model = resolveModel(for: task)
        let baseTokens = maxTokens ?? task.defaultMaxTokens
        let tokens = energyMode == .maxCloud ? Int((Double(baseTokens) * 1.5 / 100).rounded() * 100) : baseTokens
        let policy = taskRoutingPolicies[task.rawValue]
            .flatMap { RoutingPolicy(rawValue: $0) } ?? task.routingPolicy

        if provider(for: model) == .local && policy == .preferLocal {
            do {
                return try await callLocal(model: model, system: system, user: user, maxTokens: tokens, task: task)
            } catch {
                DebugLog.write("[AIRouter] Local fehlgeschlagen fuer \(task.rawValue), Fallback zu Cloud: \(String(describing: error).prefix(80))")
                let cloudModel = task.defaultModel
                try checkBudget(task: task, estimatedTokens: tokens * 4)
                return try await callVertex(model: cloudModel, system: system, user: user, maxTokens: tokens, task: task)
            }
        }

        if provider(for: model) == .local {
            return try await callLocal(model: model, system: system, user: user, maxTokens: tokens, task: task)
        }

        if policy == .preferCloud {
            do {
                try checkBudget(task: task, estimatedTokens: tokens * 4)
                return try await callVertex(model: model, system: system, user: user, maxTokens: tokens, task: task)
            } catch let error as AIRouterError {
                if case .budgetExhausted = error, localProvider != nil || !localLLMEndpoint.isEmpty {
                    DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), Fallback zu lokal")
                    return try await callLocal(model: localModelTag, system: system, user: user, maxTokens: tokens, task: task)
                }
                throw error
            }
        }

        do {
            try checkBudget(task: task, estimatedTokens: tokens * 4)
            return try await callVertex(model: model, system: system, user: user, maxTokens: tokens, task: task)
        } catch let error as AIRouterError {
            if case .budgetExhausted = error, localProvider != nil || !localLLMEndpoint.isEmpty {
                DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), Fallback zu lokal")
                return try await callLocal(model: localModelTag, system: system, user: user, maxTokens: tokens, task: task)
            }
            throw error
        }
    }

    public func send(model: String, system: String, user: String, maxTokens: Int) async throws -> String {
        let effectiveModel = airplaneMode ? localModelTag : model
        return try await callVertex(model: effectiveModel, system: system, user: user, maxTokens: maxTokens, task: nil)
    }

    private var localModelTag: String {
        "local:\(localLLMModel.isEmpty ? "gemma4" : localLLMModel)"
    }

    public func resolvedModelName(for task: AITask) -> String {
        resolveModel(for: task)
    }

    public func sendStreaming(task: AITask, system: String, user: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let model = resolveModel(for: task)
                let baseTokens = maxTokens ?? task.defaultMaxTokens
                let tokens = self.energyMode == .maxCloud ? Int((Double(baseTokens) * 1.5 / 100).rounded() * 100) : baseTokens

                // In-Process-Provider streamt direkt (schnellster lokaler Pfad).
                if let provider = self.localProvider, await provider.isReady {
                    do {
                        try await self.streamLocalProvider(provider: provider, system: system, user: user, maxTokens: tokens, continuation: continuation)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // Ollama nativ /api/chat streamt token-weise.
                if self.provider(for: model) == .local && !self.localLLMEndpoint.isEmpty {
                    do {
                        try await self.streamOllama(model: model, system: system, user: user, maxTokens: tokens, task: task, continuation: continuation)
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // Fallback: non-streaming full response
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

    /// Baut den nativen Ollama-/api/chat-Body inkl. `keep_alive` und `options`
    /// (num_ctx, num_predict, num_batch, num_gpu, sampling).
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

    private func resolveLocalModel(_ modelTag: String) -> String {
        if modelTag.hasPrefix("local:") {
            let stripped = String(modelTag.dropFirst(6))
            if !stripped.isEmpty { return stripped }
        }
        if !localLLMModel.isEmpty { return localLLMModel }
        return "gemma4"
    }

    private func streamOllama(model modelTag: String, system: String, user: String, maxTokens: Int, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        guard !localLLMEndpoint.isEmpty else {
            throw AIRouterError.notConfigured("Ollama nicht konfiguriert")
        }

        let base = localLLMEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/chat") else {
            throw AIRouterError.invalidEndpoint
        }

        let model = resolveLocalModel(modelTag)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ollamaChatBody(model: model, system: system, user: user, maxTokens: maxTokens, stream: true))

        let (bytes, response) = try await Self.ollamaSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIRouterError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0, "Streaming request failed")
        }

        // Natives /api/chat liefert NDJSON: ein JSON-Objekt pro Zeile.
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? String, !content.isEmpty {
                continuation.yield(content)
            }
            if json["done"] as? Bool == true { break }
        }
        continuation.finish()
    }

    private func streamLocalProvider(provider: LocalInferenceProvider, system: String, user: String, maxTokens: Int, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let stream = provider.generateStream(system: system, user: user, maxTokens: maxTokens)
        for try await chunk in stream {
            continuation.yield(chunk)
        }
        continuation.finish()
    }

    private func resolveModel(for task: AITask) -> String {
        if let override = taskModels[task.rawValue] { return override }
        if airplaneMode { return localModelTag }

        let policy = taskRoutingPolicies[task.rawValue]
            .flatMap { RoutingPolicy(rawValue: $0) } ?? task.routingPolicy

        let localAvailable = localProvider != nil || !localLLMEndpoint.isEmpty

        switch energyMode {
        case .maxCloud:
            return upgradeModel(task.defaultModel)

        case .offline:
            return localModelTag

        case .powerSave:
            // Akkubetrieb: kurze/EASY-Tasks bevorzugt in die Cloud (Funk-I/O ist
            // guenstiger als die GPU aus dem Kaltstart hochzufahren). Nur explizit
            // lokale Tasks bleiben lokal.
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
        switch model {
        case "gemini-2.5-flash": return "gemini-2.5-pro"
        case "gemini-2.5-pro": return "claude-opus-4-6"
        default: return model
        }
    }

    private enum ModelProvider {
        case anthropic, google, local
    }

    private func provider(for model: String) -> ModelProvider {
        if model == "local" || model.hasPrefix("local:") { return .local }
        return model.hasPrefix("gemini-") ? .google : .anthropic
    }

    private static func fallbackModel(for model: String) -> String? {
        if model.contains("flash") { return "gemini-2.5-flash" }
        if model.hasPrefix("gemini-") && model.contains("pro") { return "gemini-2.5-pro" }
        if model.hasPrefix("claude-opus") { return "claude-opus-4-6" }
        if model.hasPrefix("claude-sonnet") { return "claude-sonnet-4-6" }
        return nil
    }

    private func callVertex(model: String, system: String, user: String, maxTokens: Int, task: AITask?) async throws -> String {
        if provider(for: model) == .local {
            return try await callLocal(model: model, system: system, user: user, maxTokens: maxTokens, task: task)
        }

        let region = vertexRegion
        let project = vertexProject

        guard !project.isEmpty else {
            DebugLog.write("[AIRouter] Vertex AI Project nicht konfiguriert")
            throw AIRouterError.notConfigured("Vertex AI Project nicht konfiguriert")
        }

        let endpoint: String
        switch provider(for: model) {
        case .anthropic:
            endpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/anthropic/models/\(model):rawPredict"
        case .google:
            endpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(model):generateContent"
        case .local:
            fatalError("unreachable")
        }
        guard let url = URL(string: endpoint) else {
            throw AIRouterError.invalidEndpoint
        }

        let accessToken = try await getAccessToken()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]
        switch provider(for: model) {
        case .anthropic:
            body = [
                "anthropic_version": "vertex-2023-10-16",
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]]
            ]
        case .google:
            body = [
                "contents": [["role": "user", "parts": [["text": user]]]],
                "systemInstruction": ["parts": [["text": system]]],
                "generationConfig": ["maxOutputTokens": maxTokens]
            ]
        case .local:
            fatalError("unreachable - local handled before callVertex")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let clock = ContinuousClock()

        for attempt in 0..<3 {
            let start = clock.now
            let (data, response) = try await URLSession.shared.data(for: request)
            let elapsed = clock.now - start

            guard let http = response as? HTTPURLResponse else {
                throw AIRouterError.noResponse
            }

            if http.statusCode == 401 {
                cachedToken = nil
                tokenExpiresAt = nil
                let newToken = try await getAccessToken()
                request.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                continue
            }

            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[AIRouter] HTTP \(http.statusCode) for \(model): \(body.prefix(200))")

                if http.statusCode == 404, let fallback = Self.fallbackModel(for: model), fallback != model {
                    DebugLog.write("[AIRouter] Model \(model) not found, falling back to \(fallback)")
                    let fallbackEndpoint: String
                    switch provider(for: fallback) {
                    case .anthropic:
                        fallbackEndpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/anthropic/models/\(fallback):rawPredict"
                    case .google:
                        fallbackEndpoint = "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(fallback):generateContent"
                    case .local:
                        fallbackEndpoint = ""
                    }
                    if let fallbackURL = URL(string: fallbackEndpoint), !fallbackEndpoint.isEmpty {
                        request.url = fallbackURL
                        let fallbackBody: [String: Any]
                        switch provider(for: fallback) {
                        case .anthropic:
                            fallbackBody = [
                                "anthropic_version": "vertex-2023-10-16",
                                "max_tokens": maxTokens,
                                "system": system,
                                "messages": [["role": "user", "content": user]]
                            ]
                        case .google:
                            fallbackBody = [
                                "contents": [["role": "user", "parts": [["text": user]]]],
                                "systemInstruction": ["parts": [["text": system]]],
                                "generationConfig": ["maxOutputTokens": maxTokens]
                            ]
                        case .local:
                            fallbackBody = [:]
                        }
                        request.httpBody = try? JSONSerialization.data(withJSONObject: fallbackBody)
                        continue
                    }
                }

                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
                    continue
                }
                throw AIRouterError.apiError(http.statusCode, body)
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AIRouterError.unexpectedResponse
            }

            let text: String
            var inputTokens = 0
            var outputTokens = 0

            switch provider(for: model) {
            case .anthropic:
                guard let content = json["content"] as? [[String: Any]],
                      let first = content.first,
                      let t = first["text"] as? String else {
                    throw AIRouterError.unexpectedResponse
                }
                text = t
                if let usage = json["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                    outputTokens = usage["output_tokens"] as? Int ?? 0
                }
            case .google:
                guard let candidates = json["candidates"] as? [[String: Any]],
                      let first = candidates.first,
                      let content = first["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]],
                      let firstPart = parts.first,
                      let t = firstPart["text"] as? String else {
                    throw AIRouterError.unexpectedResponse
                }
                text = t
                if let meta = json["usageMetadata"] as? [String: Any] {
                    inputTokens = meta["promptTokenCount"] as? Int ?? 0
                    outputTokens = meta["candidatesTokenCount"] as? Int ?? 0
                }
            case .local:
                fatalError("unreachable - local handled before callVertex")
            }

            tokensUsedThisHour += inputTokens + outputTokens

            if let callback = usageCallback {
                let info = AIUsageInfo(
                    task: task,
                    model: model,
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    timestamp: Date(),
                    durationMs: Int(elapsed.components.seconds * 1000 + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000))
                )
                callback(info)
            }

            return text
        }

        throw AIRouterError.apiError(0, "Maximale Versuche erreicht")
    }

    private func callLocal(model modelTag: String = "local", system: String, user: String, maxTokens: Int, task: AITask?) async throws -> String {
        // In-Process-Provider: Prioritaet vor Ollama
        if let provider = localProvider, await provider.isReady {
            return try await callLocalProvider(provider: provider, system: system, user: user, maxTokens: maxTokens, task: task)
        }

        // Ollama HTTP Fallback
        return try await callOllama(modelTag: modelTag, system: system, user: user, maxTokens: maxTokens, task: task)
    }

    private func callLocalProvider(provider: LocalInferenceProvider, system: String, user: String, maxTokens: Int, task: AITask?) async throws -> String {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await provider.generate(system: system, user: user, maxTokens: maxTokens)
        let elapsed = clock.now - start

        if let callback = usageCallback {
            let info = AIUsageInfo(
                task: task,
                model: "local-provider",
                inputTokens: result.inputTokens,
                outputTokens: result.outputTokens,
                timestamp: Date(),
                durationMs: Int(elapsed.components.seconds * 1000 + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000))
            )
            callback(info)
        }

        return result.text
    }

    private func callOllama(modelTag: String = "local", system: String, user: String, maxTokens: Int, task: AITask?) async throws -> String {
        guard !localLLMEndpoint.isEmpty else {
            throw AIRouterError.notConfigured("Weder ein lokaler Provider noch Ollama verfuegbar. Konfiguriere einen LocalInferenceProvider oder einen Ollama-Endpoint.")
        }

        let base = localLLMEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiURL = "\(base)/api/chat"
        guard let url = URL(string: apiURL) else {
            throw AIRouterError.invalidEndpoint
        }

        let model = resolveLocalModel(modelTag)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ollamaChatBody(model: model, system: system, user: user, maxTokens: maxTokens, stream: false))

        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await Self.ollamaSession.data(for: request)
        let elapsed = clock.now - start

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIRouterError.apiError((response as? HTTPURLResponse)?.statusCode ?? 0, body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIRouterError.unexpectedResponse
        }

        // Natives /api/chat liefert Token-Zaehler direkt im Top-Level-Objekt.
        let inputTokens = json["prompt_eval_count"] as? Int ?? 0
        let outputTokens = json["eval_count"] as? Int ?? 0

        if let callback = usageCallback {
            let info = AIUsageInfo(
                task: task,
                model: "local:\(model)",
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                timestamp: Date(),
                durationMs: Int(elapsed.components.seconds * 1000 + Int64(elapsed.components.attoseconds / 1_000_000_000_000_000))
            )
            callback(info)
        }

        return text
    }

    private func checkBudget(task: AITask, estimatedTokens: Int) throws {
        resetHourIfNeeded()
        if task.priority == .critical { return }
        let remaining = hourlyTokenBudget - tokensUsedThisHour
        if task.priority == .low && remaining < hourlyTokenBudget / 4 {
            throttledTasks += 1
            DebugLog.write("[AIRouter] Budget-Throttle: \(task.rawValue) aufgeschoben (remaining: \(remaining))")
            throw AIRouterError.budgetExhausted(task: task.rawValue)
        }
        if task.priority == .normal && remaining < hourlyTokenBudget / 10 {
            throttledTasks += 1
            throw AIRouterError.budgetExhausted(task: task.rawValue)
        }
    }

    private func resetHourIfNeeded() {
        if Date().timeIntervalSince(currentHourStart) >= 3600 {
            tokensUsedThisHour = 0
            currentHourStart = Date()
            throttledTasks = 0
        }
    }

    private func getAccessToken() async throws -> String {
        if let token = cachedToken, let expires = tokenExpiresAt, Date() < expires {
            return token
        }

        guard let provider = accessTokenProvider else {
            throw AIRouterError.notConfigured("Kein accessTokenProvider gesetzt. Uebergib im Initializer einen accessTokenProvider, um Cloud-Aufrufe zu authentifizieren.")
        }

        let token = try await provider()
        guard !token.isEmpty else { throw AIRouterError.authFailed }
        cacheToken(token)
        return token
    }

    private func cacheToken(_ token: String) {
        cachedToken = token
        tokenExpiresAt = Date().addingTimeInterval(50 * 60)
    }

    public struct BudgetStatus: Sendable {
        public let tokensUsed: Int
        public let tokenBudget: Int
        public let throttledCount: Int
        public let hourStarted: Date
        public var remaining: Int { max(0, tokenBudget - tokensUsed) }
        public var utilization: Double { tokenBudget > 0 ? Double(tokensUsed) / Double(tokenBudget) : 0 }
        public var minutesUntilReset: Int { max(0, Int((3600 - Date().timeIntervalSince(hourStarted)) / 60)) }
    }

    public func budgetStatus() -> BudgetStatus {
        resetHourIfNeeded()
        return BudgetStatus(
            tokensUsed: tokensUsedThisHour,
            tokenBudget: hourlyTokenBudget,
            throttledCount: throttledTasks,
            hourStarted: currentHourStart
        )
    }
}
