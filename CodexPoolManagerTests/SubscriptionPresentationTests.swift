import Foundation
import Testing
@testable import CodexPoolManager

struct SubscriptionPresentationTests {
    private func token(_ auth: [String: Any], expiration: Int = 1_900_000_000) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": auth, "exp": expiration])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    @Test func parsesSubscriptionClaimWithoutUsingTokenExpiration() throws {
        let jwt = try token(["chatgpt_account_id": "acct", "chatgpt_subscription_active_until": "2026-08-31T20:30:07+00:00",
                             "chatgpt_subscription_last_checked": "2026-08-28T14:57:43.877694+00:00"])
        let record = try #require(OAuthIDTokenClaimsParser.subscriptionRecord(idToken: jwt, expectedAccountID: "acct"))
        #expect(record.activeUntil == ISO8601DateFormatter().date(from: "2026-08-31T20:30:07Z"))
        #expect(record.lastCheckedAt != nil)
        #expect(OAuthIDTokenClaimsParser.subscriptionRecord(idToken: jwt, expectedAccountID: "other") == nil)
        #expect(OAuthIDTokenClaimsParser.subscriptionRecord(idToken: try token([:]), expectedAccountID: nil) == nil)
    }

    @Test func acceptsSecondsAndMillisecondsAndRejectsInvalidValues() throws {
        for value in [1_800_000_000, 1_800_000_000_000, "1800000000"] as [Any] {
            let jwt = try token(["chatgpt_subscription_active_until": value])
            #expect(OAuthIDTokenClaimsParser.subscriptionRecord(idToken: jwt, expectedAccountID: nil)?.activeUntil
                == Date(timeIntervalSince1970: 1_800_000_000))
        }
        for value in [NSNull(), true, -1, "invalid", "nan", ["date": "2026-08-31"]] as [Any] {
            let jwt = try token(["chatgpt_subscription_active_until": value])
            #expect(OAuthIDTokenClaimsParser.subscriptionRecord(idToken: jwt, expectedAccountID: nil) == nil)
        }
        #expect(OAuthIDTokenClaimsParser.subscriptionRecord(idToken: "broken", expectedAccountID: nil) == nil)
    }

    @Test func expiredRecordIsMarkedStaleAndTokenReplacementUpdatesPresentation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var account = AgentAccount(id: UUID(), name: "test", usedUnits: 0, quota: 100,
            oauthIDToken: try token(["chatgpt_subscription_active_until": 1_700_000_000]), isPaid: true)
        let old = try #require(SubscriptionPresentationFormatter.presentation(for: account, now: now))
        #expect(old.needsUpdate)
        account.oauthIDToken = try token(["chatgpt_subscription_active_until": 1_900_000_000])
        let fresh = try #require(SubscriptionPresentationFormatter.presentation(for: account, now: now))
        #expect(!fresh.needsUpdate)
        #expect(fresh.text != old.text)
        account.isPaid = false
        #expect(SubscriptionPresentationFormatter.presentation(for: account, now: now) == nil)
        account.isPaid = true
        account.credentialType = .relayAPIKey
        #expect(SubscriptionPresentationFormatter.presentation(for: account, now: now) == nil)
    }
}
