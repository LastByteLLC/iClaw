import Foundation
import os
import Testing
@testable import iClawCore

@Suite("Consent gate")
@MainActor
struct ConsentGateTests {

    // MARK: - Test helper: a spy that records whether execute() ever ran.

    final class ConsentSpyTool: CoreTool, @unchecked Sendable {
        let name: String
        let schema: String
        let isInternal: Bool = false
        let category: CategoryEnum = .offline
        let consentPolicy: ActionConsentPolicy

        private let _executeCount = OSAllocatedUnfairLock(initialState: 0)
        var executeCount: Int { _executeCount.withLock { $0 } }

        init(name: String, policy: ActionConsentPolicy) {
            self.name = name
            self.schema = "{\"type\":\"object\"}"
            self.consentPolicy = policy
        }

        func execute(input: String, entities: ExtractedEntities?) async throws -> ToolIO {
            _executeCount.withLock { $0 += 1 }
            return ToolIO(text: "spy ran", status: .ok)
        }
    }

    // MARK: - Policy metadata audit

    @Test("Every core tool that requires consent supplies a description")
    func everyConsentRequiringCoreToolDeclaresDescription() {
        for tool in ToolRegistry.coreTools where tool.consentPolicy.needsConsent {
            let desc = tool.consentPolicy.actionDescription ?? ""
            #expect(!desc.isEmpty,
                    "\(tool.name) declares consent-required policy but has an empty description")
        }
    }

    @Test("Every FM tool that requires consent supplies a description")
    func everyConsentRequiringFMToolDeclaresDescription() {
        for tool in ToolRegistry.fmTools where tool.consentPolicy.needsConsent {
            let desc = tool.consentPolicy.actionDescription ?? ""
            #expect(!desc.isEmpty,
                    "\(tool.name) declares consent-required policy but has an empty description")
        }
    }

    // MARK: - ConsentManager resolution

    @Test("Safe actions approve without consulting the policy chain")
    func safeAlwaysApproves() async {
        let prev = ConsentManager.shared.testModePolicy
        ConsentManager.shared.testModePolicy = .alwaysDeny
        defer { ConsentManager.shared.testModePolicy = prev }

        let result = await ConsentManager.shared.requestConsent(
            policy: .safe, toolName: "audit"
        )
        #expect(result == .approved)
    }

    @Test("Test-mode alwaysDeny blocks destructive and requiresConsent")
    func testModeDenyBlocksNonSafe() async {
        let prev = ConsentManager.shared.testModePolicy
        ConsentManager.shared.testModePolicy = .alwaysDeny
        defer { ConsentManager.shared.testModePolicy = prev }

        let destructive = await ConsentManager.shared.requestConsent(
            policy: .destructive(description: "wipe"), toolName: "audit"
        )
        let requiresConsent = await ConsentManager.shared.requestConsent(
            policy: .requiresConsent(description: "send"), toolName: "audit"
        )
        #expect(destructive == .denied)
        #expect(requiresConsent == .denied)
    }

    @Test("autoApproveActions never bypasses destructive in headless mode")
    func destructiveRespectsHeadlessSafetyNet() async {
        let prevTestMode = ConsentManager.shared.testModePolicy
        let prevAutoApprove = ConsentManager.shared.autoApproveActions
        let prevHeadless = ToolRegistry.headlessMode

        ConsentManager.shared.testModePolicy = nil
        ConsentManager.shared.autoApproveActions = true
        ToolRegistry.headlessMode = true
        defer {
            ConsentManager.shared.testModePolicy = prevTestMode
            ConsentManager.shared.autoApproveActions = prevAutoApprove
            ToolRegistry.headlessMode = prevHeadless
        }

        // autoApproveActions is skipped for .destructive (step 3 in ConsentManager),
        // then headlessMode triggers the safety-net denial (step 4).
        let result = await ConsentManager.shared.requestConsent(
            policy: .destructive(description: "wipe"), toolName: "audit"
        )
        #expect(result == .denied)
    }

    @Test("Test-mode byTool routes decisions per tool name")
    func testModeByToolRoutes() async {
        let prev = ConsentManager.shared.testModePolicy
        ConsentManager.shared.testModePolicy = .byTool([
            "allow_me": .approved,
            "deny_me": .denied
        ])
        defer { ConsentManager.shared.testModePolicy = prev }

        let approved = await ConsentManager.shared.requestConsent(
            policy: .requiresConsent(description: "send"), toolName: "allow_me"
        )
        let denied = await ConsentManager.shared.requestConsent(
            policy: .requiresConsent(description: "send"), toolName: "deny_me"
        )
        #expect(approved == .approved)
        #expect(denied == .denied)
    }
}
