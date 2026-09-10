// Adapted from CodexBar UsagePaceText and UsageFormatter at b7650829 (MIT).
// Copyright (c) 2026 Peter Steinberger; see ThirdPartyNotices/CodexBar.txt.
import Foundation

struct CodexBarPacePresentation: Equatable {
    let text: String
    let expectedRemainingPercent: Double?
    let isInReserve: Bool

    static func make(usedPercent: Double, resetsAt: Date?, windowMinutes: Int, now: Date,
                     isSession: Bool, workDays: Int? = nil, historical: HistoricalUsageForecast? = nil) -> CodexBarPacePresentation? {
        // CodexBar hides forecasts until 3% of the window has elapsed and once quota is exhausted.
        guard usedPercent.isFinite, usedPercent < 100,
              let linear = CodexBarUsagePace.weekly(window: CodexBarRateWindow(
                usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt), now: now, workDays: workDays),
              linear.expectedUsedPercent >= 3 else { return nil }
        let pace = historical?.pace ?? linear
        let delta = Int(abs(pace.deltaPercent).rounded())
        let left: String
        switch pace.stage {
        case .onTrack:
            left = L10n.text("codexbar.on_pace")
        case .slightlyAhead, .ahead, .farAhead:
            left = L10n.text("codexbar.deficit", delta)
        case .slightlyBehind, .behind, .farBehind:
            left = L10n.text("codexbar.reserve", delta)
        }
        var right: String?
        if pace.willLastToReset {
            let lasts = L10n.text("codexbar.lasts")
            if pace.deltaPercent < -15, let multiplier = pace.speedMultiplierToReset, multiplier >= 1.5 {
                right = lasts + " · " + L10n.text("codexbar.headroom")
            } else {
                right = lasts
            }
        } else if let eta = pace.etaSeconds {
            let duration = CodexBarCountdown.duration(seconds: eta)
            let key = isSession ? "projected_empty" : "runs_out"
            right = duration == "now" ? L10n.text("codexbar." + key + "_now")
                : L10n.text("codexbar." + key, duration)
        }
        let basis: String? = isSession ? nil : historical.map { L10n.text("insights.historical", $0.cycleCount) }
            ?? workDays.map { L10n.text("insights.workdays", $0) }
            ?? L10n.text("insights.insufficient_history")
        return CodexBarPacePresentation(
            text: [left, right, basis].compactMap { $0 }.joined(separator: " · "),
            expectedRemainingPercent: pace.stage == .onTrack ? nil : 100 - pace.expectedUsedPercent,
            isInReserve: pace.actualUsedPercent <= pace.expectedUsedPercent)
    }
}

enum CodexBarCountdown {
    static func duration(seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 1 { return "now" }
        let totalMinutes = max(1, Int(ceil(seconds / 60)))
        let days = totalMinutes / 1440
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60
        if days > 0 {
            if hours > 0 { return "\(days)d \(hours)h" }
            if minutes > 0 { return "\(days)d \(minutes)m" }
            return "\(days)d"
        }
        if hours > 0 {
            if minutes > 0 { return "\(hours)h \(minutes)m" }
            return "\(hours)h"
        }
        return "\(totalMinutes)m"
    }

    static func resetText(date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let text = duration(seconds: date.timeIntervalSince(now))
        return text == "now" ? L10n.text("codexbar.resets_now") : L10n.text("codexbar.resets_in", text)
    }

    static func expiryText(date: Date, now: Date) -> String {
        let text = duration(seconds: date.timeIntervalSince(now))
        return text == "now" ? L10n.text("codexbar.now") : text
    }
}
