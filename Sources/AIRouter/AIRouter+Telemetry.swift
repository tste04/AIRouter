import Foundation

extension AIRouter {
    // MARK: - Auth

    func getAccessToken() async throws -> String {
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

    func invalidateToken() {
        cachedToken = nil
        tokenExpiresAt = nil
    }


    // MARK: - Telemetry helpers

    /// Wendet den Preflight-Hook (z. B. PII-Redaktion) auf ausgehende
    /// Cloud-Inhalte an — eine Stelle fuer alle Cloud-Pfade.
    func preflightedOutbound(system: String, messages: [AIMessage]) -> (system: String, messages: [AIMessage]) {
        guard let hook = cloudPreflight else { return (system, messages) }
        return (hook(system), messages.map { AIMessage(role: $0.role, content: hook($0.content)) })
    }

    func estimatedCost(model: String, input: Int, output: Int) -> Double? {
        guard let descriptor = catalog.descriptor(for: model),
              let inputCost = descriptor.inputCostPerMTok,
              let outputCost = descriptor.outputCostPerMTok else {
            return nil
        }
        return (Double(input) * inputCost + Double(output) * outputCost) / 1_000_000
    }

    func emitUsage(task: AITask?, model: String, input: Int, output: Int, elapsed: Duration, isEstimated: Bool = false) {
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

    /// Exponentieller Backoff mit Jitter (0,8–1,2×) gegen Thundering-Herd
    /// bei gleichzeitig retryenden Aufrufern.
    static func backoffDelay(policy: RetryPolicy, attempt: Int) -> Double {
        policy.baseDelay * pow(2.0, Double(attempt - 1)) * Double.random(in: 0.8...1.2)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000)
    }
}
