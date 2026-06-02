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
