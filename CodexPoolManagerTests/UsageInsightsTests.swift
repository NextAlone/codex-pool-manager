import Foundation
import Testing
@testable import CodexPoolManager

@Suite(.serialized)
@MainActor
struct UsageInsightsTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func account(expiry: Date, source: RateLimitResetCreditExpirySource = .api) -> AgentAccount {
        AgentAccount(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Test",
            usedUnits: 20, quota: 100, usageWindowName: "weekly", usageWindowResetAt: now.addingTimeInterval(200_000),
            rateLimitResetCreditsAvailableCount: 2, rateLimitResetCreditEstimatedExpiries: [expiry, expiry],
            rateLimitResetCreditExpirySource: source)
    }

    @Test func expiryWindowGroupingAndSource() {
        let expiry = now.addingTimeInterval(3600)
        let api = ResetExpiryReminder.pending(accounts: [account(expiry: expiry)], now: now)
        #expect(api.count == 1)
        #expect(api.first?.body.contains("2") == true)
        let estimated = ResetExpiryReminder.pending(accounts: [account(expiry: expiry, source: .estimated)], now: now)
        #expect(estimated.first?.body != api.first?.body)
        #expect(ResetExpiryReminder.pending(accounts: [account(expiry: now)], now: now).isEmpty)
        #expect(ResetExpiryReminder.pending(accounts: [account(expiry: now.addingTimeInterval(86_401))], now: now).isEmpty)
        var excluded = account(expiry: expiry)
        excluded.isUsageSyncExcluded = true
        #expect(ResetExpiryReminder.pending(accounts: [excluded], now: now).isEmpty)
    }

    private func records() -> [UsageAnalyticsRecord] {
        [1.0, 2.0].flatMap { cycle -> [UsageAnalyticsRecord] in
            let reset = now.addingTimeInterval(-cycle * 604_800)
            return [UsageAnalyticsRecord(timestamp: reset.addingTimeInterval(-200_000), accountKey: "a",
                weeklyDeltaPercent: 30, fiveHourDeltaPercent: 0, weeklyAbsolutePercent: 30, weeklyResetAt: reset),
                UsageAnalyticsRecord(timestamp: reset.addingTimeInterval(-3600), accountKey: "a",
                weeklyDeltaPercent: 50, fiveHourDeltaPercent: 0, weeklyAbsolutePercent: 80, weeklyResetAt: reset)]
        }
    }

    @Test func historicalForecastUsesAccountAndPhaseCoverage() {
        let reset = now.addingTimeInterval(200_000)
        let result = HistoricalUsageForecast.make(records: records(), accountKey: "a", usedPercent: 60, resetsAt: reset, now: now)
        #expect(result?.cycleCount == 2)
        #expect(result?.pace.expectedUsedPercent == 30)
        #expect(result?.pace.willLastToReset == false)
        #expect(result?.pace.etaSeconds == 160_000)
        #expect(HistoricalUsageForecast.make(records: records(), accountKey: "b", usedPercent: 60, resetsAt: reset, now: now) == nil)
        #expect(HistoricalUsageForecast.make(records: Array(records().prefix(2)), accountKey: "a", usedPercent: 60, resetsAt: reset, now: now) == nil)
        #expect(HistoricalUsageForecast.make(records: records(), accountKey: "a", usedPercent: 60,
            resetsAt: now.addingTimeInterval(300_000), now: now) == nil)
    }

    @Test func statusRejectsMalformedAndIncludesIncidents() throws {
        let incident = Data(#"{"status":{"indicator":"none","description":"Operational"},"incidents":[{"name":"Incident A","status":"monitoring"}]}"#.utf8)
        let status = try OfficialServiceStatus.decode(incident, now: now)
        #expect(status.hasIncident)
        #expect(status.message == "Incident A")
        #expect(throws: (any Error).self) {
            try OfficialServiceStatus.decode(Data(#"{"status":{"indicator":"unknown","description":"OK"},"incidents":[]}"#.utf8), now: now)
        }
        #expect(throws: (any Error).self) { try OfficialServiceStatus.decode(Data("{}".utf8), now: now) }
    }

    @Test func persistedReminderDedupAndStatusFailure() async throws {
        let suite = "UsageInsightsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var state = AccountPoolState(accounts: [account(expiry: now.addingTimeInterval(3600))])
        state.markUsageSynced(at: now)
        func model() -> AppPoolRuntimeModel {
            AppPoolRuntimeModel(store: AppPoolRuntimeModelTests.SpyStore(), initialState: state,
                widgetPublisher: { _ in }, defaults: defaults)
        }
        let first = model()
        var deliveries = 0
        var fetches = 0
        first.reminderSender = { _ in deliveries += 1; return true }
        first.statusFetcher = { date in
            fetches += 1
            if fetches > 1 { throw URLError(.notConnectedToInternet) }
            return OfficialServiceStatus(message: "Operational", hasIncident: false, checkedAt: date)
        }
        await first.refreshInsights(now: now)
        await first.refreshInsights(now: now.addingTimeInterval(10))
        #expect(deliveries == 1)
        #expect(fetches == 1)
        await first.refreshInsights(now: now.addingTimeInterval(301))
        #expect(first.officialStatusError != nil)
        #expect(first.officialStatus?.checkedAt == now)
        let restarted = model()
        restarted.reminderSender = { _ in deliveries += 1; return true }
        defaults.set(false, forKey: UsageInsightsSettings.serviceStatusKey)
        await restarted.refreshInsights(now: now.addingTimeInterval(302))
        #expect(deliveries == 1)
        defaults.set(false, forKey: UsageInsightsSettings.resetReminderKey)
        defaults.removeObject(forKey: UsageInsightsSettings.deliveredKey)
        await restarted.refreshInsights(now: now.addingTimeInterval(303))
        #expect(deliveries == 1)
    }

    @Test func deniedReminderIsNotMarkedDeliveredAndStaleSyncDoesNotNotify() async {
        let suite = "UsageInsightsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: UsageInsightsSettings.serviceStatusKey)
        var state = AccountPoolState(accounts: [account(expiry: now.addingTimeInterval(3600))])
        state.markUsageSynced(at: now)
        let model = AppPoolRuntimeModel(store: AppPoolRuntimeModelTests.SpyStore(), initialState: state,
            widgetPublisher: { _ in }, defaults: defaults)
        var attempts = 0
        model.reminderSender = { _ in attempts += 1; return false }
        await model.refreshInsights(now: now)
        #expect(attempts == 1)
        #expect(defaults.dictionary(forKey: UsageInsightsSettings.deliveredKey) == nil)
        #expect(model.insightError != nil)
        state.markUsageSynced(at: now.addingTimeInterval(-7200))
        model.replaceStateFromDashboard(state)
        await model.refreshInsights(now: now)
        #expect(attempts == 1)
    }
    @Test func workdayForecastPausesOverWeekend() throws {
        let calendar = Calendar.current
        let saturday = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 12)))
        let sunday = try #require(calendar.date(byAdding: .day, value: 1, to: saturday))
        let reset = try #require(calendar.date(byAdding: .day, value: 2, to: saturday))
        let account = AgentAccount(id: UUID(), name: "weekdays", usedUnits: 50, quota: 100,
            usageWindowName: "weekly", usageWindowResetAt: reset)
        let sat = MenuBarDashboardPresenter.usageWindows(for: account, now: saturday, workDays: 5).first?.pace
        let sun = MenuBarDashboardPresenter.usageWindows(for: account, now: sunday, workDays: 5).first?.pace
        #expect(sat != nil)
        #expect(sat?.expectedRemainingPercent == sun?.expectedRemainingPercent)
        let everyDay = MenuBarDashboardPresenter.usageWindows(for: account, now: saturday, workDays: 7).first?.pace
        #expect(everyDay?.expectedRemainingPercent != sat?.expectedRemainingPercent)
    }

    @Test func runtimeRecordsWithoutDashboardAndPreservesUnreadableHistory() async throws {
        let suite = "UsageInsightsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: UsageInsightsSettings.serviceStatusKey)
        defaults.set(false, forKey: UsageInsightsSettings.resetReminderKey)
        let base = account(expiry: now.addingTimeInterval(200_000))
        let state = AccountPoolState(accounts: [base])
        var calls = 0
        let model = AppPoolRuntimeModel(store: AppPoolRuntimeModelTests.SpyStore(), initialState: state,
            widgetPublisher: { _ in }, syncRunner: { state, viewState in
                calls += 1
                var nextAccount = base
                nextAccount.usedUnits = calls == 1 ? 20 : 35
                var next = AccountPoolState(accounts: [nextAccount])
                next.markUsageSynced(at: now.addingTimeInterval(Double(calls) * 60))
                return .init(state: next, viewState: viewState)
            }, defaults: defaults)
        _ = await model.syncNow()
        _ = await model.syncNow()
        #expect(model.usageHistory.count == 1)
        #expect(model.usageHistory.first?.weeklyDeltaPercent == 15)
        let raw = try #require(defaults.string(forKey: UsageInsightsSettings.historyKey))
        let stored = try JSONDecoder().decode(UsageAnalyticsState.self, from: Data(raw.utf8))
        #expect(stored.records == model.usageHistory)
        defaults.set("unreadable history", forKey: UsageInsightsSettings.historyKey)
        _ = await model.syncNow()
        #expect(defaults.string(forKey: UsageInsightsSettings.historyKey) == "unreadable history")
        #expect(model.historyError != nil)
    }

}
