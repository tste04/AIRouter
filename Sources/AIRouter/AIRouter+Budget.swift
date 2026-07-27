import Foundation

extension AIRouter {
    // MARK: - Budget internals

    func reserveBudget(task: AITask, estimatedTokens: Int) throws {
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

    func settleBudget(reserved estimatedTokens: Int, actual: Int) {
        reservedTokens = max(0, reservedTokens - estimatedTokens)
        tokensUsedThisHour += actual
        persistBudget()
    }

    func releaseReservation(_ estimatedTokens: Int) {
        reservedTokens = max(0, reservedTokens - estimatedTokens)
    }

    func resetHourIfNeeded() {
        if budgetClock.now - hourStartInstant >= budgetWindow {
            tokensUsedThisHour = 0
            reservedTokens = 0
            currentHourStart = Date()
            hourStartInstant = budgetClock.now
            costThisHourUSD = 0
            throttledTasks = 0
            persistBudget()
        }
    }

    /// Sekunden bis zum Fenster-Reset (monotone Uhr; 0, wenn faellig).
    func rawSecondsUntilReset() -> Double {
        let elapsed = budgetClock.now - hourStartInstant
        let remaining = budgetWindow - elapsed
        return max(0, Double(remaining.components.seconds))
    }

    /// Wartezeit fuer die Budget-Warteschlange (min. 1 s, +1 s Puffer).
    func secondsUntilBudgetReset() -> Double {
        max(1, rawSecondsUntilReset() + 1)
    }

    /// Speichert den Budget-Zustand fire-and-forget in den konfigurierten Storage.
    func persistBudget() {
        guard let storage else { return }
        let state = PersistedBudgetState(
            tokensUsed: tokensUsedThisHour,
            costUSD: costThisHourUSD,
            throttled: throttledTasks,
            hourStarted: currentHourStart
        )
        Task { await storage.saveBudgetState(state) }
    }
}
