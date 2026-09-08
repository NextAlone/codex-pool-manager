import Foundation

struct SubscriptionPresentation: Equatable {
    let text: String
    let detail: String
    let compactDateText: String
    let needsUpdate: Bool
}

enum SubscriptionPresentationFormatter {
    static func presentation(for account: AgentAccount, now: Date = .now) -> SubscriptionPresentation? {
        guard account.supportsCodexUsageSync, account.isPaid,
              let record = OAuthIDTokenClaimsParser.subscriptionRecord(
                idToken: account.oauthIDToken, expectedAccountID: account.chatGPTAccountID
              ) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let needsUpdate = record.activeUntil <= now
        let text = L10n.text("account.subscription.record_until", formatter.string(from: record.activeUntil))
            + (needsUpdate ? " · " + L10n.text("account.subscription.needs_update") : "")
        var detail = L10n.text("account.subscription.record_help")
        if let checkedAt = record.lastCheckedAt {
            formatter.timeStyle = .short
            detail += "\n" + L10n.text("account.subscription.checked_at", formatter.string(from: checkedAt))
        }
        if needsUpdate { detail += "\n" + L10n.text("account.subscription.stale_help") }
        formatter.timeStyle = .none
        formatter.setLocalizedDateFormatFromTemplate("yyyyMd")
        return SubscriptionPresentation(text: text, detail: detail,
            compactDateText: formatter.string(from: record.activeUntil), needsUpdate: needsUpdate)
    }
}
