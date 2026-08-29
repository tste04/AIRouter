import Foundation

extension AIRouter {
    // MARK: - Circuit breaker internals

    func breakerIsOpen(_ model: String) -> Bool {
        guard let openedAt = breakers[model]?.openedAt else { return false }
        if budgetClock.now - openedAt >= breakerCooldown {
            // Cooldown abgelaufen -> Breaker schliessen, Modell wieder zulassen.
            breakers[model] = nil
            emitEvent(.breakerClosed(model: model))
            return false
        }
        return true
    }

    func recordSuccess(_ model: String) {
        breakers[model] = nil
    }

    func recordFailure(_ model: String) {
        statsFailures[model, default: 0] += 1
        var state = breakers[model] ?? BreakerState()
        state.consecutiveFailures += 1
        if state.consecutiveFailures >= breakerThreshold && state.openedAt == nil {
            state.openedAt = budgetClock.now
            DebugLog.write("[AIRouter] Circuit-Breaker offen fuer \(model) (\(state.consecutiveFailures) Fehler in Folge)")
            emitEvent(.breakerOpened(model: model))
        }
        breakers[model] = state
    }


    // MARK: - Response cache internals

    func responseCacheKey(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions) -> ResponseCacheKey? {
        guard responseCacheMax > 0, cacheableTasks.contains(task) else { return nil }
        return ResponseCacheKey(task: task, model: model, system: system, messages: messages, maxTokens: maxTokens, options: options)
    }

    func cachedResponse(for key: ResponseCacheKey) -> String? {
        guard let entry = responseCache[key] else { return nil }
        guard budgetClock.now - entry.storedAt < responseCacheTTL else {
            removeCacheEntry(key)
            return nil
        }
        return entry.text
    }

    func storeResponse(_ text: String, for key: ResponseCacheKey) {
        guard responseCacheMax > 0 else { return }
        let bytes = text.utf8.count
        // Eine Antwort oberhalb des gesamten Byte-Budgets wird nicht gecacht —
        // sie wuerde nur alle anderen Eintraege verdraengen.
        guard bytes <= responseCacheMaxBytes else { return }
        if let existing = responseCache[key] {
            responseCacheBytes -= existing.text.utf8.count
        } else {
            responseCacheOrder.append(key)
        }
        responseCache[key] = ResponseCacheEntry(text: text, storedAt: budgetClock.now)
        responseCacheBytes += bytes
        // Eviction ueber Eintrags- UND Byte-Deckel: 256 Eintraege zu je 50 MB
        // waeren sonst ein gueltiger Cache-Zustand.
        while responseCacheOrder.count > responseCacheMax || responseCacheBytes > responseCacheMaxBytes,
              let oldest = responseCacheOrder.first {
            removeCacheEntry(oldest)
        }
    }

    func removeCacheEntry(_ key: ResponseCacheKey) {
        if let entry = responseCache.removeValue(forKey: key) {
            responseCacheBytes -= entry.text.utf8.count
        }
        responseCacheOrder.removeAll { $0 == key }
    }
}
