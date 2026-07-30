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

    let vertexRegion: String
    let vertexProject: String
    let taskModels: [AITask: String]
    let taskRoutingPolicies: [AITask: RoutingPolicy]
    let accessTokenProvider: AccessTokenProvider?
    let transport: HTTPTransport
    let localTransport: HTTPTransport
    let retryPolicy: RetryPolicy
    var catalog: ModelCatalog

    var cachedToken: String?
    var tokenExpiresAt: Date?
    var usageCallback: (@Sendable (AIUsageInfo) -> Void)?
    /// Registrierte ``CloudInferenceProvider`` fuer Modelle mit
    /// `provider: .custom(id)` (OpenAI-kompatibel, Anthropic-direkt, eigene).
    var customProviders: [String: CloudInferenceProvider] = [:]
    /// Optionaler Persistenz-Hook: Budget-Zustand ueberlebt App-Neustarts.
    var storage: RouterStorage?
    /// Serialisiert Persistenz-Schreibvorgaenge: verhindert, dass ein aelterer
    /// Snapshot einen neueren ueberholt und ueberschreibt.
    var persistChain: Task<Void, Never>?
    /// Generation der Lokal-Konfiguration: ein langsamer aelterer
    /// configureLocalLLM-Aufruf darf eine neuere Konfiguration nicht ueberschreiben.
    var localConfigGeneration: UInt64 = 0
    /// Wird vor jedem Cloud-Versand auf System-Prompt und Nachrichteninhalte
    /// angewandt (z. B. PII-Redaktion). Lokale Aufrufe bleiben unveraendert.
    var cloudPreflight: (@Sendable (String) -> String)?

    var localLLMEndpoint: String = ""
    var localLLMModel: String = ""
    var localLLMNumCtx: Int = 4096
    let localLLMKeepAlive: String = "24h"
    var airplaneMode: Bool = false
    var energyMode: EnergyMode = .fullPower
    var localProvider: LocalInferenceProvider?
    /// Ollama-Modell-Discovery; austauschbar (z. B. fuer Tests), Default `.shared`.
    var ollamaDiscovery: OllamaService = .shared

    let cloudTimeout: TimeInterval = 60
    let localTimeout: TimeInterval = 120

    /// Dedizierte, gepoolte Session fuer lokale Inferenz (HTTP keep-alive zu localhost).
    static let ollamaSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.timeoutIntervalForRequest = 120
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Budget

    var hourlyTokenBudget: Int = 200_000
    var tokensUsedThisHour: Int = 0
    var reservedTokens: Int = 0
    var reservedCostUSD: Double = 0
    /// Fenster-Generation: schuetzt Settle/Release ueber Fenstergrenzen hinweg
    /// (siehe ``BudgetReservation``).
    var budgetEpoch: UInt64 = 0
    var currentHourStart: Date = Date()
    /// Monotone Uhr fuer Budget-Reset, Circuit-Breaker und Cache-TTL: Wanduhr-
    /// Spruenge (NTP, manuelle Zeitumstellung) koennen weder Budgets vorzeitig
    /// zuruecksetzen (Kosten-Bypass) noch Zustaende einfrieren.
    let budgetClock = ContinuousClock()
    var hourStartInstant: ContinuousClock.Instant
    /// Laenge des Budget-Fensters (nur fuer Tests veraenderbar).
    var budgetWindow: Duration = .seconds(3600)
    var throttledTasks: Int = 0
    var costThisHourUSD: Double = 0
    /// Optionales Kosten-Budget in USD pro Stunde (zusaetzlich zum Token-Budget).
    var hourlyCostBudgetUSD: Double?
    /// Wenn aktiv, warten Cloud-Aufrufe bei erschoepftem Budget (und ohne
    /// lokales Fallback) auf das naechste Stundenfenster statt zu werfen.
    var queueOnBudgetExhausted = false

    // MARK: - Concurrency limit

    var maxConcurrentCloudCalls = 8
    var activeCloudCalls = 0
    var slotWaiters: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []
    var nextSlotWaiterID: UInt64 = 0

    // MARK: - Model stats

    /// Latenz-/Fehler-Telemetrie pro Modell (fuer Monitoring und Routing-Debugging).
    public struct ModelStats: Sendable {
        public let model: String
        public let calls: Int
        public let failures: Int
        public let averageLatencyMs: Int
    }

    var statsCalls: [String: Int] = [:]
    var statsFailures: [String: Int] = [:]
    var statsLatencyTotalMs: [String: Int] = [:]

    // MARK: - Circuit breaker

    struct BreakerState {
        var consecutiveFailures: Int = 0
        var openedAt: ContinuousClock.Instant?
    }

    var breakers: [String: BreakerState] = [:]
    var breakerThreshold = 3
    /// Cooldown des Circuit-Breakers (nur fuer Tests veraenderbar).
    var breakerCooldown: Duration = .seconds(60)

    // MARK: - Test hooks (internal, nur via @testable erreichbar)

    func overrideBudgetWindowForTesting(seconds: TimeInterval) {
        budgetWindow = .seconds(seconds)
    }

    func overrideBreakerCooldownForTesting(seconds: TimeInterval) {
        breakerCooldown = .seconds(seconds)
    }

    // MARK: - Response cache

    struct ResponseCacheKey: Hashable {
        let task: AITask
        let model: String
        let system: String
        let messages: [AIMessage]
        let maxTokens: Int
        let options: GenerationOptions
    }

    struct ResponseCacheEntry {
        let text: String
        let storedAt: ContinuousClock.Instant
    }

    var responseCache: [ResponseCacheKey: ResponseCacheEntry] = [:]
    var responseCacheOrder: [ResponseCacheKey] = []
    var responseCacheTTL: Duration = .seconds(300)
    var responseCacheMax: Int = 0
    var cacheableTasks: Set<AITask> = []

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
        // Alle ContinuousClock-Instanzen messen dieselbe monotone Uhr;
        // self.budgetClock ist in Phase 1 der Initialisierung nicht lesbar.
        self.hourStartInstant = ContinuousClock().now
    }

    // MARK: - Configuration

    /// Konfiguriert das Ollama-Backend. Liefert `true`, wenn ein gueltiger
    /// Endpoint uebernommen wurde; `false` bei verworfenem Endpoint (nur
    /// http/https mit Host erlaubt) oder wenn ein neuerer Aufruf zuvorkam.
    @discardableResult
    public func configureLocalLLM(endpoint: String, model: String, numCtx: Int = 4096) async -> Bool {
        // Nur http/https mit Host akzeptieren — verhindert, dass ein fehlerhaft
        // oder boeswillig konfigurierter "lokaler" Endpoint Prompts an ein
        // unerwartetes Ziel (file://, fehlgeformte URL, ...) leitet.
        let validated = RouterValidation.validatedLocalEndpoint(endpoint)
        if !endpoint.isEmpty && validated == nil {
            DebugLog.write("[AIRouter] Ungueltiger lokaler Endpoint verworfen (erlaubt: http/https mit Host)")
        }
        localConfigGeneration += 1
        let generation = localConfigGeneration
        let sanitizedEndpoint = validated ?? ""

        // Kein Modell gewaehlt -> automatisch ein installiertes Ollama-Modell entdecken.
        var resolved = model
        if resolved.isEmpty && !sanitizedEndpoint.isEmpty {
            let available = await ollamaDiscovery.fetchModels(endpoint: sanitizedEndpoint)
            resolved = available.first(where: { $0.name.lowercased().contains("gemma") })?.name
                ?? available.first(where: { $0.name.lowercased().contains("qwen") })?.name
                ?? available.first?.name
                ?? ""
            if !resolved.isEmpty {
                DebugLog.write("[AIRouter] Kein localLLMModel gesetzt -> automatisch gewaehlt: \(resolved)")
            }
        }
        // Endpoint und Modell erst NACH der Discovery gemeinsam setzen —
        // waehrend des await darf kein Aufrufer einen Endpoint ohne Modell sehen.
        // Und nur, wenn kein neuerer configure-Aufruf dazwischenkam.
        guard generation == localConfigGeneration else { return false }
        self.localLLMNumCtx = max(512, numCtx)
        self.localLLMEndpoint = sanitizedEndpoint
        self.localLLMModel = resolved

        if !sanitizedEndpoint.isEmpty {
            DebugLog.write("[AIRouter] Local LLM konfiguriert: \(sanitizedEndpoint) (\(resolved.isEmpty ? "kein Modell" : resolved), num_ctx=\(self.localLLMNumCtx))")
        }
        return !sanitizedEndpoint.isEmpty
    }

    /// Konfiguriert einen In-Process-Anbieter lokaler Inferenz.
    public func configureLocalProvider(_ provider: LocalInferenceProvider) {
        self.localProvider = provider
        DebugLog.write("[AIRouter] LocalInferenceProvider konfiguriert")
    }

    public func isLocalModelReady() async -> Bool {
        if let provider = localProvider, await provider.isReady { return true }
        // Ein Endpoint ohne aufgeloestes Modell kann keinen Aufruf bedienen.
        return !localLLMEndpoint.isEmpty && !localLLMModel.isEmpty
    }

    public func localLLMEndpointValue() -> String {
        localLLMEndpoint
    }

    /// Aktueller Energiemodus (Gegenstueck zu ``setEnergyMode(_:)``).
    public var currentEnergyMode: EnergyMode { energyMode }

    /// Ob der Flugmodus aktiv ist (Gegenstueck zu ``setAirplaneMode(_:)``).
    public var isAirplaneMode: Bool { airplaneMode }

    /// Das konfigurierte bzw. automatisch entdeckte lokale Modell (leer = keins).
    public var localModelName: String { localLLMModel }

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
        responseCacheTTL = .seconds(max(0.001, ttlSeconds))
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

    /// Konfiguriert den Circuit-Breaker (Default: 3 Fehler in Folge, 60 s
    /// Cooldown; Minima 1 Fehler / 1 s).
    public func setBreakerParameters(failureThreshold: Int, cooldownSeconds: TimeInterval) {
        breakerThreshold = max(1, failureThreshold)
        breakerCooldown = .seconds(max(1, cooldownSeconds))
    }

    /// Laenge des Budget-Fensters in Sekunden (Default 3600, min. 60).
    public func setBudgetWindow(seconds: TimeInterval) {
        budgetWindow = .seconds(max(60, seconds))
    }

    /// Begrenzung paralleler Cloud-Aufrufe (Backpressure). Default: 8.
    public func setMaxConcurrentCloudCalls(_ limit: Int) {
        maxConcurrentCloudCalls = max(1, limit)
        // Frei gewordene Kapazitaet sofort an Wartende vergeben.
        while activeCloudCalls < maxConcurrentCloudCalls, !slotWaiters.isEmpty {
            activeCloudCalls += 1
            slotWaiters.removeFirst().continuation.resume(returning: ())
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

    /// Wartet, bis alle ausstehenden Budget-Persistierungen geschrieben sind —
    /// z. B. vor App-Terminierung, damit der letzte Stand nicht verloren geht.
    public func flushPersistence() async {
        await persistChain?.value
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

    public func send(task: AITask, system: String, user: String, maxTokens: Int? = nil, options: GenerationOptions = .default) async throws -> String {
        try await send(task: task, system: system, messages: [.user(user)], maxTokens: maxTokens, options: options)
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
        let estimate = estimatedRequestTokens(system: system, messages: messages, maxTokens: tokens)
        let policy = taskRoutingPolicies[task] ?? task.routingPolicy

        let cacheKey = responseCacheKey(task: task, model: model, system: system, messages: messages, maxTokens: tokens, options: options)
        if let key = cacheKey, let hit = cachedResponse(for: key) {
            DebugLog.write("[AIRouter] Cache-Treffer fuer \(task.rawValue)")
            return hit
        }

        let result: String
        // Degradierte Ergebnisse (Budget-Fallback auf ein schwaecheres lokales
        // Modell) duerfen nicht gecacht werden, sonst wird die schwaechere
        // Antwort bis TTL-Ablauf serviert, obwohl die Cloud wieder kann.
        var cacheStoreAllowed = true

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
                    cacheStoreAllowed = false
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

        if let key = cacheKey, cacheStoreAllowed {
            storeResponse(result, for: key)
        }
        return result
    }

    public func send(model: String, system: String, user: String, maxTokens: Int, options: GenerationOptions = .default) async throws -> String {
        try await send(model: model, system: system, messages: [.user(user)], maxTokens: maxTokens, options: options)
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
        // Voller Budget-Preflight wie beim Task-Pfad (Prioritaet .normal) —
        // der rohe Pfad ist kein Schlupfloch an den Kostengrenzen vorbei.
        let estimate = estimatedRequestTokens(system: system, messages: messages, maxTokens: maxTokens)
        try checkContextWindow(model: effectiveModel, estimate: estimate)
        let reservation = try reserveBudget(
            priority: .normal,
            label: "raw:\(effectiveModel)",
            estimatedTokens: estimate,
            estimatedCostUSD: estimatedRequestCostUSD(model: effectiveModel, estimate: estimate, maxTokens: maxTokens))
        do {
            try await acquireCloudSlot()
        } catch {
            releaseReservation(reservation)
            throw error
        }
        do {
            let result = try await callVertex(model: effectiveModel, system: system, messages: messages, maxTokens: maxTokens, options: options, task: nil)
            releaseCloudSlot()
            settleBudget(reservation, actualTokens: result.inputTokens + result.outputTokens)
            return result.text
        } catch {
            releaseCloudSlot()
            releaseReservation(reservation)
            throw error
        }
    }

    public func resolvedModelName(for task: AITask) -> String {
        resolveModel(for: task)
    }

    public func sendStreaming(task: AITask, system: String, user: String, maxTokens: Int? = nil, options: GenerationOptions = .default) -> AsyncThrowingStream<String, Error> {
        sendStreaming(task: task, system: system, messages: [.user(user)], maxTokens: maxTokens, options: options)
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
                    guard case .budgetExhausted = error else {
                        continuation.finish(throwing: error)
                        return
                    }
                    if self.hasLocalBackend() {
                        DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), Streaming-Fallback zu lokal")
                        do {
                            try await self.streamLocal(model: self.localModelTag, system: system, messages: messages, maxTokens: tokens, options: options, task: task, continuation: continuation)
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } else if self.queueOnBudgetExhausted {
                        // Warteschlange gilt auch fuer Streaming, nicht nur fuer send().
                        do {
                            let wait = self.secondsUntilBudgetReset()
                            DebugLog.write("[AIRouter] Budget erschoepft fuer \(task.rawValue), Streaming wartet \(Int(wait))s")
                            try await Task.sleep(for: .seconds(wait))
                            try await self.streamCloud(task: task, model: model, system: system, messages: messages, maxTokens: tokens, options: options, continuation: continuation)
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

    /// Streaming-Pendant zum rohen Modell-Pfad ``send(model:system:messages:maxTokens:options:)``.
    /// Unterliegt wie dieser dem vollen Budget-Preflight (Prioritaet `.normal`).
    public func sendStreaming(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions = .default) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                let effectiveModel = self.airplaneMode ? self.localModelTag : model
                if self.isLocalTag(effectiveModel) {
                    do {
                        try await self.streamLocal(model: effectiveModel, system: system, messages: messages, maxTokens: maxTokens, options: options, task: nil, continuation: continuation)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                do {
                    let estimate = self.estimatedRequestTokens(system: system, messages: messages, maxTokens: maxTokens)
                    try self.checkContextWindow(model: effectiveModel, estimate: estimate)
                    let reservation = try self.reserveBudget(
                        priority: .normal,
                        label: "raw:\(effectiveModel)",
                        estimatedTokens: estimate,
                        estimatedCostUSD: self.estimatedRequestCostUSD(model: effectiveModel, estimate: estimate, maxTokens: maxTokens))
                    do {
                        try await self.acquireCloudSlot()
                    } catch {
                        self.releaseReservation(reservation)
                        throw error
                    }
                    do {
                        let usage = try await self.streamVertex(model: effectiveModel, system: system, messages: messages, maxTokens: maxTokens, options: options, task: nil, continuation: continuation)
                        self.releaseCloudSlot()
                        self.settleBudget(reservation, actualTokens: usage.input + usage.output)
                        continuation.finish()
                    } catch {
                        self.releaseCloudSlot()
                        self.releaseReservation(reservation)
                        throw error
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
        /// Sekunden bis zum Fenster-Reset — aus der monotonen Uhr abgeleitet
        /// (konsistent mit dem tatsaechlichen Reset, unbeeindruckt von
        /// Wanduhr-Spruengen).
        public let secondsUntilReset: Int
        /// Konfiguriertes USD-Stunden-Ceiling (`nil` = keine Kosten-Grenze).
        public let costBudgetUSD: Double?
        /// Auslastung der Kosten-Grenze (0…1+); `nil` ohne Kosten-Grenze.
        public var costUtilization: Double? {
            costBudgetUSD.map { $0 > 0 ? costUSD / $0 : 0 }
        }
        public var remaining: Int { max(0, tokenBudget - tokensUsed - tokensReserved) }
        public var utilization: Double { tokenBudget > 0 ? Double(tokensUsed + tokensReserved) / Double(tokenBudget) : 0 }
        public var minutesUntilReset: Int { secondsUntilReset / 60 }
    }

    public func budgetStatus() -> BudgetStatus {
        resetHourIfNeeded()
        return BudgetStatus(
            tokensUsed: tokensUsedThisHour,
            tokensReserved: reservedTokens,
            tokenBudget: hourlyTokenBudget,
            throttledCount: throttledTasks,
            hourStarted: currentHourStart,
            costUSD: costThisHourUSD,
            secondsUntilReset: Int(rawSecondsUntilReset()),
            costBudgetUSD: hourlyCostBudgetUSD
        )
    }

    /// Betriebszustand fuer Monitoring und Debug-Panels.
    public struct HealthStatus: Sendable {
        /// Modelle mit aktuell offenem Circuit-Breaker.
        public let openBreakers: [String]
        public let activeCloudCalls: Int
        public let queuedCloudCalls: Int
        public let maxConcurrentCloudCalls: Int
        public let responseCacheEntries: Int
        public let registeredProviders: [String]
        public let localBackendConfigured: Bool
    }

    public func healthStatus() -> HealthStatus {
        HealthStatus(
            openBreakers: breakers.compactMap { model, state -> String? in
                guard let openedAt = state.openedAt,
                      budgetClock.now - openedAt < breakerCooldown else { return nil }
                return model
            }.sorted(),
            activeCloudCalls: activeCloudCalls,
            queuedCloudCalls: slotWaiters.count,
            maxConcurrentCloudCalls: maxConcurrentCloudCalls,
            responseCacheEntries: responseCache.count,
            registeredProviders: customProviders.keys.sorted(),
            localBackendConfigured: hasLocalBackend()
        )
    }

    /// Alle im Katalog bekannten Modellnamen (Defaults + `additionalModels`).
    public func availableModels() -> [String] {
        catalog.modelNames
    }
}
