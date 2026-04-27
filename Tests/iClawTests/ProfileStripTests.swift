import Foundation
import Testing
@testable import iClawCore

@Suite("Profile stripping for conversational turns")
struct ProfileStripTests {

    @Test("Tool-advertising lines are removed")
    func stripsToolAdvertising() {
        let raw = "User: Tom Barrasso. Email: t@example.com. Frequently used: Automate, Calculator, Calendar. Common topics: AAPL, AI"
        let stripped = ExecutionEngine.stripProfileForConversation(raw)
        #expect(!stripped.contains("Frequently used"))
        #expect(!stripped.contains("Common topics"))
        #expect(stripped.contains("User: Tom Barrasso"))
        #expect(stripped.contains("Email: t@example.com"))
    }

    @Test("Empty input returns empty")
    func emptyStays() {
        #expect(ExecutionEngine.stripProfileForConversation("") == "")
    }

    @Test("Profile with no tool lines is unchanged")
    func noToolLines() {
        let raw = "User: Sam. Email: s@example.com"
        let stripped = ExecutionEngine.stripProfileForConversation(raw)
        #expect(stripped.contains("User: Sam"))
        #expect(stripped.contains("Email: s@example.com"))
    }
}
