import XCTest
@testable import AIRouter

// MARK: - Test doubles

/// Konfigurierbarer HTTP-Transport fuer Tests. Liefert vordefinierte Antworten
/// pro Aufruf und zaehlt die Requests.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data
    }

    private let lock = NSLock()
    private var responses: [Response]
    private(set) var requests: [URLRequest] = []
    private let streamLines: [String]
    private let streamStatus: Int

    init(responses: [Response], streamLines: [String] = [], streamStatus: Int = 200) {
        self.responses = responses
        self.streamLines = streamLines
        self.streamStatus = streamStatus
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    // Sperren nur in synchronen Helfern — NSLock ist in async-Kontexten tabu.
    private func consumeResponse(for request: URLRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return responses.isEmpty ? Response(status: 500, body: Data()) : responses.removeFirst()
    }

    private func recordStreamRequest(_ request: URLRequest) -> [String] {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return streamLines
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = consumeResponse(for: request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (response.body, http)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let lines = recordStreamRequest(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: streamStatus, httpVersion: nil, headerFields: nil)!
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return (stream, http)
    }
}

private func anthropicBody(text: String, input: Int = 10, output: Int = 20) -> Data {
    let json: [String: Any] = [
        "content": [["type": "text", "text": text]],
        "usage": ["input_tokens": input, "output_tokens": output]
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func googleBody(text: String, input: Int = 10, output: Int = 20) -> Data {
    let json: [String: Any] = [
        "candidates": [["content": ["parts": [["text": text]]]]],
        "usageMetadata": ["promptTokenCount": input, "candidatesTokenCount": output]
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

private func token() -> AccessToken {
    AccessToken(value: "test-token", lifetime: 3600)
}

/// Standard-Router fuer Tests: feste Region/Projekt, Token-Provider, Mock-Transport.
private func makeRouter(
    transport: HTTPTransport,
    taskModels: [AITask: String] = [:],
    additionalModels: [String: ModelDescriptor] = [:],
    retryPolicy: RetryPolicy = .default
) -> AIRouter {
    AIRouter(
        vertexRegion: "us-central1",
        vertexProject: "demo",
        taskModels: taskModels,
        accessTokenProvider: { token() },
        transport: transport,
        additionalModels: additionalModels,
        retryPolicy: retryPolicy
    )
}

final class AIRouterTests: XCTestCase {

    // MARK: - Static metadata

    func testTaskDefaultsAreConsistent() {
        for task in AITask.allCases {
            XCTAssertFalse(task.defaultModel.isEmpty, "\(task) hat kein Default-Modell")
            XCTAssertGreaterThan(task.defaultMaxTokens, 0, "\(task) hat kein Token-Budget")
            XCTAssertFalse(task.displayName.isEmpty)
            XCTAssertNotNil(
                ModelCatalog.default.descriptor(for: task.defaultModel),
                "\(task): defaultModel '\(task.defaultModel)' fehlt im Standardkatalog")
        }
    }

    func testRoutingPolicyAndPriorityExpectations() {
        XCTAssertEqual(AITask.dossierSynthesis.routingPolicy, .cloudOnly)
        XCTAssertEqual(AITask.emailRelevance.routingPolicy, .preferLocal)
        XCTAssertEqual(AITask.memoryQuery.routingPolicy, .preferCloud)
        XCTAssertEqual(AITask.dossierSynthesis.priority, .critical)
        XCTAssertEqual(AITask.bundleSynthesis.priority, .low)
    }

    // MARK: - Routing

    func testOfflineModeResolvesLocal() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.setEnergyMode(.offline)
        let model = await router.resolvedModelName(for: .dossierSynthesis)
        XCTAssertEqual(model, "local:gemma3")
    }

    func testMaxCloudUpgradesModel() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.setEnergyMode(.maxCloud)
        // meetingSummary default = gemini-2.5-flash -> upgrade -> gemini-2.5-pro
        let model = await router.resolvedModelName(for: .meetingSummary)
        XCTAssertEqual(model, "gemini-2.5-pro")
    }

    func testTaskModelOverride() async {
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "claude-sonnet-4-6"]
        )
        let model = await router.resolvedModelName(for: .factCheck)
        XCTAssertEqual(model, "claude-sonnet-4-6")
    }

    // MARK: - Budget

    func testBudgetStatusDefaults() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokenBudget, 200_000)
        XCTAssertEqual(status.tokensUsed, 0)
        XCTAssertEqual(status.remaining, 200_000)
    }

    // MARK: - Cloud call via mock transport

    func testSuccessfulCloudCallSettlesBudget() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "hello", input: 7, output: 13))])
        let router = makeRouter(transport: transport)
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "hello")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 20) // 7 + 13 actual tokens
        XCTAssertEqual(status.tokensReserved, 0) // reservation settled
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testTokenRefreshDoesNotConsumeTransientRetry() async throws {
        // First 401 -> refresh, then 200. Two requests total.
        let transport = MockTransport(responses: [
            .init(status: 401, body: Data("unauthorized".utf8)),
            .init(status: 200, body: googleBody(text: "ok"))
        ])
        let counter = Counter()
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: {
                let n = counter.next()
                return AccessToken(value: "tok-\(n)", lifetime: 3600)
            },
            transport: transport
        )
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testNotFoundFollowsFallbackChain() async throws {
        // opus -> 404 -> sonnet -> 200
        let transport = MockTransport(responses: [
            .init(status: 404, body: Data("not found".utf8)),
            .init(status: 200, body: anthropicBody(text: "fallback"))
        ])
        let router = makeRouter(transport: transport, taskModels: [.factCheck: "claude-opus-4-6"])
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testUnknownModelThrows() async {
        let transport = MockTransport(responses: [])
        let router = makeRouter(transport: transport, taskModels: [.factCheck: "totally-unknown-model"])
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected notConfigured error")
        } catch let error as AIRouterError {
            guard case .notConfigured = error else {
                return XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testUsageCallbackEmitted() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "x", input: 3, output: 4))])
        let router = makeRouter(transport: transport)
        let box = UsageBox()
        await router.setUsageCallback { info in box.store(info) }
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        // Der Callback laeuft synchron innerhalb des send-Aufrufs.
        let captured = box.value
        XCTAssertEqual(captured?.inputTokens, 3)
        XCTAssertEqual(captured?.outputTokens, 4)
    }

    func testBudgetExhaustedThrowsBeforeNetwork() async {
        let transport = MockTransport(responses: [])
        let router = makeRouter(transport: transport)
        await router.setHourlyBudget(10_000) // low-prio ceiling = 7.5k
        // factCheck is .low priority; maxTokens 8000 -> estimate ~8000 > 7500 ceiling.
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 8_000)
            XCTFail("Expected budgetExhausted")
        } catch let error as AIRouterError {
            guard case .budgetExhausted = error else {
                return XCTFail("Expected budgetExhausted, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0, "Budget muss vor dem Netzaufruf greifen")
    }

    // MARK: - Security hardening

    func testValidationRules() {
        XCTAssertTrue(RouterValidation.isValidRegion("us-central1"))
        XCTAssertFalse(RouterValidation.isValidRegion("us-central1/evil"))
        XCTAssertFalse(RouterValidation.isValidRegion("evil.com"))
        XCTAssertFalse(RouterValidation.isValidRegion(""))

        XCTAssertTrue(RouterValidation.isValidProject("my-project-123"))
        XCTAssertTrue(RouterValidation.isValidProject("example.com:legacy"))
        XCTAssertFalse(RouterValidation.isValidProject("proj/../../etc"))

        XCTAssertTrue(RouterValidation.isValidModelName("gemini-2.5-flash"))
        XCTAssertTrue(RouterValidation.isValidModelName("claude-3-5-sonnet@20240620"))
        XCTAssertFalse(RouterValidation.isValidModelName("evil/../model"))
        XCTAssertFalse(RouterValidation.isValidModelName("model?x=1"))

        XCTAssertEqual(RouterValidation.validatedLocalEndpoint("http://localhost:11434/"), "http://localhost:11434")
        XCTAssertEqual(RouterValidation.validatedLocalEndpoint("https://my-host:8080"), "https://my-host:8080")
        XCTAssertNil(RouterValidation.validatedLocalEndpoint("file:///etc/passwd"))
        XCTAssertNil(RouterValidation.validatedLocalEndpoint("localhost:11434"))
        XCTAssertNil(RouterValidation.validatedLocalEndpoint(""))
    }

    func testMaliciousRegionRejectedBeforeNetwork() async {
        // Region landet im Hostnamen: "us-central1.evil.com/x" wuerde den Request
        // (inkl. Bearer-Token) auf einen fremden Host umleiten.
        let transport = MockTransport(responses: [])
        let router = AIRouter(
            vertexRegion: "us-central1.evil.com/x",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected notConfigured error")
        } catch let error as AIRouterError {
            guard case .notConfigured = error else {
                return XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0, "Kein Request darf den Host verlassen")
    }

    func testModelNameWithPathInjectionRejected() async {
        let transport = MockTransport(responses: [])
        let router = makeRouter(transport: transport, taskModels: [.factCheck: "evil/../../model"], additionalModels: ["evil/../../model": ModelDescriptor(provider: .google)])
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected notConfigured error")
        } catch let error as AIRouterError {
            guard case .notConfigured = error else {
                return XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testInvalidLocalEndpointIsDiscarded() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.configureLocalLLM(endpoint: "file:///etc/passwd", model: "gemma3")
        let ready = await router.isLocalModelReady()
        XCTAssertFalse(ready, "Ungueltiger Endpoint darf lokale Inferenz nicht aktivieren")
        let stored = await router.localEndpoint
        XCTAssertTrue(stored.isEmpty)
    }

    func testLocalEndpointNormalized() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.configureLocalLLM(endpoint: "http://localhost:11434/", model: "gemma3")
        let stored = await router.localEndpoint
        XCTAssertEqual(stored, "http://localhost:11434")
    }

    func testRawModelSendCountsTowardBudget() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "raw", input: 5, output: 9))])
        let router = makeRouter(transport: transport)
        let result = try await router.send(model: "gemini-2.5-flash", system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "raw")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 14, "Roher Modell-Pfad muss auf das Budget einzahlen")
    }

    func testApiErrorBodyIsCapped() async {
        let bigBody = String(repeating: "x", count: 5_000)
        let transport = MockTransport(responses: [.init(status: 400, body: Data(bigBody.utf8))])
        let router = makeRouter(transport: transport)
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected apiError")
        } catch let error as AIRouterError {
            guard case .apiError(let code, let body) = error else {
                return XCTFail("Expected apiError, got \(error)")
            }
            XCTAssertEqual(code, 400)
            XCTAssertLessThanOrEqual(body.count, 500, "Fehler-Body muss begrenzt sein")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Multi-Turn & Optionen

    private func jsonBody(of request: URLRequest?) -> [String: Any] {
        guard let data = request?.httpBody,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    func testMultiTurnMessagesInAnthropicBody() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: anthropicBody(text: "ok"))])
        let router = makeRouter(transport: transport, taskModels: [.factCheck: "claude-sonnet-4-6"])
        let messages: [AIMessage] = [.user("Hallo"), .assistant("Hi!"), .user("Weiter")]
        _ = try await router.send(task: .factCheck, system: "s", messages: messages, maxTokens: 100)

        let body = jsonBody(of: transport.requests.first)
        let sent = body["messages"] as? [[String: Any]]
        XCTAssertEqual(sent?.count, 3)
        XCTAssertEqual(sent?.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(sent?.last?["content"] as? String, "Weiter")
    }

    func testGenerationOptionsInGoogleBody() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "ok"))])
        let router = makeRouter(transport: transport)
        let options = GenerationOptions(temperature: 0.7, topP: 0.5, topK: 40, stopSequences: ["END"])
        _ = try await router.send(task: .factCheck, system: "s", messages: [.user("u")], maxTokens: 100, options: options)

        let body = jsonBody(of: transport.requests.first)
        let config = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["temperature"] as? Double, 0.7)
        XCTAssertEqual(config?["topP"] as? Double, 0.5)
        XCTAssertEqual(config?["topK"] as? Int, 40)
        XCTAssertEqual(config?["stopSequences"] as? [String], ["END"])
    }

    // MARK: - Cloud-Streaming (SSE)

    func testGoogleCloudStreamingParsesSSE() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"Hel\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"lo\"}]}}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":2}}"
        ]
        let transport = MockTransport(responses: [], streamLines: lines)
        let router = makeRouter(transport: transport)
        var chunks: [String] = []
        for try await chunk in await router.sendStreaming(task: .factCheck, system: "s", user: "u") {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.joined(), "Hello")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 7, "SSE-Usage muss ins Budget einfliessen")
        XCTAssertEqual(status.tokensReserved, 0, "Reservierung muss verrechnet sein")
        let url = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains(":streamGenerateContent"), "Google muss den SSE-Endpoint nutzen")
    }

    func testAnthropicCloudStreamingParsesSSE() async throws {
        let lines = [
            "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":3}}}",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hi\"}}",
            "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":1}}"
        ]
        let transport = MockTransport(responses: [], streamLines: lines)
        let router = makeRouter(transport: transport, taskModels: [.factCheck: "claude-sonnet-4-6"])
        var chunks: [String] = []
        for try await chunk in await router.sendStreaming(task: .factCheck, system: "s", user: "u") {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.joined(), "Hi")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 4)
        let url = transport.requests.first?.url?.absoluteString ?? ""
        XCTAssertTrue(url.contains(":streamRawPredict"), "Anthropic muss den SSE-Endpoint nutzen")
    }

    // MARK: - Antwort-Cache

    func testResponseCacheHitAvoidsSecondRequest() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "cached"))])
        let router = makeRouter(transport: transport)
        await router.enableResponseCache(tasks: [.factCheck])
        let first = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        let second = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(first, "cached")
        XCTAssertEqual(second, "cached")
        XCTAssertEqual(transport.requestCount, 1, "Zweiter Aufruf muss aus dem Cache kommen")
    }

    func testResponseCacheDisabledByDefault() async throws {
        let transport = MockTransport(responses: [
            .init(status: 200, body: googleBody(text: "a")),
            .init(status: 200, body: googleBody(text: "b"))
        ])
        let router = makeRouter(transport: transport)
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(transport.requestCount, 2)
    }

    // MARK: - Circuit-Breaker

    func testCircuitBreakerOpensAfterRepeatedFailures() async {
        let transport = MockTransport(responses: [
            .init(status: 503, body: Data()),
            .init(status: 503, body: Data()),
            .init(status: 503, body: Data())
        ])
        let router = makeRouter(transport: transport, retryPolicy: RetryPolicy(maxTransientRetries: 0, baseDelay: 0))
        for _ in 0..<3 {
            do {
                _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
                XCTFail("Expected apiError")
            } catch let error as AIRouterError {
                guard case .apiError(503, _) = error else {
                    return XCTFail("Expected apiError(503), got \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        // gemini-2.5-flash hat keinen Fallback -> 4. Aufruf muss am offenen
        // Breaker scheitern, ohne das Netz zu beruehren.
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected circuitOpen")
        } catch let error as AIRouterError {
            guard case .circuitOpen(let model) = error else {
                return XCTFail("Expected circuitOpen, got \(error)")
            }
            XCTAssertEqual(model, "gemini-2.5-flash")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 3)
    }

    // MARK: - Preflight-Hook (PII-Redaktion)

    func testCloudPreflightRedactsOutboundContent() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "ok"))])
        let router = makeRouter(transport: transport)
        await router.setCloudPreflight { text in
            text.replacingOccurrences(of: "SECRET", with: "[redacted]")
        }
        _ = try await router.send(task: .factCheck, system: "SECRET system", user: "user SECRET data", maxTokens: 100)

        let raw = String(data: transport.requests.first?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(raw.contains("SECRET"), "Preflight muss ausgehende Cloud-Inhalte redigieren")
        XCTAssertTrue(raw.contains("[redacted]"))
    }

    // MARK: - Kosten-Telemetrie

    func testCostTelemetryFromCatalogPrices() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "x", input: 100_000, output: 10_000))])
        let router = makeRouter(transport: transport)
        let box = UsageBox()
        await router.setUsageCallback { info in box.store(info) }
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)

        // gemini-2.5-flash: 0.30/MTok in, 2.50/MTok out -> 0.03 + 0.025 = 0.055 USD
        let cost = box.value?.costUSD
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost ?? 0, 0.055, accuracy: 0.0001)
        let status = await router.budgetStatus()
        XCTAssertEqual(status.costUSD, 0.055, accuracy: 0.0001)
    }

    // MARK: - CloudInferenceProvider (Custom-Provider)

    func testCustomProviderRouting() async throws {
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "grok-beta"],
            additionalModels: ["grok-beta": ModelDescriptor(provider: .custom("mock"))]
        )
        await router.registerCloudProvider(MockCloudProvider(id: "mock", text: "custom!"))
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "custom!")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 7, "Custom-Provider muss auf das Budget einzahlen")
        XCTAssertEqual(status.tokensReserved, 0)
    }

    func testCustomProviderStreaming() async throws {
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "grok-beta"],
            additionalModels: ["grok-beta": ModelDescriptor(provider: .custom("mock"))]
        )
        await router.registerCloudProvider(MockCloudProvider(id: "mock", text: "custom!"))
        var chunks: [String] = []
        for try await chunk in await router.sendStreaming(task: .factCheck, system: "s", user: "u") {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.joined(), "custom!")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 7)
    }

    func testUnregisteredCustomProviderThrows() async {
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "grok-beta"],
            additionalModels: ["grok-beta": ModelDescriptor(provider: .custom("missing"))]
        )
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected notConfigured")
        } catch let error as AIRouterError {
            guard case .notConfigured = error else {
                return XCTFail("Expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOpenAICompatibleProviderParsesResponse() async throws {
        let responseJSON: [String: Any] = [
            "choices": [["message": ["content": "openai-ok"]]],
            "usage": ["prompt_tokens": 5, "completion_tokens": 6]
        ]
        let body = try JSONSerialization.data(withJSONObject: responseJSON)
        let transport = MockTransport(responses: [.init(status: 200, body: body)])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKeyProvider: { "sk-test" },
            transport: transport
        )
        let response = try await provider.generate(model: "gpt-4o", system: "s", messages: [.user("u")], maxTokens: 50, options: .default)
        XCTAssertEqual(response.text, "openai-ok")
        XCTAssertEqual(response.inputTokens, 5)
        XCTAssertEqual(response.outputTokens, 6)

        let request = transport.requests.first
        XCTAssertEqual(request?.url?.absoluteString, "https://api.example.com/v1/chat/completions")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testAnthropicDirectProviderParsesResponse() async throws {
        let responseJSON: [String: Any] = [
            "content": [["type": "text", "text": "anthropic-ok"]],
            "usage": ["input_tokens": 8, "output_tokens": 9]
        ]
        let body = try JSONSerialization.data(withJSONObject: responseJSON)
        let transport = MockTransport(responses: [.init(status: 200, body: body)])
        let provider = AnthropicDirectProvider(
            apiKeyProvider: { "sk-ant-test" },
            transport: transport
        )
        let response = try await provider.generate(model: "claude-sonnet-4-6", system: "s", messages: [.user("u")], maxTokens: 50, options: .default)
        XCTAssertEqual(response.text, "anthropic-ok")
        XCTAssertEqual(response.inputTokens, 8)
        XCTAssertEqual(response.outputTokens, 9)

        let request = transport.requests.first
        XCTAssertEqual(request?.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    // MARK: - JSON-Mode, Kosten-Budget, Statistik, Persistenz

    func testJsonModeInGoogleBody() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "{}"))])
        let router = makeRouter(transport: transport)
        _ = try await router.send(task: .factCheck, system: "s", messages: [.user("u")], maxTokens: 100, options: GenerationOptions(jsonMode: true))
        let body = jsonBody(of: transport.requests.first)
        let config = body["generationConfig"] as? [String: Any]
        XCTAssertEqual(config?["responseMimeType"] as? String, "application/json")
    }

    func testCostBudgetThrottles() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "x", input: 100_000, output: 10_000))])
        let router = makeRouter(transport: transport)
        await router.setHourlyCostBudget(usd: 0.01)
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100) // Kosten: 0.055 USD
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected budgetExhausted")
        } catch let error as AIRouterError {
            guard case .budgetExhausted = error else {
                return XCTFail("Expected budgetExhausted, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 1, "Kosten-Grenze muss vor dem Netzaufruf greifen")
    }

    func testModelStatsRecorded() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "ok"))])
        let router = makeRouter(transport: transport)
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        let stats = await router.modelStats()
        let flash = stats.first { $0.model == "gemini-2.5-flash" }
        XCTAssertEqual(flash?.calls, 1)
        XCTAssertEqual(flash?.failures, 0)
    }

    func testStorageRestoresBudgetWithinHour() async throws {
        let initial = PersistedBudgetState(tokensUsed: 1234, costUSD: 0.5, throttled: 2, hourStarted: Date().addingTimeInterval(-600))
        let storage = MemoryStorage(initial: initial)
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.configureStorage(storage)
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 1234)
        XCTAssertEqual(status.costUSD, 0.5, accuracy: 0.0001)
        XCTAssertEqual(status.throttledCount, 2)
    }

    func testBudgetEstimateIncludesInput() async {
        // Grosser Input muss in die Reservierung einfliessen, auch wenn
        // maxTokens klein ist (~40k Zeichen ≈ 10k Tokens > 7.5k-Ceiling).
        let transport = MockTransport(responses: [])
        let router = makeRouter(transport: transport)
        await router.setHourlyBudget(10_000)
        let hugeInput = String(repeating: "x", count: 40_000)
        do {
            _ = try await router.send(task: .factCheck, system: hugeInput, user: "u", maxTokens: 100)
            XCTFail("Expected budgetExhausted")
        } catch let error as AIRouterError {
            guard case .budgetExhausted = error else {
                return XCTFail("Expected budgetExhausted, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testQueueOnBudgetExhaustedRetriesNextWindow() async throws {
        let transport = MockTransport(responses: [
            .init(status: 200, body: googleBody(text: "big", input: 4_000, output: 4_000)),
            .init(status: 200, body: googleBody(text: "queued"))
        ])
        let router = makeRouter(transport: transport)
        await router.setHourlyBudget(10_000)
        await router.overrideBudgetWindowForTesting(seconds: 1)
        await router.setQueueOnBudgetExhausted(true)
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100) // verbraucht 8000
        // Zweiter Aufruf: 8000 + estimate > 7500-Ceiling -> wartet aufs neue Fenster.
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "queued")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testConcurrencyLimitSerializesCloudCalls() async throws {
        let transport = GatedTransport(body: googleBody(text: "ok"))
        let router = makeRouter(transport: transport)
        await router.setMaxConcurrentCloudCalls(1)
        let first = Task { try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100) }
        let second = Task { try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.startedCount, 1, "Zweiter Call muss auf den Slot warten")
        transport.open()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(transport.startedCount, 2)
    }

    func testCircuitBreakerClosesAfterCooldown() async throws {
        let transport = MockTransport(responses: [
            .init(status: 503, body: Data()),
            .init(status: 503, body: Data()),
            .init(status: 503, body: Data()),
            .init(status: 200, body: googleBody(text: "recovered"))
        ])
        let router = makeRouter(transport: transport, retryPolicy: RetryPolicy(maxTransientRetries: 0, baseDelay: 0))
        await router.overrideBreakerCooldownForTesting(seconds: 0.1)
        for _ in 0..<3 {
            _ = try? await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        }
        try await Task.sleep(for: .milliseconds(250))
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "recovered", "Breaker muss nach Cooldown wieder schliessen")
    }

    func testResponseCacheExpiresAfterTTL() async throws {
        let transport = MockTransport(responses: [
            .init(status: 200, body: googleBody(text: "a")),
            .init(status: 200, body: googleBody(text: "b"))
        ])
        let router = makeRouter(transport: transport)
        await router.enableResponseCache(tasks: [.factCheck], ttlSeconds: 0.1)
        let first = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        try await Task.sleep(for: .milliseconds(250))
        let second = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(first, "a")
        XCTAssertEqual(second, "b", "Abgelaufener Cache-Eintrag muss neu geladen werden")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testLocalFallbackResultNotCached() async throws {
        let ollamaBody = try JSONSerialization.data(withJSONObject: [
            "message": ["content": "local"], "prompt_eval_count": 1, "eval_count": 2
        ])
        let transport = MockTransport(responses: [
            .init(status: 200, body: ollamaBody),
            .init(status: 200, body: ollamaBody)
        ])
        let router = makeRouter(transport: transport)
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.setHourlyBudget(10_000)
        await router.enableResponseCache(tasks: [.factCheck])
        let hugeInput = String(repeating: "x", count: 40_000) // erzwingt budgetExhausted -> lokal
        let first = try await router.send(task: .factCheck, system: hugeInput, user: "u", maxTokens: 100)
        let second = try await router.send(task: .factCheck, system: hugeInput, user: "u", maxTokens: 100)
        XCTAssertEqual(first, "local")
        XCTAssertEqual(second, "local")
        XCTAssertEqual(transport.requestCount, 2, "Degradiertes Fallback-Ergebnis darf nicht gecacht werden")
    }

    func testOllamaServiceParsesModels() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "models": [["name": "gemma3:latest", "size": 3_000_000_000, "details": ["parameter_size": "4B"]]]
        ])
        let transport = MockTransport(responses: [.init(status: 200, body: body)])
        let service = OllamaService(transport: transport)
        let models = await service.fetchModels(endpoint: "http://localhost:11434")
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.name, "gemma3:latest")
        XCTAssertEqual(models.first?.parameterSize, "4B")
    }

    func testInsecureRemoteCloudBaseRejected() async {
        // http:// nur fuer Loopback/private Hosts — Keys nie im Klartext ins Netz.
        XCTAssertNotNil(RouterValidation.validatedCloudBase("http://localhost:8000/v1"))
        XCTAssertNotNil(RouterValidation.validatedCloudBase("http://192.168.1.20:8000/v1"))
        XCTAssertNotNil(RouterValidation.validatedCloudBase("https://api.example.com/v1"))
        XCTAssertNil(RouterValidation.validatedCloudBase("http://api.example.com/v1"))
        XCTAssertNotNil(RouterValidation.validatedCloudBase("http://api.example.com/v1", allowInsecureHTTP: true))

        // IP-Praefix-Bypass: DNS-Namen, die wie private Bereiche BEGINNEN,
        // sind NICHT privat.
        XCTAssertFalse(RouterValidation.isPrivateOrLoopbackHost("10.evil.com"))
        XCTAssertFalse(RouterValidation.isPrivateOrLoopbackHost("192.168.evil.com"))
        XCTAssertFalse(RouterValidation.isPrivateOrLoopbackHost("127.0.0.1.evil.com"))
        XCTAssertTrue(RouterValidation.isPrivateOrLoopbackHost("10.0.0.5"))
        XCTAssertTrue(RouterValidation.isPrivateOrLoopbackHost("172.20.1.1"))
        XCTAssertFalse(RouterValidation.isPrivateOrLoopbackHost("172.32.0.1"))
        XCTAssertNil(RouterValidation.validatedCloudBase("http://10.evil.com/v1"))

        let provider = OpenAICompatibleProvider(
            baseURL: "http://api.example.com/v1",
            apiKeyProvider: { "sk-test" },
            transport: MockTransport(responses: [])
        )
        do {
            _ = try await provider.generate(model: "m", system: "s", messages: [.user("u")], maxTokens: 10, options: .default)
            XCTFail("Expected invalidEndpoint")
        } catch let error as AIRouterError {
            guard case .invalidEndpoint = error else {
                return XCTFail("Expected invalidEndpoint, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMaxCompletionTokensField() async throws {
        let responseJSON: [String: Any] = [
            "choices": [["message": ["content": "ok"]]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 2]
        ]
        let transport = MockTransport(responses: [.init(status: 200, body: try JSONSerialization.data(withJSONObject: responseJSON))])
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKeyProvider: { "k" },
            transport: transport,
            tokenLimitField: .maxCompletionTokens
        )
        _ = try await provider.generate(model: "o4-mini", system: "s", messages: [.user("u")], maxTokens: 42, options: .default)
        let body = jsonBody(of: transport.requests.first)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 42)
        XCTAssertNil(body["max_tokens"])
    }

    func testStoragePersistsAfterSettle() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "x", input: 7, output: 13))])
        let router = makeRouter(transport: transport)
        let storage = MemoryStorage(initial: nil)
        await router.configureStorage(storage)
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        await router.flushPersistence() // deterministisch statt Sleep-Race
        XCTAssertEqual(storage.current?.tokensUsed, 20)
    }

    func testContextWindowExceededFailsFast() async {
        let transport = MockTransport(responses: [])
        let router = makeRouter(
            transport: transport,
            taskModels: [.factCheck: "tiny-model"],
            additionalModels: ["tiny-model": ModelDescriptor(provider: .google, contextWindow: 1_000)]
        )
        do {
            _ = try await router.send(task: .factCheck, system: String(repeating: "x", count: 8_000), user: "u", maxTokens: 100)
            XCTFail("Expected contextWindowExceeded")
        } catch let error as AIRouterError {
            guard case .contextWindowExceeded = error else {
                return XCTFail("Expected contextWindowExceeded, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testRawModelSendEnforcesBudget() async {
        // Der rohe Modell-Pfad darf die Budgetgrenzen nicht umgehen.
        let transport = MockTransport(responses: [])
        let router = makeRouter(transport: transport)
        await router.setHourlyBudget(10_000) // normal-Ceiling: 9_000
        let hugeInput = String(repeating: "x", count: 60_000) // ~15k Tokens
        do {
            _ = try await router.send(model: "gemini-2.5-flash", system: hugeInput, user: "u", maxTokens: 100)
            XCTFail("Expected budgetExhausted")
        } catch let error as AIRouterError {
            guard case .budgetExhausted = error else {
                return XCTFail("Expected budgetExhausted, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0, "Budget muss vor dem Netzaufruf greifen")
    }

    // MARK: - Routing-Governance

    func testOfflineOverridesTaskModelOverride() async {
        // taskModels-Override darf die Offline-Garantie nicht durchbrechen.
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "gemini-2.5-pro"]
        )
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.setEnergyMode(.offline)
        let model = await router.resolvedModelName(for: .factCheck)
        XCTAssertEqual(model, "local:gemma3", "Offline muss den Cloud-Override verdraengen")
        await router.setEnergyMode(.fullPower)
        await router.setAirplaneMode(true)
        let airplaneModel = await router.resolvedModelName(for: .factCheck)
        XCTAssertEqual(airplaneModel, "local:gemma3", "airplaneMode muss den Cloud-Override verdraengen")
    }

    func testMaxCloudRespectsLocalOnlyPolicy() async {
        // localOnly ist eine Datenschutz-Zusage — auch unter maxCloud.
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskRoutingPolicies: [.factCheck: .localOnly]
        )
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.setEnergyMode(.maxCloud)
        let model = await router.resolvedModelName(for: .factCheck)
        XCTAssertEqual(model, "local:gemma3", "localOnly darf unter maxCloud nicht in die Cloud")
    }

    // MARK: - Budget-Reservierung (Epoche & USD)

    func testBudgetEpochProtectsNewWindowReservations() async throws {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.overrideBudgetWindowForTesting(seconds: 0.05)
        let old = try await router.reserveBudget(task: .factCheck, estimatedTokens: 5_000)
        try await Task.sleep(for: .milliseconds(120))
        // Fenster abgelaufen: naechste Reservierung erzwingt Reset + neue Epoche.
        let fresh = try await router.reserveBudget(task: .factCheck, estimatedTokens: 7_000)
        XCTAssertNotEqual(old.epoch, fresh.epoch)
        // Settle der alten Reservierung darf die neue nicht anfassen.
        await router.settleBudget(old, actualTokens: 100)
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensReserved, 7_000, "Stale-Settle darf neue Reservierungen nicht reduzieren")
        XCTAssertEqual(status.tokensUsed, 100)
        await router.releaseReservation(fresh)
        let cleared = await router.budgetStatus()
        XCTAssertEqual(cleared.tokensReserved, 0)
    }

    func testCostBudgetCountsInFlightReservations() async throws {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.setHourlyCostBudget(usd: 0.05)
        // Erste Reservierung passt unters Ceiling …
        _ = try await router.reserveBudget(task: .factCheck, estimatedTokens: 100, estimatedCostUSD: 0.04)
        // … die zweite muss an settled + in-flight scheitern (0.04 + 0.04 > 0.05).
        do {
            _ = try await router.reserveBudget(task: .factCheck, estimatedTokens: 100, estimatedCostUSD: 0.04)
            XCTFail("Expected budgetExhausted")
        } catch let error as AIRouterError {
            guard case .budgetExhausted = error else {
                return XCTFail("Expected budgetExhausted, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Lokale Pfade & Fallbacks

    func testPreferLocalFallsBackToCloudOnLocalError() async throws {
        // Lokal (Ollama) scheitert -> automatischer Cloud-Fallback.
        let transport = MockTransport(responses: [
            .init(status: 500, body: Data()),
            .init(status: 200, body: googleBody(text: "cloud"))
        ])
        let router2 = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskRoutingPolicies: [.factCheck: .preferLocal],
            accessTokenProvider: { token() },
            transport: transport
        )
        await router2.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        let result = try await router2.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "cloud")
        XCTAssertEqual(transport.requestCount, 2, "Erst lokal (Fehler), dann Cloud")
    }

    func testInProcessLocalProviderServesRequests() async throws {
        let transport = MockTransport(responses: [])
        let router2 = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskRoutingPolicies: [.factCheck: .localOnly],
            accessTokenProvider: { token() },
            transport: transport
        )
        await router2.configureLocalProvider(MockLocalProvider())
        let result = try await router2.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "in-process")
        XCTAssertEqual(transport.requestCount, 0, "In-Process-Provider braucht kein Netz")
    }

    func testOllamaStreamingParsesNDJSON() async throws {
        let lines = [
            "{\"message\":{\"content\":\"Ha\"}}",
            "{\"message\":{\"content\":\"llo\"}}",
            "{\"prompt_eval_count\":3,\"eval_count\":2,\"done\":true}"
        ]
        let transport = MockTransport(responses: [], streamLines: lines)
        let router2 = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskRoutingPolicies: [.factCheck: .localOnly],
            accessTokenProvider: { token() },
            transport: transport
        )
        await router2.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        var chunks: [String] = []
        for try await chunk in await router2.sendStreaming(task: .factCheck, system: "s", user: "u") {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.joined(), "Hallo")
        let status = await router2.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 0, "Lokales Streaming zahlt nicht aufs Cloud-Budget ein")
    }

    func testStreamingConsumerCanAbort() async throws {
        let lines = [
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"eins\"}]}}]}",
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"zwei\"}]}}]}"
        ]
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "ok"))], streamLines: lines)
        let router = makeRouter(transport: transport)
        var received = 0
        for try await _ in await router.sendStreaming(task: .factCheck, system: "s", user: "u") {
            received += 1
            break // Konsument bricht ab
        }
        XCTAssertEqual(received, 1)
        // Router bleibt nach Abbruch voll funktionsfaehig.
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "ok")
    }

    func testStreamingHTTPErrorReleasesReservation() async {
        let transport = MockTransport(responses: [], streamLines: [], streamStatus: 503)
        let router = makeRouter(transport: transport)
        do {
            for try await _ in await router.sendStreaming(task: .factCheck, system: "s", user: "u") {}
            XCTFail("Expected apiError")
        } catch let error as AIRouterError {
            guard case .apiError(503, _) = error else {
                return XCTFail("Expected apiError(503), got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensReserved, 0, "Reservierung muss nach Stream-Fehler frei sein")
    }

    // MARK: - Budget-Prioritaeten & Retry

    func testCriticalPriorityBypassesBudgetCeilings() async throws {
        // dossierSynthesis ist critical: passiert trotz gesprengtem Ceiling.
        let transport = MockTransport(responses: [.init(status: 200, body: anthropicBody(text: "wichtig"))])
        let router = makeRouter(transport: transport)
        await router.setHourlyBudget(10_000)
        let result = try await router.send(task: .dossierSynthesis, system: "s", user: "u", maxTokens: 20_000)
        XCTAssertEqual(result, "wichtig")
        XCTAssertEqual(transport.requestCount, 1)
    }

    func testTransientRetrySucceedsAfter503() async throws {
        let transport = MockTransport(responses: [
            .init(status: 503, body: Data()),
            .init(status: 200, body: googleBody(text: "erholt"))
        ])
        let router = makeRouter(transport: transport, retryPolicy: RetryPolicy(maxTransientRetries: 1, baseDelay: 0))
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "erholt")
        XCTAssertEqual(transport.requestCount, 2)
    }

    // MARK: - EnergyMode x Policy Matrix

    func testEnergyModePolicyMatrix() async {
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskRoutingPolicies: [.factCheck: .localOnly, .meetingSummary: .preferLocal]
        )
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")

        await router.setEnergyMode(.powerSave)
        var model = await router.resolvedModelName(for: .factCheck)
        XCTAssertEqual(model, "local:gemma3", "powerSave + localOnly -> lokal")
        model = await router.resolvedModelName(for: .meetingSummary)
        XCTAssertEqual(model, "gemini-2.5-flash", "powerSave + preferLocal -> Cloud-Default")

        await router.setEnergyMode(.fullPower)
        model = await router.resolvedModelName(for: .meetingSummary)
        XCTAssertEqual(model, "local:gemma3", "fullPower + preferLocal + Backend -> lokal")
        model = await router.resolvedModelName(for: .dossierSynthesis)
        XCTAssertEqual(model, "claude-opus-4-6", "fullPower + cloudOnly -> Cloud")

        // Ohne lokales Backend faellt preferLocal auf den Cloud-Default zurueck.
        let bare = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await bare.setEnergyMode(.fullPower)
        model = await bare.resolvedModelName(for: .emailRelevance) // preferLocal
        XCTAssertEqual(model, "gemini-2.5-flash")
    }

    func testRaisingConcurrencyLimitWakesWaiters() async throws {
        let transport = GatedTransport(body: googleBody(text: "ok"))
        let router = makeRouter(transport: transport)
        await router.setMaxConcurrentCloudCalls(1)
        let first = Task { try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100) }
        let second = Task { try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.startedCount, 1, "Limit 1: zweiter Call wartet")
        await router.setMaxConcurrentCloudCalls(2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.startedCount, 2, "Limit-Erhoehung muss Wartende sofort wecken")
        transport.open()
        _ = try await first.value
        _ = try await second.value
    }

    func testEventCallbackReportsThrottleAndLocalFallback() async throws {
        let ollamaBody = try JSONSerialization.data(withJSONObject: [
            "message": ["content": "lokal"], "prompt_eval_count": 1, "eval_count": 1
        ])
        let transport = MockTransport(responses: [.init(status: 200, body: ollamaBody)])
        let router = makeRouter(transport: transport)
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.setHourlyBudget(10_000)
        let events = EventBox()
        await router.setEventCallback { events.store($0) }

        let hugeInput = String(repeating: "x", count: 60_000) // sprengt das Budget
        let result = try await router.send(task: .factCheck, system: hugeInput, user: "u", maxTokens: 100)
        XCTAssertEqual(result, "lokal")
        XCTAssertEqual(events.all.first, .budgetThrottled(label: "factCheck"))
        XCTAssertTrue(events.all.contains(.localFallback(task: "factCheck")))
    }

    func testStreamingFallsBackToLocalWhenBudgetExhausted() async throws {
        let lines = [
            "{\"message\":{\"content\":\"lokal\"}}",
            "{\"done\":true,\"prompt_eval_count\":1,\"eval_count\":1}"
        ]
        let transport = MockTransport(responses: [], streamLines: lines)
        let router = makeRouter(transport: transport)
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.setHourlyBudget(10_000)
        let hugeInput = String(repeating: "x", count: 60_000) // sprengt das Budget
        var chunks: [String] = []
        for try await chunk in await router.sendStreaming(task: .factCheck, system: hugeInput, user: "u") {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.joined(), "lokal")
        XCTAssertEqual(transport.requestCount, 1, "Nur der lokale Stream-Request darf rausgehen")
    }

    func testResponseCacheEvictsOldestBeyondMaxEntries() async throws {
        let transport = MockTransport(responses: [
            .init(status: 200, body: googleBody(text: "a")),
            .init(status: 200, body: googleBody(text: "b")),
            .init(status: 200, body: googleBody(text: "a2"))
        ])
        let router = makeRouter(transport: transport)
        await router.enableResponseCache(tasks: [.factCheck], ttlSeconds: 60, maxEntries: 1)
        _ = try await router.send(task: .factCheck, system: "eins", user: "u", maxTokens: 100)
        _ = try await router.send(task: .factCheck, system: "zwei", user: "u", maxTokens: 100) // verdraengt "eins"
        let reloaded = try await router.send(task: .factCheck, system: "eins", user: "u", maxTokens: 100)
        XCTAssertEqual(reloaded, "a2", "Verdraengter Eintrag muss neu geladen werden")
        XCTAssertEqual(transport.requestCount, 3)
        let health = await router.healthStatus()
        XCTAssertEqual(health.responseCacheEntries, 1, "maxEntries begrenzt den Cache")
    }

    // MARK: - Auth-Kanten

    func testRepeated401FailsAfterSingleRefresh() async {
        // Genau ein Token-Refresh; ein zweites 401 ist ein echter Fehler.
        let transport = MockTransport(responses: [
            .init(status: 401, body: Data()),
            .init(status: 401, body: Data())
        ])
        let router = makeRouter(transport: transport)
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected apiError(401)")
        } catch let error as AIRouterError {
            guard case .apiError(401, _) = error else {
                return XCTFail("Expected apiError(401), got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testEmptyTokenFailsAuthBeforeNetwork() async {
        let transport = MockTransport(responses: [])
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { AccessToken(value: "", lifetime: 3600) },
            transport: transport
        )
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
            XCTFail("Expected authFailed")
        } catch let error as AIRouterError {
            guard case .authFailed = error else {
                return XCTFail("Expected authFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testOllamaServiceCachesWithinTTL() async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "models": [["name": "gemma3:latest", "size": 1_000, "details": ["parameter_size": "4B"]]]
        ])
        // Nur EINE Antwort im Mock: der zweite Abruf muss aus dem Cache kommen.
        let transport = MockTransport(responses: [.init(status: 200, body: body)])
        let service = OllamaService(transport: transport)
        let first = await service.fetchModels(endpoint: "http://localhost:11434")
        let second = await service.fetchModels(endpoint: "http://localhost:11434")
        XCTAssertEqual(first.map(\.name), second.map(\.name))
        XCTAssertEqual(transport.requestCount, 1, "Innerhalb der TTL kein zweiter Request")
    }

    func testOllamaServiceReturnsEmptyOnInvalidEndpointOrError() async {
        let transport = MockTransport(responses: [.init(status: 500, body: Data())])
        let service = OllamaService(transport: transport)
        let invalid = await service.fetchModels(endpoint: "ftp://nope")
        XCTAssertTrue(invalid.isEmpty)
        XCTAssertEqual(transport.requestCount, 0, "Ungueltiger Endpoint darf kein Netz beruehren")
        let errored = await service.fetchModels(endpoint: "http://localhost:11434")
        XCTAssertTrue(errored.isEmpty, "HTTP-Fehler liefert leere Liste statt zu werfen")
        XCTAssertEqual(transport.requestCount, 1)
    }

    // MARK: - Provider-Streaming (SSE der Direkt-Provider)

    func testOpenAIProviderStreamsSSE() async throws {
        let lines = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hal\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}",
            "data: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}",
            "data: [DONE]"
        ]
        let transport = MockTransport(responses: [], streamLines: lines)
        let provider = OpenAICompatibleProvider(
            baseURL: "https://api.example.com/v1",
            apiKeyProvider: { "k" },
            transport: transport
        )
        var text = ""
        var usage: (input: Int, output: Int)?
        let events = try await provider.stream(model: "gpt-4o", system: "s", messages: [.user("u")], maxTokens: 32, options: .default)
        for try await event in events {
            switch event {
            case .text(let chunk): text += chunk
            case .usage(let input, let output): usage = (input, output)
            }
        }
        XCTAssertEqual(text, "Hallo")
        XCTAssertEqual(usage?.input, 5)
        XCTAssertEqual(usage?.output, 2)
    }

    func testAnthropicDirectProviderStreamsSSE() async throws {
        let lines = [
            "data: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":7}}}",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hi\"}}",
            "data: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":3}}"
        ]
        let transport = MockTransport(responses: [], streamLines: lines)
        let provider = AnthropicDirectProvider(apiKeyProvider: { "k" }, transport: transport)
        var text = ""
        var usage: (input: Int, output: Int)?
        let events = try await provider.stream(model: "claude-sonnet-4-6", system: "s", messages: [.user("u")], maxTokens: 32, options: .default)
        for try await event in events {
            switch event {
            case .text(let chunk): text += chunk
            case .usage(let input, let output): usage = (input, output)
            }
        }
        XCTAssertEqual(text, "Hi")
        XCTAssertEqual(usage?.input, 7)
        XCTAssertEqual(usage?.output, 3)
    }
}

