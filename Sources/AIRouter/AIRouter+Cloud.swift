import Foundation

extension AIRouter {
    // MARK: - Cloud orchestration with budget

    /// Geschaetzte Kosten einer Anfrage fuer die USD-Reservierung: Input-Anteil
    /// der Token-Schaetzung zu Input-Preisen, maxTokens zu Output-Preisen.
    func estimatedRequestCostUSD(model: String, estimate: Int, maxTokens: Int) -> Double {
        estimatedCost(model: model, input: max(0, estimate - maxTokens), output: maxTokens) ?? 0
    }

    /// Wirft, wenn die Schaetzung das Kontextfenster des Modells uebersteigt —
    /// frueh und klar scheitern statt spaet am Backend (oder still gekuerzt).
    func checkContextWindow(model: String, estimate: Int) throws {
        guard let window = catalog.descriptor(for: model)?.contextWindow, estimate > window else { return }
        throw AIRouterError.contextWindowExceeded(model: model, estimatedTokens: estimate, window: window)
    }

    func runCloud(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, estimate: Int) async throws -> String {
        try checkContextWindow(model: model, estimate: estimate)
        let reservation = try reserveBudget(
            task: task,
            estimatedTokens: estimate,
            estimatedCostUSD: estimatedRequestCostUSD(model: model, estimate: estimate, maxTokens: maxTokens))
        do {
            try await acquireCloudSlot()
        } catch {
            releaseReservation(reservation)
            throw error
        }
        do {
            let result = try await callVertex(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task)
            releaseCloudSlot()
            settleBudget(reservation, actualTokens: result.inputTokens + result.outputTokens)
            return result.text
        } catch {
            releaseCloudSlot()
            releaseReservation(reservation)
            throw error
        }
    }

    func streamCloud(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let estimate = estimatedRequestTokens(system: system, messages: messages, maxTokens: maxTokens)
        try checkContextWindow(model: model, estimate: estimate)
        let reservation = try reserveBudget(
            task: task,
            estimatedTokens: estimate,
            estimatedCostUSD: estimatedRequestCostUSD(model: model, estimate: estimate, maxTokens: maxTokens))
        do {
            try await acquireCloudSlot()
        } catch {
            releaseReservation(reservation)
            throw error
        }
        do {
            let usage = try await streamVertex(model: model, system: system, messages: messages, maxTokens: maxTokens, options: options, task: task, continuation: continuation)
            releaseCloudSlot()
            settleBudget(reservation, actualTokens: usage.input + usage.output)
        } catch {
            releaseCloudSlot()
            releaseReservation(reservation)
            throw error
        }
    }

    /// Async-Semaphor fuer parallele Cloud-Aufrufe. Cancellation-korrekt:
    /// Ein abgebrochener Task verlaesst die Warteschlange sofort mit
    /// `CancellationError`, statt einen Slot zu blockieren oder zu stehlen.
    func acquireCloudSlot() async throws {
        try Task.checkCancellation()
        if activeCloudCalls < maxConcurrentCloudCalls {
            activeCloudCalls += 1
            return
        }
        let id = nextSlotWaiterID
        nextSlotWaiterID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                slotWaiters.append((id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(id) }
        }
    }

    func cancelSlotWaiter(_ id: UInt64) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = slotWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    func releaseCloudSlot() {
        if activeCloudCalls > maxConcurrentCloudCalls {
            // Limit wurde gesenkt: Kapazitaet abbauen statt Slot weiterzugeben.
            activeCloudCalls -= 1
            return
        }
        if !slotWaiters.isEmpty {
            // Slot direkt an den naechsten Wartenden uebergeben (Zaehler bleibt).
            slotWaiters.removeFirst().continuation.resume(returning: ())
        } else {
            activeCloudCalls = max(0, activeCloudCalls - 1)
        }
    }
}
