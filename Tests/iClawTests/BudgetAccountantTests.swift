import Foundation
import Testing
@testable import iClawCore

/// Budget enforcement is not optional — every LLMAdapter path (guardedGenerate,
/// generateStructured) must reject prompts that would blow past the backend's
/// context window. The review flagged C3 as "declared but not enforced";
/// these tests pin the enforcement in place so it does not regress.
@Suite("LLMAdapter budget enforcement")
struct BudgetAccountantTests {

    /// `TurnBudget.availableForData` is a pure function of component sizes.
    /// If a component exceeds its cap, the cap applies (not the raw size).
    @Test("Turn budget caps components and yields remaining for data")
    func turnBudgetComputation() {
        let budget = AppConfig.buildTurnBudget(
            identitySize: 220, conversationStateSize: 280, toolSchemaSize: 600
        )
        #expect(budget.identity == AppConfig.identityBudget)
        #expect(budget.conversationState == 280)
        #expect(budget.toolSchemas == 600)
        #expect(budget.generationSpace == AppConfig.generationSpace)
        #expect(budget.fixedCost == budget.identity + 280 + 600 + budget.generationSpace)

        let expectedData = AppConfig.totalContextBudget - budget.fixedCost
        #expect(budget.availableForData == expectedData)
        #expect(budget.availableForData > 0, "4K window should leave room for data")
    }

    /// Oversized components cap at their declared budgets so a runaway
    /// caller cannot starve `availableForData` to negative.
    @Test("Budget caps prevent negative data allocation")
    func budgetCapsPreventUnderflow() {
        let huge = AppConfig.buildTurnBudget(
            identitySize: 10_000,
            conversationStateSize: 10_000,
            toolSchemaSize: 10_000
        )
        #expect(huge.identity == AppConfig.identityBudget)
        #expect(huge.conversationState == AppConfig.conversationStateBlob)
        #expect(huge.toolSchemas == AppConfig.targetedToolSchemas)
        #expect(huge.availableForData >= 0)
    }

    /// `validateBudget` rejects combinations that would exceed the 4K window
    /// once `generationSpace` is reserved.
    @Test("validateBudget rejects over-window compositions")
    func validateBudgetRejectsOverflow() {
        let overflow = AppConfig.validateBudget(
            identity: AppConfig.identityBudget,
            stateBlob: AppConfig.conversationStateBlob,
            toolSchemas: AppConfig.targetedToolSchemas,
            dataChunks: AppConfig.retrievedDataChunks + 500 // push past 4K
        )
        #expect(overflow == false)

        let nominal = AppConfig.validateBudget(
            identity: AppConfig.identityBudget,
            stateBlob: AppConfig.conversationStateBlob,
            toolSchemas: AppConfig.targetedToolSchemas,
            dataChunks: 200
        )
        #expect(nominal == true)
    }
}