// MARK: - Test-Provider & -Storage

/// Minimaler In-Process-Provider fuer Router-Tests.
struct MockLocalProvider: LocalInferenceProvider {
    var isReady: Bool {
        get async { true }
    }

    func generate(system: String, user: String, maxTokens: Int) async throws -> (text: String, inputTokens: Int, outputTokens: Int) {
        (text: "in-process", inputTokens: 2, outputTokens: 3)
    }

    func generateStream(system: String, user: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("in-")
            continuation.yield("process")
            continuation.finish()
        }
    }
}

/// Minimaler CloudInferenceProvider fuer Router-Tests.
struct MockCloudProvider: CloudInferenceProvider {
    let id: String
    let text: String

    func generate(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> CloudResponse {
        CloudResponse(text: text, inputTokens: 3, outputTokens: 4)
    }

    func stream(model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) async throws -> AsyncThrowingStream<CloudStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(text))
            continuation.yield(.usage(input: 3, output: 4))
            continuation.finish()
        }
    }
}

/// In-Memory-Storage fuer Persistenz-Tests.
final class MemoryStorage: RouterStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PersistedBudgetState?

    init(initial: PersistedBudgetState?) {
        state = initial
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func loadBudgetState() async -> PersistedBudgetState? {
        withLock { state }
    }

    func saveBudgetState(_ newState: PersistedBudgetState) async {
        withLock { state = newState }
    }

    var current: PersistedBudgetState? {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

/// Thread-sicherer Sammler fuer Router-Events.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RouterEvent] = []

    func store(_ event: RouterEvent) {
        lock.lock(); events.append(event); lock.unlock()
    }

    var all: [RouterEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Transport, dessen Antworten hinter einem Tor warten — deterministische
/// Ueberlappung fuer Konkurrenz-Tests.
final class GatedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var gateOpen = false
    private var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let body: Data

    init(body: Data) {
        self.body = body
    }

    var startedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    func open() {
        lock.lock()
        gateOpen = true
        let resumable = waiters
        waiters = []
        lock.unlock()
        resumable.forEach { $0.resume() }
    }

    private func markStarted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        started += 1
        return gateOpen
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isOpen = markStarted()
        if !isOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if gateOpen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, http)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (AsyncThrowingStream { $0.finish() }, http)
    }
}

