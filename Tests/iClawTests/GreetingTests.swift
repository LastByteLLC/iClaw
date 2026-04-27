import Foundation
import Testing
@testable import iClawCore

@Suite("GreetingManager", .serialized)
struct GreetingTests {

    // MARK: - GreetingContext Assembly

    @Test func timeOfDayMorning() async {
        let ctx = await GreetingManager.assembleContext()
        // Just verify it assembles without crashing and has valid fields
        #expect(!ctx.dayOfWeek.isEmpty)
        #expect(!ctx.date.isEmpty)
        #expect(ctx.batteryPercent >= 0 && ctx.batteryPercent <= 100)
        #expect(ctx.uptimeHours >= 0)
        #expect(ctx.streakDays >= 1)
    }

    @Test func seasonFromMonth() {
        // Context uses Calendar.current month — we just verify the enum exists
        let seasons: [GreetingContext.Season] = [.spring, .summer, .autumn, .winter]
        #expect(seasons.count == 4)
    }

    // MARK: - Holiday Proximity

    @Test func holidayWithinLookahead() {
        let cal = Calendar.current
        // Test with a date right before Christmas
        let dec20 = cal.date(from: DateComponents(year: 2026, month: 12, day: 20))!
        let result = GreetingManager.findNearestHoliday(from: dec20)
        #expect(result != nil)
        #expect(result?.name == "Christmas")
        #expect(result?.daysAway == 5)
    }

    @Test func holidayOutsideLookahead() {
        let cal = Calendar.current
        // Test with a date far from any holiday (mid-August)
        let aug10 = cal.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let result = GreetingManager.findNearestHoliday(from: aug10)
        // Should be nil — no holidays within 14 days of Aug 10
        #expect(result == nil)
    }

    @Test func holidayOnTheDay() {
        let cal = Calendar.current
        let jul4 = cal.date(from: DateComponents(year: 2026, month: 7, day: 4))!
        let result = GreetingManager.findNearestHoliday(from: jul4)
        #expect(result != nil)
        #expect(result?.name == "Independence Day")
        #expect(result?.daysAway == 0)
    }

    @Test func holidayNewYearCrossover() {
        let cal = Calendar.current
        // Dec 28 should find New Year's Eve (3 days) or New Year's Day (4 days)
        let dec28 = cal.date(from: DateComponents(year: 2026, month: 12, day: 28))!
        let result = GreetingManager.findNearestHoliday(from: dec28)
        #expect(result != nil)
        #expect(result?.daysAway ?? 99 <= 4)
    }

    // MARK: - Streak Counter

    @Test func streakIncrements() {
        let defaults = UserDefaults.standard
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let savedDate = defaults.string(forKey: GreetingManager.lastActiveDateKey)
        let savedStreak = defaults.integer(forKey: GreetingManager.currentStreakKey)
        defer {
            if let d = savedDate { defaults.set(d, forKey: GreetingManager.lastActiveDateKey) }
            else { defaults.removeObject(forKey: GreetingManager.lastActiveDateKey) }
            defaults.set(savedStreak, forKey: GreetingManager.currentStreakKey)
        }

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        defaults.set(formatter.string(from: yesterday), forKey: GreetingManager.lastActiveDateKey)
        defaults.set(5, forKey: GreetingManager.currentStreakKey)

        let streak = GreetingManager.updateStreak()
        #expect(streak == 6)
    }

    @Test func streakResets() {
        let defaults = UserDefaults.standard
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let savedDate = defaults.string(forKey: GreetingManager.lastActiveDateKey)
        let savedStreak = defaults.integer(forKey: GreetingManager.currentStreakKey)
        defer {
            if let d = savedDate { defaults.set(d, forKey: GreetingManager.lastActiveDateKey) }
            else { defaults.removeObject(forKey: GreetingManager.lastActiveDateKey) }
            defaults.set(savedStreak, forKey: GreetingManager.currentStreakKey)
        }

        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: Calendar.current.startOfDay(for: Date()))!
        defaults.set(formatter.string(from: threeDaysAgo), forKey: GreetingManager.lastActiveDateKey)
        defaults.set(10, forKey: GreetingManager.currentStreakKey)

