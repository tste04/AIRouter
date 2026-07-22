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

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        let response = responses.isEmpty ? Response(status: 500, body: Data()) : responses.removeFirst()
        lock.unlock()
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        return (response.body, http)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        lock.lock()
        requests.append(request)
        let lines = streamLines
        lock.unlock()
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

final class AIRouterTests: XCTestCase {

    // MARK: - Static metadata

    func testTaskDefaultsAreConsistent() {
        for task in AITask.allCases {
            XCTAssertFalse(task.defaultModel.isEmpty, "\(task) hat kein Default-Modell")
            XCTAssertGreaterThan(task.defaultMaxTokens, 0, "\(task) hat kein Token-Budget")
            XCTAssertFalse(task.displayName.isEmpty)
        }
    }

    func testRoutingPolicyDefined() {
        for task in AITask.allCases {
            _ = task.routingPolicy
            _ = task.priority
        }
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "claude-opus-4-6"],
            accessTokenProvider: { token() },
            transport: transport
        )
        let result = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(transport.requestCount, 2)
    }

    func testUnknownModelThrows() async {
        let transport = MockTransport(responses: [])
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "totally-unknown-model"],
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
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testUsageCallbackEmitted() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "x", input: 3, output: 4))])
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
        let box = UsageBox()
        await router.setUsageCallback { info in box.store(info) }
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        try await Task.sleep(for: .milliseconds(50)) // allow callback dispatch
        let captured = box.value
        XCTAssertEqual(captured?.inputTokens, 3)
        XCTAssertEqual(captured?.outputTokens, 4)
    }

    func testBudgetExhaustedThrowsBeforeNetwork() async {
        let transport = MockTransport(responses: [])
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
        await router.setHourlyBudget(10_000) // low-prio ceiling = 7.5k
        // factCheck is .low priority; maxTokens 2000 -> estimate 8000 > 7500 ceiling.
        do {
            _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 2_000)
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "evil/../../model"],
            accessTokenProvider: { token() },
            transport: transport,
            additionalModels: ["evil/../../model": ModelDescriptor(provider: .google)]
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
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testInvalidLocalEndpointIsDiscarded() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.configureLocalLLM(endpoint: "file:///etc/passwd", model: "gemma3")
        let ready = await router.isLocalModelReady()
        XCTAssertFalse(ready, "Ungueltiger Endpoint darf lokale Inferenz nicht aktivieren")
        let stored = await router.localLLMEndpointValue()
        XCTAssertTrue(stored.isEmpty)
    }

    func testLocalEndpointNormalized() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.configureLocalLLM(endpoint: "http://localhost:11434/", model: "gemma3")
        let stored = await router.localLLMEndpointValue()
        XCTAssertEqual(stored, "http://localhost:11434")
    }

    func testRawModelSendCountsTowardBudget() async throws {
        let transport = MockTransport(responses: [.init(status: 200, body: googleBody(text: "raw", input: 5, output: 9))])
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
        let result = try await router.send(model: "gemini-2.5-flash", system: "s", user: "u", maxTokens: 100)
        XCTAssertEqual(result, "raw")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokensUsed, 14, "Roher Modell-Pfad muss auf das Budget einzahlen")
    }

    func testApiErrorBodyIsCapped() async {
        let bigBody = String(repeating: "x", count: 5_000)
        let transport = MockTransport(responses: [.init(status: 400, body: Data(bigBody.utf8))])
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "claude-sonnet-4-6"],
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            taskModels: [.factCheck: "claude-sonnet-4-6"],
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport,
            retryPolicy: RetryPolicy(maxTransientRetries: 0, baseDelay: 0)
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
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
        let router = AIRouter(
            vertexRegion: "us-central1",
            vertexProject: "demo",
            accessTokenProvider: { token() },
            transport: transport
        )
        let box = UsageBox()
        await router.setUsageCallback { info in box.store(info) }
        _ = try await router.send(task: .factCheck, system: "s", user: "u", maxTokens: 100)
        try await Task.sleep(for: .milliseconds(50))

        // gemini-2.5-flash: 0.30/MTok in, 2.50/MTok out -> 0.03 + 0.025 = 0.055 USD
        let cost = box.value?.costUSD
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost ?? 0, 0.055, accuracy: 0.0001)
        let status = await router.budgetStatus()
        XCTAssertEqual(status.costUSD, 0.055, accuracy: 0.0001)
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