// MARK: - Helpers

/// Thread-sicherer Container fuer das Usage-Callback.
final class UsageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var info: AIUsageInfo?
    func store(_ value: AIUsageInfo) { lock.lock(); info = value; lock.unlock() }
    var value: AIUsageInfo? { lock.lock(); defer { lock.unlock() }; return info }
}

/// Thread-sicherer Zaehler fuer den Token-Provider.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

// MARK: - Offline-Garantie bei lokalem Fehler
//
// Der Flugmodus ist eine Zusage, keine Praeferenz: auch wenn das lokale Modell
// scheitert (etwa weil Ollama nicht laeuft), darf unter `preferLocal` kein
// Prompt ins Netz gehen.

/// Lokaler Anbieter, der bereit meldet und dann scheitert — die Form, die den
/// Fallback ausloest.
private struct FailingLocalProvider: LocalInferenceProvider {
    struct Boom: Error {}
    var isReady: Bool { get async { true } }

    func generate(system: String, user: String, maxTokens: Int) async throws
        -> (text: String, inputTokens: Int, outputTokens: Int) {
        throw Boom()
    }

    func generateStream(system: String, user: String, maxTokens: Int)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: Boom()) }
    }
}

final class OfflineGuaranteeTests: XCTestCase {

    private func makeRouter() async -> AIRouter {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.configureLocalProvider(FailingLocalProvider())
        return router
    }