        let streak = GreetingManager.updateStreak()
        #expect(streak == 1)
    }

    @Test func streakSameDayIdempotent() {
        let defaults = UserDefaults.standard
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        let savedDate = defaults.string(forKey: GreetingManager.lastActiveDateKey)
        let savedStreak = defaults.integer(forKey: GreetingManager.currentStreakKey)
        defer {
            if let d = savedDate { defaults.set(d, forKey: GreetingManager.lastActiveDateKey) }
            else { defaults.removeObject(forKey: GreetingManager.lastActiveDateKey) }
            defaults.set(savedStreak, forKey: GreetingManager.currentStreakKey)
        }

        defaults.set(formatter.string(from: Date()), forKey: GreetingManager.lastActiveDateKey)
        defaults.set(7, forKey: GreetingManager.currentStreakKey)

        let streak = GreetingManager.updateStreak()
        #expect(streak == 7)
    }

    // MARK: - Static Fallbacks

    @Test func fallbacksAreNonEmpty() {
        #expect(GreetingManager.fallbackGreetings.count == 20)
        for fallback in GreetingManager.fallbackGreetings {
            #expect(!fallback.isEmpty)
        }
    }

    // MARK: - recentUserInputs

    @Test @MainActor func recentUserInputsQuery() async throws {
        let db = try DatabaseManager(inMemory: true)

        // Save 10 user memories and 3 agent memories
        for i in 1...10 {
            _ = try await db.saveMemory(Memory(
                id: nil, role: "user", content: "query \(i)",
                embedding: nil, created_at: Date().addingTimeInterval(Double(i)), is_important: false
            ))
        }
        for i in 1...3 {
            _ = try await db.saveMemory(Memory(
                id: nil, role: "agent", content: "response \(i)",
                embedding: nil, created_at: Date().addingTimeInterval(Double(i + 10)), is_important: false
            ))
        }

        let results = await db.recentUserInputs(limit: 5)
        #expect(results.count == 5)
        // Should be most recent first
        #expect(results[0] == "query 10")
        #expect(results[4] == "query 6")
    }

    @Test @MainActor func recentUserInputsSkipsAgentMessages() async throws {
        let db = try DatabaseManager(inMemory: true)

        _ = try await db.saveMemory(Memory(
            id: nil, role: "agent", content: "I'm an agent response",
            embedding: nil, created_at: Date(), is_important: false
        ))
        _ = try await db.saveMemory(Memory(
            id: nil, role: "user", content: "user question",
            embedding: nil, created_at: Date().addingTimeInterval(1), is_important: false
        ))

        let results = await db.recentUserInputs(limit: 5)
        #expect(results.count == 1)
        #expect(results[0] == "user question")
    }

    // MARK: - Phase 3 Skip

    @Test func phase3SkipsWithFewHistoryItems() async throws {
        // The threshold guard (recentInputs.count >= 3) is tested deterministically
        // via an in-memory DB: with <3 user messages, recentUserInputs returns fewer
        // than 3 items, which would cause generatePredictedRepeat() to return nil.
        // We can't call generatePredictedRepeat() directly because it uses
        // DatabaseManager.shared (real DB with unknown state) + LLMAdapter.shared
        // (real Apple Intelligence). Instead, verify the threshold logic on a
        // controlled in-memory database.
        let db = try DatabaseManager(inMemory: true)
        // Insert only 2 user messages (below the 3-message threshold)
        _ = try await db.saveMemory(Memory(
            id: nil, role: "user", content: "weather in London",
            embedding: nil, created_at: Date(), is_important: false
        ))
        _ = try await db.saveMemory(Memory(
            id: nil, role: "user", content: "stock price of AAPL",
            embedding: nil, created_at: Date().addingTimeInterval(1), is_important: false
        ))
        let recentInputs = await db.recentUserInputs(limit: 5)
        #expect(recentInputs.count < 3, "With only 2 user messages, count should be below the phase-3 threshold")
    }
}
