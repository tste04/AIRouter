import Foundation

extension AIRouter {
    // MARK: - Cloud orchestration with budget

    func runCloud(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, estimate: Int) async throws -> String {
        try reserveBudget(task: task, estimatedTokens: estimate)
        do {
            try await acquireCloudSlot()
        } catch {
            releaseReservation(estimate)
            throw error
        }
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

    func streamCloud(task: AITask, model: String, system: String, messages: [AIMessage], maxTokens: Int, options: GenerationOptions, continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let estimate = estimatedRequestTokens(system: system, messages: messages, maxTokens: maxTokens)
        try reserveBudget(task: task, estimatedTokens: estimate)
        do {
            try await acquireCloudSlot()
        } catch {
            releaseReservation(estimate)
            throw error
        }
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
        if !slotWaiters.isEmpty {
            // Slot direkt an den naechsten Wartenden uebergeben (Zaehler bleibt).
            slotWaiters.removeFirst().continuation.resume(returning: ())
        } else {
            activeCloudCalls = max(0, activeCloudCalls - 1)
        }
    }
}