    /// Im Flugmodus muss der Fehler beim Aufrufer ankommen — nicht eine
    /// Antwort, die aus der Cloud stammt.
    func testLocalFailureInAirplaneModeDoesNotReachTheCloud() async {
        let router = await makeRouter()
        await router.setEnergyMode(.offline)

        do {
            _ = try await router.send(task: .factCheck, system: "s",
                                      messages: [.user("streng vertraulich")], maxTokens: 32)
            XCTFail("Der Prompt haette die Maschine verlassen")
        } catch is FailingLocalProvider.Boom {
            // Erwartet: der lokale Fehler wird durchgereicht.
        } catch {
            // Kein Cloud-Fehler erwartet — ein Netzwerk-/Auth-Fehler waere der
            // Beweis, dass doch gerufen wurde.
            XCTFail("unerwarteter Fehler (Cloud-Pfad?): \(error)")
        }
    }

    /// Ohne Flugmodus muss der Cloud-Fallback greifen — sonst waere
    /// `preferLocal` bei lokalem Ausfall nutzlos.
    func testLocalFailureOutsideAirplaneModeFallsBackToCloud() async {
        let router = await makeRouter()
        await router.setEnergyMode(.fullPower)

        do {
            _ = try await router.send(task: .factCheck, system: "s",
                                      messages: [.user("hallo")], maxTokens: 32)
            XCTFail("ohne echte Cloud-Zugangsdaten kann das nicht gelingen")
        } catch is FailingLocalProvider.Boom {
            XCTFail("ausserhalb des Flugmodus muss der Cloud-Fallback greifen")
        } catch {
            // Erwartet: der Versuch ging in die Cloud und scheiterte dort.
        }
    }
}

extension OfflineGuaranteeTests {

    /// `localOnly` ist eine Datenschutz-Zusage, kein Wunsch. Ein
    /// taskModels-Override darf sie so wenig aushebeln wie den Flugmodus.
    func testLocalOnlyPolicyBeatsTaskModelOverride() async {
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "gemini-2.5-pro"],
            taskRoutingPolicies: [.factCheck: .localOnly]
        )
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")

        for mode in [EnergyMode.fullPower, .powerSave, .maxCloud] {
            await router.setEnergyMode(mode)
            let model = await router.resolvedModelName(for: .factCheck)
            XCTAssertEqual(model, "local:gemma3",
                           "localOnly muss den Override verdraengen (\(mode.displayName))")
        }
    }

    /// Ohne localOnly bleibt der Override wirksam — sonst waere die Option tot.
    func testTaskModelOverrideStillAppliesWithoutLocalOnly() async {
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "gemini-2.5-pro"]
        )
        await router.configureLocalLLM(endpoint: "http://localhost:11434", model: "gemma3")
        await router.setEnergyMode(.fullPower)
        let model = await router.resolvedModelName(for: .factCheck)
        XCTAssertEqual(model, "gemini-2.5-pro")
    }
}
