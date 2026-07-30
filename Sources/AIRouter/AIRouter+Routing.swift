import Foundation

extension AIRouter {
    // MARK: - Model resolution

    func effectiveMaxTokens(task: AITask, requested: Int?) -> Int {
        let base = requested ?? task.defaultMaxTokens
        return energyMode == .maxCloud ? Int((Double(base) * 1.5 / 100).rounded() * 100) : base
    }

    /// Budget-Schaetzung fuer eine Anfrage: Input (System + Verlauf, ~4 Zeichen
    /// pro Token) plus maximale Output-Tokens.
    func estimatedRequestTokens(system: String, messages: [AIMessage], maxTokens: Int) -> Int {
        let inputChars = system.count + messages.reduce(0) { $0 + $1.content.count }
        return inputChars / 4 + maxTokens
    }

    var localModelTag: String {
        localLLMModel.isEmpty ? "local" : "local:\(localLLMModel)"
    }

    func isLocalTag(_ model: String) -> Bool {
        model == "local" || model.hasPrefix("local:")
    }

    func hasLocalBackend() -> Bool {
        localProvider != nil || !localLLMEndpoint.isEmpty
    }

    func resolveModel(for task: AITask) -> String {
        // Offline-Garantie schlaegt Modell-Overrides: bei airplaneMode/.offline
        // darf KEIN Pfad ins Netz fuehren, auch nicht ueber taskModels.
        if airplaneMode { return localModelTag }
        if let override = taskModels[task] { return override }

        let policy = taskRoutingPolicies[task] ?? task.routingPolicy
        let localAvailable = hasLocalBackend()

        switch energyMode {
        case .maxCloud:
            // localOnly ist eine Datenschutz-Zusage und gilt auch unter maxCloud.
            if policy == .localOnly { return localModelTag }
            return upgradeModel(task.defaultModel)
        case .offline:
            return localModelTag
        case .powerSave:
            switch policy {
            case .localOnly:
                return localModelTag
            case .preferLocal, .preferCloud, .cloudOnly:
                return task.defaultModel
            }
        case .fullPower:
            switch policy {
            case .cloudOnly:
                return task.defaultModel
            case .localOnly:
                return localModelTag
            case .preferLocal:
                return localAvailable ? localModelTag : task.defaultModel
            case .preferCloud:
                return task.defaultModel
            }
        }
    }

    func upgradeModel(_ model: String) -> String {
        catalog.descriptor(for: model)?.upgradesTo ?? model
    }

    func descriptor(for model: String) throws -> ModelDescriptor {
        if isLocalTag(model) { return ModelDescriptor(provider: .local) }
        guard let descriptor = catalog.descriptor(for: model) else {
            throw AIRouterError.notConfigured("Unbekanntes Modell '\(model)'. Registriere es ueber 'additionalModels' im Initializer.")
        }
        return descriptor
    }
}
