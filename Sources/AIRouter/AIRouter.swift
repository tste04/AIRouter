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
    /// Geschaetzte Kosten in USD (aus den Katalog-Preisen; `nil` fuer lokale
    /// Modelle oder Modelle ohne hinterlegte Preise).
    public let costUSD: Double?

    public init(
        task: AITask?,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        timestamp: Date,
        durationMs: Int,
        isEstimated: Bool = false,
        costUSD: Double? = nil
    ) {
        self.task = task
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.timestamp = timestamp
        self.durationMs = durationMs
        self.isEstimated = isEstimated
        self.costUSD = costUSD
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
///
/// Erweiterte Funktionen:
/// - Multi-Turn-Konversationen (``AIMessage``) und Sampling-Optionen
///   (``GenerationOptions``) auf allen Pfaden.
/// - Natives Cloud-Streaming via SSE (`:streamRawPredict` bzw.
///   `:streamGenerateContent?alt=sse`) inklusive Budget-Reservierung.
/// - Circuit-Breaker pro Modell: nach wiederholten Fehlern wird ein Modell
///   temporaer gemieden (Fallback-Kette, sonst ``AIRouterError/circuitOpen(model:)``).
/// - Opt-in-Antwort-Cache fuer idempotente Tasks.
/// - Kosten-Telemetrie aus den Katalog-Preisen (``AIUsageInfo/costUSD``,
///   ``BudgetStatus/costUSD``).
/// - Preflight-Hook fuer ausgehende Cloud-Inhalte (z. B. PII-Redaktion).
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
    private let retryPolicy: RetryPolicy
    private var catalog: ModelCatalog

    private var cachedToken: String?
    private var tokenExpiresAt: Date?
    private var usageCallback: (@Sendable (AIUsageInfo) -> Void)?
    /// Registrierte ``CloudInferenceProvider`` fuer Modelle mit
    /// `provider: .custom(id)` (OpenAI-kompatibel, Anthropic-direkt, eigene).
    private var customProviders: [String: CloudInferenceProvider] = [:]
    /// Optionaler Persistenz-Hook: Budget-Zustand ueberlebt App-Neustarts.
    private var storage: RouterStorage?
    /// Wird vor jedem Cloud-Versand auf System-Prompt und Nachrichteninhalte
    /// angewandt (z. B. PII-Redaktion). Lokale Aufrufe bleiben unveraendert.
    private var cloudPreflight: (@Sendable (String) -> String)?

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
    /// Monotone Uhr fuer Budget-Reset, Circuit-Breaker und Cache-TTL: Wanduhr-
    /// Spruenge (NTP, manuelle Zeitumstellung) koennen weder Budgets vorzeitig
    /// zuruecksetzen (Kosten-Bypass) noch Zustaende einfrieren.
    private let budgetClock = ContinuousClock()
    private var hourStartInstant: ContinuousClock.Instant
    private var throttledTasks: Int = 0
    private var costThisHourUSD: Double = 0
    /// Optionales Kosten-Budget in USD pro Stunde (zusaetzlich zum Token-Budget).
    private var hourlyCostBudgetUSD: Double?
    /// Wenn aktiv, warten Cloud-Aufrufe bei erschoepftem Budget (und ohne
    /// lokales Fallback) auf das naechste Stundenfenster statt zu werfen.
    private var queueOnBudgetExhausted = false

    // MARK: - Concurrency limit

    private var maxConcurrentCloudCalls = 8
    private var activeCloudCalls = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Model stats

    /// Latenz-/Fehler-Telemetrie pro Modell (fuer Monitoring und Routing-Debugging).
    public struct ModelStats: Sendable {
        public let model: String
        public let calls: Int
        public let failures: Int
        public let averageLatencyMs: Int
    }

    private var statsCalls: [String: Int] = [:]
    private var statsFailures: [String: Int] = [:]
    private var statsLatencyTotalMs: [String: Int] = [:]

    // MARK: - Circuit breaker

    private struct BreakerState {
        var consecutiveFailures: Int = 0
        var openedAt: ContinuousClock.Instant?
    }

    private var breakers: [String: BreakerState] = [:]
    private let breakerThreshold = 3
    private let breakerCooldown: Duration = .seconds(60)

    // MARK: - Response cache

    private struct ResponseCacheKey: Hashable {
        let task: AITask
        let model: String
        let system: String
        let messages: [AIMessage]
        let maxTokens: Int
        let options: GenerationOptions
    }

    private struct ResponseCacheEntry {
        let text: String
        let storedAt: ContinuousClock.Instant
    }

    private var responseCache: [ResponseCacheKey: ResponseCacheEntry] = [:]
    private var responseCacheOrder: [ResponseCacheKey] = []
    private var responseCacheTTL: Duration = .seconds(300)
    private var responseCacheMax: Int = 0
    private var cacheableTasks: Set<AITask> = []

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
    ///   - retryPolicy: Retry-Strategie fuer transiente Cloud-Fehler (429/5xx).
    public init(
        vertexRegion: String,
        vertexProject: String,
        taskModels: [AITask: String] = [:],
        taskRoutingPolicies: [AITask: RoutingPolicy] = [:],
        accessTokenProvider: AccessTokenProvider? = nil,
        transport: HTTPTransport? = nil,
        additionalModels: [String: ModelDescriptor] = [:],
        retryPolicy: RetryPolicy = .default
    ) {
        self.vertexRegion = vertexRegion
        self.vertexProject = vertexProject
        self.taskModels = taskModels
        self.taskRoutingPolicies = taskRoutingPolicies
        self.accessTokenProvider = accessTokenProvider
        self.transport = transport ?? URLSessionTransport()
        self.localTransport = transport ?? URLSessionTransport(session: AIRouter.ollamaSession)
        self.retryPolicy = retryPolicy
        var catalog = ModelCatalog.default
        catalog.merge(additionalModels)
        self.catalog = catalog
        self.hourStartInstant = budgetClock.now
    }

    // MARK: - Configuration

    public func configureLocalLLM(endpoint: String, model: String, numCtx: Int = 4096) async {
        // Nur http/https mit Host akzeptieren — verhindert, dass ein fehlerhaft
        // oder boeswillig konfigurierter "lokaler" Endpoint Prompts an ein
        // unerwartetes Ziel (file://, fehlgeformte URL, ...) leitet.
        let validated = RouterValidation.validatedLocalEndpoint(endpoint)
        if !endpoint.isEmpty && validated == nil {
            DebugLog.write("[AIRouter] Ungueltiger lokaler Endpoint verworfen (erlaubt: http/https mit Host)")
        }
        let sanitizedEndpoint = validated ?? ""
        self.localLLMEndpoint = sanitizedEndpoint
        self.localLLMNumCtx = max(512, numCtx)

        // Kein Modell gewaehlt -> automatisch ein installiertes Ollama-Modell entdecken.
        var resolved = model
        if resolved.isEmpty && !sanitizedEndpoint.isEmpty {
            let available = await OllamaService.shared.fetchModels(endpoint: sanitizedEndpoint)
            resolved = available.first(where: { $0.name.lowercased().contains("gemma") })?.name
                ?? available.first(where: { $0.name.lowercased().contains("qwen") })?.name
                ?? available.first?.name
                ?? ""
            if !resolved.isEmpty {
                DebugLog.write("[AIRouter] Kein localLLMModel gesetzt -> automatisch gewaehlt: \(resolved)")
            }
        }
        self.localLLMModel = resolved

        if !sanitizedEndpoint.isEmpty {
            DebugLog.write("[AIRouter] Local LLM konfiguriert: \(sanitizedEndpoint) (\(resolved.isEmpty ? "kein Modell" : resolved), num_ctx=\(self.localLLMNumCtx))")
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

    /// Setzt einen Hook, der vor jedem Cloud-Versand auf System-Prompt und alle
    /// Nachrichteninhalte angewandt wird — z. B. zur PII-Redaktion. Lokale
    /// Aufrufe (In-Process/Ollama) bleiben unveraendert. `nil` entfernt den Hook.
    public func setCloudPreflight(_ hook: (@Sendable (String) -> String)?) {
        self.cloudPreflight = hook
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

    /// Aktiviert den Antwort-Cache fuer die angegebenen Tasks (opt-in; gedacht
    /// fuer idempotente Klassifikations-/Extraktions-Tasks). Der Schluessel ist
    /// die vollstaendige Anfrage (Task, Modell, System, Nachrichten, Limits,
    /// Optionen). `maxEntries: 0` deaktiviert den Cache.
    public func enableResponseCache(tasks: Set<AITask>, ttlSeconds: TimeInterval = 300, maxEntries: Int = 256) {
        responseCacheMax = max(0, maxEntries)
        responseCacheTTL = .seconds(max(1, ttlSeconds))
        cacheableTasks = responseCacheMax > 0 ? tasks : []
        if responseCacheMax == 0 {
            responseCache.removeAll()
            responseCacheOrder.removeAll()
        }
    }

    public func clearResponseCache() {
        responseCache.removeAll()
        responseCacheOrder.removeAll()
    }

    /// Registriert einen ``CloudInferenceProvider``. Modelle, deren
    /// ``ModelDescriptor`` `provider: .custom(provider.id)` traegt, werden an
    /// diesen Provider geleitet — Budget, Circuit-Breaker, Retry-Policy,
    /// Preflight und Kosten-Telemetrie bleiben beim Router.
    public func registerCloudProvider(_ provider: CloudInferenceProvider) {
        customProviders[provider.id] = provider
        DebugLog.write("[AIRouter] CloudInferenceProvider '\(provider.id)' registriert")
    }

    /// Setzt ein zusaetzliches Kosten-Budget in USD pro Stunde (aus den
    /// Katalog-Preisen berechnet). `nil` deaktiviert die Kosten-Grenze.
    /// Tasks mit Prioritaet `critical` umgehen die Grenze wie beim Token-Budget.
    public func setHourlyCostBudget(usd: Double?) {
        hourlyCostBudgetUSD = usd.map { max(0, $0) }
    }

    /// Wenn aktiviert, warten Cloud-Aufrufe bei erschoepftem Budget (und ohne
    /// lokales Fallback) auf das naechste Stundenfenster und versuchen es dann
    /// erneut, statt `budgetExhausted` zu werfen. Abbruch via Task-Cancellation.
    public func setQueueOnBudgetExhausted(_ enabled: Bool) {
        queueOnBudgetExhausted = enabled
    }

    /// Begrenzung paralleler Cloud-Aufrufe (Backpressure). Default: 8.
    public func setMaxConcurrentCloudCalls(_ limit: Int) {
        maxConcurrentCloudCalls = max(1, limit)
        // Frei gewordene Kapazitaet sofort an Wartende vergeben.
        while activeCloudCalls < maxConcurrentCloudCalls, !slotWaiters.isEmpty {
            activeCloudCalls += 1
            slotWaiters.removeFirst().resume()
        }
    }

    /// Konfiguriert Persistenz fuer den Budget-Zustand. Ist der gespeicherte
    /// Stundenanfang juenger als eine Stunde, werden Zaehler und Kosten
    /// wiederhergestellt — das Budget laesst sich nicht per Neustart umgehen.
    public func configureStorage(_ storage: RouterStorage) async {
        self.storage = storage
        if let state = await storage.loadBudgetState() {
            let elapsed = Date().timeIntervalSince(state.hourStarted)
            if elapsed >= 0 && elapsed < 3600 {
                tokensUsedThisHour = state.tokensUsed
                costThisHourUSD = state.costUSD
                throttledTasks = state.throttled
                currentHourStart = state.hourStarted
                hourStartInstant = budgetClock.now - .seconds(elapsed)
                DebugLog.write("[AIRouter] Budget-Zustand wiederhergestellt (\(state.tokensUsed) Tokens, Fenster seit \(Int(elapsed))s)")
            }
        }
    }

    /// Latenz-/Fehler-Statistik pro Modell seit Prozessstart.
    public func modelStats() -> [ModelStats] {
        let models = Set(statsCalls.keys).union(statsFailures.keys)
        return models.map { model in
            let calls = statsCalls[model] ?? 0
            return ModelStats(
                model: model,
                calls: calls,
                failures: statsFailures[model] ?? 0,
                averageLatencyMs: calls > 0 ? (statsLatencyTotalMs[model] ?? 0) / calls : 0
            )
        }.sorted { $0.model < $1.model }
    }

    public func warmup() async {
        _ = try? await getAccessToken()
    }

    // MARK: - Public API

    public func send(task: AITask, system: String, user: String, maxTokens: Int? = nil) async throws -> String {
        try await send(task: task, system: system, messages: [.user(user)], maxTokens: maxTokens)
    }

    /// Multi-Turn-Variante: `messages` ist der Konversationsverlauf (User/Assistant),
    /// `options` steuert Sampling (Temperatur, top-p/k, Stop-Sequenzen).
    public func send(
        task: AITask,
        system: String,
        messages: [AIMessage],
        maxTokens: Int? = nil,
        options: GenerationOptions = .default
    ) async throws -> String {
        let model = resolveModel(for: task)
        let tokens = effectiveMaxTokens(task: task, requested: maxTokens)
        let estimate = tokens * 4
        let policy = taskRoutingPolicies[task] ?? task.routingPolicy

        let cacheKey = responseCacheKey(task: task, model: model, system: system, messages: messages, maxTokens: tokens, options: options)
        if let key = cacheKey, let hit = cachedResponse(for: key) {
            DebugLog.write("[AIRouter] Cache-Treffer fuer \(task.rawValue)")
            return hit
        }

        let result: String

        if isLocalTag(model) && policy == .preferLocal {
            // preferLocal: erst lokal, bei Fehler (ausser Cancellation) Cloud-Fallback.
            do {
                result = try await callLocal(model: model, system: system, messages: messages, maxTokens: tokens, options: options, task: task).text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                DebugLog.write("[AIRouter] Local fehlgeschlagen fuer \(task.rawValue), Fallback zu Cloud: \(String(describing: error).prefix(80))")
                result = try await runCloud(task: task, model: task.defaultModel, system: system, messages: messages, maxTokens: tokens, options: options, estimate: estimate)
            }
        } else if isLocalTag(model) {
            // Rein lokal (kein Budget).
            result = try await callLocal(model: model, system: system, messages: messages, maxTokens: tokens, options: options, task: task).text
        } else {
            // Cloud mit Budget; bei Budget-Erschoepfung optional lokal oder Warteschlange.
            do {
                result = try await runCloud(task: task, model: model, system: system, messages: messages, maxTokens: tokens, options: options, estimate: estimate)
            } catch let error as AIRouterError {
                guard case .budgetExhausted = error else { throw error }
                if hasLocalBackend() {
                    DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), Fallback zu lokal")
                    result = try await callLocal(model: localModelTag, system: system, messages: messages, maxTokens: tokens, options: options, task: task).text
                } else if queueOnBudgetExhausted {
                    let wait = secondsUntilBudgetReset()
                    DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), warte \(Int(wait))s auf das naechste Fenster")
                    try await Task.sleep(for: .seconds(wait))
                    result = try await runCloud(task: task, model: model, system: system, messages: messages, maxTokens: tokens, options: options, estimate: estimate)
                } else {
                    throw error
                }
            }
        }

        if let key = cacheKey {
            storeResponse(result, for: key)
        }
        return result
    }

    public func send(model: String, system: String, user: String, maxTokens: Int) async throws -> String {
        try await send(model: model, system: system, messages: [.user(user)], maxTokens: maxTokens)
    }

    /// Roher Modell-Pfad (ohne Task-Abstraktion). Zaehlt ebenfalls auf das
    /// Stundenbudget ein, damit `budgetStatus()` die realen Cloud-Kosten abbildet.
    public func send(
        model: String,
        system: String,
        messages: [AIMessage],
        maxTokens: Int,
        options: GenerationOptions = .default
    ) async throws -> String {
        let effectiveModel = airplaneMode ? localModelTag : model
        if isLocalTag(effectiveModel) {
            return try await callLocal(model: effectiveModel, system: system, messages: messages, maxTokens: maxTokens, options: options, task: nil).text
        }
        await acquireCloudSlot()
        do {
            let result = try await callVertex(model: effectiveModel, system: system, messages: messages, maxTokens: maxTokens, options: options, task: nil)
            releaseCloudSlot()
            resetHourIfNeeded()
            tokensUsedThisHour += result.inputTokens + result.outputTokens
            persistBudget()
            return result.text
        } catch {
            releaseCloudSlot()
            throw error
        }
    }

    public func resolvedModelName(for task: AITask) -> String {
        resolveModel(for: task)
    }

    public func sendStreaming(task: AITask, system: String, user: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        sendStreaming(task: task, system: system, messages: [.user(user)], maxTokens: maxTokens)
    }

    /// Token-weises Streaming: In-Process-Provider und Ollama streamen nativ,
    /// Cloud-Modelle via SSE (inkl. Budget-Reservierung). Bei erschoepftem
    /// Budget faellt der Stream auf ein lokales Backend zurueck, sofern vorhanden.
    public func sendStreaming(
        task: AITask,
        system: String,
        messages: [AIMessage],
        maxTokens: Int? = nil,
        options: GenerationOptions = .default
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                let model = self.resolveModel(for: task)
                let tokens = self.effectiveMaxTokens(task: task, requested: maxTokens)

                // Lokal aufgeloestes Modell -> In-Process-Provider oder Ollama.
                if self.isLocalTag(model) {
                    do {
                        try await self.streamLocal(model: model, system: system, messages: messages, maxTokens: tokens, options: options, task: task, continuation: continuation)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                // Cloud: natives SSE-Streaming mit Budget; bei Erschoepfung lokal.
                do {
                    try await self.streamCloud(task: task, model: model, system: system, messages: messages, maxTokens: tokens, options: options, continuation: continuation)
                    continuation.finish()
                } catch let error as AIRouterError {
                    if case .budgetExhausted = error, self.hasLocalBackend() {
                        DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), Streaming-Fallback zu lokal")
                        do {
                            try await self.streamLocal(model: self.localModelTag, system: system, messages: messages, maxTokens: tokens, options: options, task: task, continuation: continuation)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    public struct BudgetStatus: Sendable {
        public let tokensUsed: Int
        public let tokensReserved: Int
        public let tokenBudget: Int
        public let throttledCount: Int
        public let hourStarted: Date
        /// Geschaetzte Cloud-Kosten dieser Stunde in USD (aus Katalog-Preisen).
        public let costUSD: Double
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
            hourStarted: currentHourStart,
            costUSD: costThisHourUSD
        )
    }

    // MARK: - Cloud orchestration with budget

    private func runCloud(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, estimate: Int) async throws -> String {
        try reserveBudget(task: task, estimatedTokens: estimate)
        await acquireCloudSlot()
        do {
            let result = try await callVertex(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task)
            releaseCloudSlot()
            settleBudget(reserved: estimate, actual: result.inputTokens + result.outputTokens)
            return result.text
        } catch {
            releaseCloudSlot()
            releaseReservation(estimate)
            throw error
        }
    }

    private func streamCloud(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let estimate = maxTokens * 4
        try reserveBudget(task: task, estimatedTokens: estimate)
        await acquireCloudSlot()
        do {
            let usage = try await streamVertex(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task, continuation: continuation)
            releaseCloudSlot()
            settleBudget(reserved: estimate, actual: usage.input + usage.output)
        } catch {
            releaseCloudSlot()
            releaseReservation(estimate)
            throw error
        }
    }

    /// Async-Semaphor fuer parallele Cloud-Aufrufe. Hinweis: Ein Warteplatz
    /// wird bei Task-Cancellation erst beim naechsten frei werdenden Slot
    /// aufgeloest (die Cancellation greift dann im nachfolgenden Request).
    private func acquireCloudSlot() async {
        if activeCloudCalls < maxConcurrentCloudCalls {
            activeCloudCalls += 1
            return
        }
        await withCheckedContinuation { continuation in
            slotWaiters.append(continuation)
        }
    }

    private func releaseCloudSlot() {
        if !slotWaiters.isEmpty {
            // Slot direkt an den naechsten Wartenden uebergeben.
            slotWaiters.removeFirst().resume()
        } else {
            activeCloudCalls = max(0, activeCloudCalls - 1)
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

    private func hasLocalBackend() -> Bool {
        localProvider != nil || !localLLMEndpoint.isEmpty
    }

    private func resolveModel(for task: AITask) -> String {
        if let override = taskModels[task] { return override }
        if airplaneMode { return localModelTag }

        let policy = taskRoutingPolicies[task] ?? task.routingPolicy
        let localAvailable = hasLocalBackend()

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

    private func vertexEndpoint(model: String, provider: ModelDescriptor.Provider, streaming: Bool = false) throws -> URL {
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

    private static func vertexBody(provider: ModelDescriptor.Provider, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, stream: Bool = false) -> [String: Any] {
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

    private func callVertex(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
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
        let outboundSystem = cloudPreflight.map { $0(system) } ?? system
        let outboundMessages = preflightedMessages(messages)

        var currentModel = model
        var transientAttempts = 0
        var tokenRefreshed = false
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
            let url = try vertexEndpoint(model: currentModel, provider: descriptor.provider)
            let accessToken = try await getAccessToken()

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = options.requestTimeout ?? cloudTimeout
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(
                withJSONObject: Self.vertexBody(provider: descriptor.provider, system: outboundSystem, messages: outboundMessages, maxTokens: maxTokens, options: options))

            let start = clock.now
            let (data, http): (Data, HTTPURLResponse)
            do {
                (data, http) = try await transport.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
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
                let body = String(data: data, encoding: .utf8) ?? ""
                if let fallback = descriptor.fallsBackTo, fallback != currentModel {
                    DebugLog.write("[AIRouter] Modell \(currentModel) nicht gefunden, Fallback zu \(fallback)")
                    currentModel = fallback
                    continue
                }
                throw AIRouterError.apiError(404, String(body.prefix(500)))

            case 429 where transientAttempts < retryPolicy.maxTransientRetries,
                 500...599 where transientAttempts < retryPolicy.maxTransientRetries:
                transientAttempts += 1
                let body = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[AIRouter] HTTP \(http.statusCode) for \(currentModel) (retry \(transientAttempts)): \(body.prefix(120))")
                try await Task.sleep(for: .seconds(retryPolicy.baseDelay * pow(2.0, Double(transientAttempts - 1))))
                continue

            default:
                let body = String(data: data, encoding: .utf8) ?? ""
                DebugLog.write("[AIRouter] HTTP \(http.statusCode) for \(currentModel): \(body.prefix(200))")
                if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                    recordFailure(currentModel)
                }
                // Body begrenzen: keine unbegrenzten Fremd-Antworten in Fehlern
                // (und damit in Logs/Telemetrie der aufrufenden App) halten.
                throw AIRouterError.apiError(http.statusCode, String(body.prefix(500)))
            }
        }
    }

    /// Natives Cloud-Streaming via SSE. Liefert die gemeldeten Token-Zaehler;
    /// fehlt der Output-Zaehler, wird grob aus der Zeichenzahl geschaetzt.
    private func streamVertex(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws -> (input: Int, output: Int) {
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

        let outboundSystem = cloudPreflight.map { $0(system) } ?? system
        let outboundMessages = preflightedMessages(messages)

        let url = try vertexEndpoint(model: model, provider: desc.provider, streaming: true)
        let accessToken = try await getAccessToken()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.requestTimeout ?? cloudTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.vertexBody(provider: desc.provider, system: outboundSystem, messages: outboundMessages, maxTokens: maxTokens, options: options, stream: desc.provider == .anthropic))

        let clock = ContinuousClock()
        let start = clock.now
        let (lines, http): (AsyncThrowingStream<String, Error>, HTTPURLResponse)
        do {
            (lines, http) = try await transport.lines(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordFailure(model)
            throw error
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                recordFailure(model)
            }
            throw AIRouterError.apiError(http.statusCode, "Streaming request failed")
        }

        var inputTokens = 0
        var outputTokens = 0
        var charCount = 0

        for try await line in lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty, payload != "[DONE]",
                  let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            switch desc.provider {
            case .anthropic:
                switch json["type"] as? String {
                case "content_block_delta":
                    if let delta = json["delta"] as? [String: Any],
                       let text = delta["text"] as? String, !text.isEmpty {
                        charCount += text.count
                        continuation.yield(text)
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
                        outputTokens = output
                    }
                default:
                    break
                }
            case .google:
                if let candidates = json["candidates"] as? [[String: Any]],
                   let first = candidates.first,
                   let content = first["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]],
                   let text = parts.first?["text"] as? String, !text.isEmpty {
                    charCount += text.count
                    continuation.yield(text)
                }
                if let meta = json["usageMetadata"] as? [String: Any] {
                    inputTokens = meta["promptTokenCount"] as? Int ?? inputTokens
                    outputTokens = meta["candidatesTokenCount"] as? Int ?? outputTokens
                }
            case .local:
                break
            }
        }

        recordSuccess(model)
        let elapsed = clock.now - start
        let estimated = outputTokens == 0 && charCount > 0
        if estimated { outputTokens = charCount / 4 }
        emitUsage(task: task, model: model, input: inputTokens, output: outputTokens, elapsed: elapsed, isEstimated: estimated)
        return (inputTokens, outputTokens)
    }

    // MARK: - Custom cloud providers

    private func customProvider(for id: String) throws -> CloudInferenceProvider {
        guard let provider = customProviders[id] else {
            throw AIRouterError.notConfigured("Kein CloudInferenceProvider mit ID '\(id)' registriert. Rufe registerCloudProvider(_:) auf.")
        }
        return provider
    }

    private func isTransientStatus(_ status: Int) -> Bool {
        status == 429 || (500...599).contains(status)
    }

    /// Nicht-streamender Aufruf eines registrierten Providers. Router-seitig
    /// gelten Breaker, Retry-Policy, Preflight und Telemetrie wie bei Vertex.
    private func callCustom(providerID: String, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
        let provider = try customProvider(for: providerID)
        let outboundSystem = cloudPreflight.map { $0(system) } ?? system
        let outboundMessages = preflightedMessages(messages)

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
                        DebugLog.write("[AIRouter] HTTP \(status) for \(model) via '\(providerID)' (retry \(transientAttempts)): \(body.prefix(120))")
                        try await Task.sleep(for: .seconds(retryPolicy.baseDelay * pow(2.0, Double(transientAttempts - 1))))
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
    private func streamCustom(providerID: String, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws -> (input: Int, output: Int) {
        let provider = try customProvider(for: providerID)
        let outboundSystem = cloudPreflight.map { $0(system) } ?? system
        let outboundMessages = preflightedMessages(messages)

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
        case .local, .custom:
            throw AIRouterError.unexpectedResponse
        }
    }

    // MARK: - Local inference

    /// Fasst einen Konversationsverlauf fuer den bewusst minimalen
    /// ``LocalInferenceProvider`` (system+user-Signatur) zu einem Prompt zusammen.
    private static func flattenForLocalProvider(_ messages: [AIMessage]) -> String {
        if messages.count == 1, let only = messages.first { return only.content }
        return messages.map { message in
            (message.role == .assistant ? "Assistant: " : "User: ") + message.content
        }.joined(separator: "\n\n")
    }

    private func callLocal(model modelTag: String = "local", system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
        if let provider = localProvider, await provider.isReady {
            return try await callLocalProvider(provider: provider, system: system, messages: messages, maxTokens: maxTokens, task: task)
        }
        return try await callOllama(modelTag: modelTag, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task)
    }

    private func callLocalProvider(provider: LocalInferenceProvider, system: String, messages: [AIMessage], maxTokens: Int, task: AITask?) async throws -> CallResult {
        let clock = ContinuousClock()
        let start = clock.now
        let user = Self.flattenForLocalProvider(messages)
        let result = try await provider.generate(system: system, user: user, maxTokens: maxTokens)
        let elapsed = clock.now - start
        emitUsage(task: task, model: "local-provider", input: result.inputTokens, output: result.outputTokens, elapsed: elapsed)
        return CallResult(text: result.text, inputTokens: result.inputTokens, outputTokens: result.outputTokens)
    }

    private func ollamaChatBody(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, stream: Bool) -> [String: Any] {
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
        // Defense in depth: configureLocalLLM validiert bereits, hier erneut
        // pruefen, falls der Endpoint auf anderem Weg gesetzt wurde.
        guard let base = RouterValidation.validatedLocalEndpoint(localLLMEndpoint),
              let url = URL(string: "\(base)\(path)") else {
            throw AIRouterError.invalidEndpoint
        }
        return url
    }

    private func callOllama(modelTag: String = "local", system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?) async throws -> CallResult {
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
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AIRouterError.apiError(http.statusCode, String(body.prefix(500)))
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

    private func streamLocal(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        if let provider = localProvider, await provider.isReady {
            try await streamLocalProvider(provider: provider, system: system, messages: messages, maxTokens: maxTokens, task: task, continuation: continuation)
            return
        }
        try await streamOllama(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task, continuation: continuation)
    }

    private func streamLocalProvider(provider: LocalInferenceProvider, system: String, messages: [AIMessage], maxTokens: Int, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
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

    private func streamOllama(model modelTag: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, task: AITask?, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
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
    }

    // MARK: - Budget internals

    private func reserveBudget(task: AITask, estimatedTokens: Int) throws {
        resetHourIfNeeded()
        if task.priority == .critical {
            reservedTokens += estimatedTokens
            return
        }
        // Kosten-Grenze (USD) zusaetzlich zum Token-Budget.
        if let costCeiling = hourlyCostBudgetUSD, costThisHourUSD >= costCeiling {
            throttledTasks += 1
            DebugLog.write("[AIRouter] Kosten-Budget erreicht (\(costThisHourUSD) >= \(costCeiling) USD): \(task.rawValue) aufgeschoben")
            throw AIRouterError.budgetExhausted(task: task.rawValue)
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
        persistBudget()
    }

    private func releaseReservation(_ estimatedTokens: Int) {
        reservedTokens = max(0, reservedTokens - estimatedTokens)
    }

    private func resetHourIfNeeded() {
        if budgetClock.now - hourStartInstant >= .seconds(3600) {
            tokensUsedThisHour = 0
            reservedTokens = 0
            currentHourStart = Date()
            hourStartInstant = budgetClock.now
            costThisHourUSD = 0
            throttledTasks = 0
            persistBudget()
        }
    }

    /// Sekunden bis zum naechsten Budget-Fenster (monotone Uhr, min. 1 s).
    private func secondsUntilBudgetReset() -> Double {
        let elapsed = budgetClock.now - hourStartInstant
        let remaining = Duration.seconds(3600) - elapsed
        let seconds = Double(remaining.components.seconds) + 1
        return max(1, seconds)
    }

    /// Speichert den Budget-Zustand fire-and-forget in den konfigurierten Storage.
    private func persistBudget() {
        guard let storage else { return }
        let state = PersistedBudgetState(
            tokensUsed: tokensUsedThisHour,
            costUSD: costThisHourUSD,
            throttled: throttledTasks,
            hourStarted: currentHourStart
        )
        Task { await storage.saveBudgetState(state) }
    }

    // MARK: - Circuit breaker internals

    private func breakerIsOpen(_ model: String) -> Bool {
        guard let openedAt = breakers[model]?.openedAt else { return false }
        if budgetClock.now - openedAt >= breakerCooldown {
            // Cooldown abgelaufen -> Breaker schliessen, Modell wieder zulassen.
            breakers[model] = nil
            return false
        }
        return true
    }

    private func recordSuccess(_ model: String) {
        breakers[model] = nil
    }

    private func recordFailure(_ model: String) {
        statsFailures[model, default: 0] += 1
        var state = breakers[model] ?? BreakerState()
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= breakerThreshold && state.openedAt == nil {
            state.openedAt = budgetClock.now
            DebugLog.write("[AIRouter] Circuit-Breaker offen fuer \(model) (\(state.consecutiveFailures) Fehler in Folge)")
        }
        breakers[model] = state
    }

    // MARK: - Response cache internals

    private func responseCacheKey(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) -> ResponseCacheKey? {
        guard responseCacheMax > 0, cacheableTasks.contains(task) else { return nil }
        return ResponseCacheKey(task: task, model: model, system: system, messages: messages, maxTokens: maxTokens, options: options)
    }

    private func cachedResponse(for key: ResponseCacheKey) -> String? {
        guard let entry = responseCache[key] else { return nil }
        guard budgetClock.now - entry.storedAt < responseCacheTTL else {
            responseCache[key] = nil
            responseCacheOrder.removeAll { $0 == key }
            return nil
        }
        return entry.text
    }

    private func storeResponse(_ text: String, for key: ResponseCacheKey) {
        guard responseCacheMax > 0 else { return }
        if responseCache[key] == nil {
            responseCacheOrder.append(key)
        }
        responseCache[key] = ResponseCacheEntry(text: text, storedAt: budgetClock.now)
        while responseCacheOrder.count > responseCacheMax {
            let oldest = responseCacheOrder.removeFirst()
            responseCache[oldest] = nil
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

    // MARK: - Telemetry helpers

    private func preflightedMessages(_ messages: [AIMessage]) -> [AIMessage] {
        guard let hook = cloudPreflight else { return messages }
        return messages.map { AIMessage(role: $0.role, content: hook($0.content)) }
    }

    private func estimatedCost(model: String, input: Int, output: Int) -> Double? {
        guard let descriptor = catalog.descriptor(for: model),
              let inputCost = descriptor.inputCostPerMTok,
              let outputCost = descriptor.outputCostPerMTok else {
            return nil
        }
        return (Double(input) * inputCost + Double(output) * outputCost) / 1_000_000
    }

    private func emitUsage(task: AITask?, model: String, input: Int, output: Int, elapsed: Duration, isEstimated: Bool = false) {
        let cost = estimatedCost(model: model, input: input, output: output)
        if let cost {
            costThisHourUSD += cost
        }
        statsCalls[model, default: 0] += 1
        statsLatencyTotalMs[model, default: 0] += Self.milliseconds(elapsed)
        guard let callback = usageCallback else { return }
        callback(AIUsageInfo(
            task: task,
            model: model,
            inputTokens: input,
            outputTokens: output,
            timestamp: Date(),
            durationMs: Self.milliseconds(elapsed),
            isEstimated: isEstimated,
            costUSD: cost
        ))
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}
