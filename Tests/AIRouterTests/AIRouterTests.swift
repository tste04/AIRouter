import XCTest
@testable import AIRouter

final class AIRouterTests: XCTestCase {

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

    func testOfflineModeResolvesLocal() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        await router.setEnergyMode(.offline)
        let model = await router.resolvedModelName(for: .dossierSynthesis)
        XCTAssertTrue(model.hasPrefix("local:"), "Offline sollte lokal aufloesen, war: \(model)")
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
            taskModels: [AITask.factCheck.rawValue: "claude-sonnet-4-6"]
        )
        let model = await router.resolvedModelName(for: .factCheck)
        XCTAssertEqual(model, "claude-sonnet-4-6")
    }

    func testBudgetStatusDefaults() async {
        let router = AIRouter(vertexRegion: "us-central1", vertexProject: "demo")
        let status = await router.budgetStatus()
        XCTAssertEqual(status.tokenBudget, 200_000)
        XCTAssertEqual(status.tokensUsed, 0)
        XCTAssertEqual(status.remaining, 200_000)
    }
}
