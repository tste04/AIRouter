import Foundation

extension AIRouter {
    // MARK: - Budget internals

    /// Eine aktive Budget-Reservierung: Tokens plus geschaetzte Kosten, gebunden
    /// an die Fenster-Epoche, in der sie angelegt wurde. Settle/Release aus einem
    /// bereits zurueckgesetzten Fenster duerfen die Zaehler des neuen Fensters
    /// nicht beruehren — sonst werden Reservierungen anderer Aufrufe unterschlagen
    /// und das Budget ueberbucht.
    struct BudgetReservation {
        let tokens: Int
        let costUSD: Double
        let epoch: UInt64
    }

    /// Reserviert Token- UND Kosten-Budget (USD, aus Katalog-Preisen geschaetzt).
    /// `critical` umgeht die Ceilings, reserviert aber trotzdem, damit andere
    /// Aufrufer die Auslastung sehen.
    func reserveBudget(task: AITask, estimatedTokens: Int, estimatedCostUSD: Double = 0) throws -> BudgetReservation {
        resetHourIfNeeded()
        let reservation = BudgetReservation(tokens: estimatedTokens, costUSD: estimatedCostUSD, epoch: budgetEpoch)
        if task.priority == .critical {
            reservedTokens += estimatedTokens
            reservedCostUSD += estimatedCostUSD
            return reservation
        }
        // Kosten-Grenze (USD): settled + in-flight-reserviert + neu gegen das Ceiling —
        // sonst passieren N parallele Aufrufe die Pruefung, bevor der erste abrechnet.
        if let costCeiling = hourlyCostBudgetUSD {
            let projectedCost = costThisHourUSD + reservedCostUSD + estimatedCostUSD
            guard projectedCost <= costCeiling else {
                throttledTasks += 1
                DebugLog.write("[AIRouter] Kosten-Budget erreicht (\(projectedCost) > \(costCeiling) USD): \(task.rawValue) aufgeschoben")
                throw AIRouterError.budgetExhausted(task: task.rawValue)
            }
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
        reservedCostUSD += estimatedCostUSD
        return reservation
    }

    func settleBudget(_ reservation: BudgetReservation, actualTokens: Int) {
        if reservation.epoch == budgetEpoch {
            reservedTokens = max(0, reservedTokens - reservation.tokens)
            reservedCostUSD = max(0, reservedCostUSD - reservation.costUSD)
        }
        tokensUsedThisHour += actualTokens
        persistBudget()
    }

    func releaseReservation(_ reservation: BudgetReservation) {
        guard reservation.epoch == budgetEpoch else { return }
        reservedTokens = max(0, reservedTokens - reservation.tokens)
        reservedCostUSD = max(0, reservedCostUSD - reservation.costUSD)
    }

    func resetHourIfNeeded() {
        if budgetClock.now - hourStartInstant >= budgetWindow {
            tokensUsedThisHour = 0
            reservedTokens = 0
            reservedCostUSD = 0
            budgetEpoch += 1
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
