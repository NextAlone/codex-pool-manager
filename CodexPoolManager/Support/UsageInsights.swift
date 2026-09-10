import Foundation

// Shared keys keep the dashboard and the window-independent runtime on one history store.
enum UsageInsightsSettings {
    static let historyKey = "pool_dashboard.usage_analytics_state"
    static let workDaysKey = "pool_dashboard.forecast.work_days"
    static let resetReminderKey = "pool_dashboard.reset_expiry_reminder"
    static let serviceStatusKey = "pool_dashboard.official_service_status"
    static let deliveredKey = "pool_dashboard.reset_expiry_delivered"

    static func enabled(_ key: String, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}

struct ResetExpiryReminder: Equatable {
    let key: String
    let expiry: Date
    let body: String

    static func pending(accounts: [AgentAccount], now: Date) -> [Self] {
        accounts.filter { !$0.isRelayAPIKeyAccount && !$0.isUsageSyncExcluded && $0.usageSyncError?.isEmpty != false }
            .flatMap { account -> [Self] in
                guard (account.rateLimitResetCreditsAvailableCount ?? 0) > 0 else { return [] }
                let dates = account.rateLimitResetCreditEstimatedExpiries.filter {
                    $0 > now && $0.timeIntervalSince(now) <= 86_400
                }
                return Set(dates).sorted().map { expiry in
                    let count = dates.filter { $0 == expiry }.count
                    let estimate = account.rateLimitResetCreditExpirySource == .api ? "" : L10n.text("insights.approximate")
                    return Self(key: "\(account.id.uuidString):\(Int(expiry.timeIntervalSince1970))", expiry: expiry,
                        body: L10n.text("insights.reset_body", account.name, count, estimate,
                            expiry.formatted(.dateTime.month().day().hour().minute())))
                }
            }
    }
}

struct HistoricalUsageForecast {
    let pace: CodexBarUsagePace
    let cycleCount: Int

    // Compare equivalent positions in previous weekly cycles. Require observations
    // near both the current phase and cycle end; sparse histories are not evidence.
    static func make(records: [UsageAnalyticsRecord], accountKey: String, usedPercent: Double,
                     resetsAt: Date, now: Date) -> Self? {
        let week: TimeInterval = 604_800
        let remaining = resetsAt.timeIntervalSince(now)
        guard usedPercent.isFinite, (0...100).contains(usedPercent), remaining > 0, remaining < week * 0.97 else { return nil }
        let grouped = Dictionary(grouping: records.filter {
            $0.accountKey == accountKey && $0.weeklyResetAt != nil && $0.timestamp < now
                && $0.timestamp > now.addingTimeInterval(-90 * 86_400)
        }, by: { $0.weeklyResetAt! })
        var phases: [Double] = []
        var futures: [Double] = []
        for (reset, samples) in grouped where reset <= now {
            let valid = samples.filter { $0.timestamp < reset && $0.timestamp >= reset.addingTimeInterval(-week) }
            let chronological = valid.sorted { $0.timestamp < $1.timestamp }
            guard valid.allSatisfy({ (0...100).contains($0.weeklyAbsolutePercent) }),
                  zip(chronological, chronological.dropFirst()).allSatisfy({ $0.weeklyAbsolutePercent <= $1.weeklyAbsolutePercent }) else { continue }
            let phase = reset.addingTimeInterval(-remaining)
            guard let near = valid.min(by: { abs($0.timestamp.timeIntervalSince(phase)) < abs($1.timestamp.timeIntervalSince(phase)) }),
                  abs(near.timestamp.timeIntervalSince(phase)) <= 10_800,
                  let end = valid.max(by: { $0.timestamp < $1.timestamp }),
                  reset.timeIntervalSince(end.timestamp) <= 21_600,
                  end.timestamp > near.timestamp,
                  end.weeklyAbsolutePercent >= near.weeklyAbsolutePercent else { continue }
            phases.append(Double(near.weeklyAbsolutePercent))
            futures.append(Double(end.weeklyAbsolutePercent - near.weeklyAbsolutePercent))
        }
        guard phases.count >= 2 else { return nil }
        let expected = median(phases)
        let future = median(futures)
        let capacity = max(0, 100 - usedPercent)
        let lasts = future <= capacity
        return Self(pace: .historical(expectedUsedPercent: expected, actualUsedPercent: usedPercent,
            etaSeconds: !lasts && future > 0 ? remaining * capacity / future : nil,
            willLastToReset: lasts, runOutProbability: nil, projectedRemainingUsage: future), cycleCount: phases.count)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

struct OfficialServiceStatus: Equatable {
    let message: String
    let hasIncident: Bool
    let checkedAt: Date

    static let pageURL = URL(string: "https://status.openai.com")!
    static let endpoint = URL(string: "https://status.openai.com/api/v2/summary.json")!

    private struct Payload: Decodable {
        struct Status: Decodable { let indicator: String; let description: String }
        struct Incident: Decodable { let name: String; let status: String }
        let status: Status
        let incidents: [Incident]
    }

    static func decode(_ data: Data, now: Date) throws -> Self {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard ["none", "minor", "major", "critical", "maintenance"].contains(payload.status.indicator),
              !payload.status.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        let incidents = payload.incidents.filter { !["resolved", "postmortem"].contains($0.status) }
        return Self(message: incidents.isEmpty ? payload.status.description : incidents.map(\.name).joined(separator: " · "),
                    hasIncident: payload.status.indicator != "none" || !incidents.isEmpty, checkedAt: now)
    }

    static func fetch(now: Date) async throws -> Self {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try decode(data, now: now)
    }
}
