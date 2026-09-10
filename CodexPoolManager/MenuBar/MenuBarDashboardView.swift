import SwiftUI
import Charts

struct MenuBarDashboardView: View {
    @ObservedObject var runtimeModel: AppPoolRuntimeModel
    @State private var isWarningPopoverPresented = false
    @State private var contentHeight: CGFloat = 0
    let openDashboard: () -> Void
    let switchAccount: (UUID) -> Void

    private var snapshot: MenuBarDashboardSnapshot { runtimeModel.menuBarSnapshot }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    if runtimeModel.showsOfficialStatus {
                        Link(destination: OfficialServiceStatus.pageURL) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(L10n.text("insights.status_title"), systemImage: runtimeModel.officialStatus?.hasIncident == true
                                    ? "exclamationmark.triangle.fill" : "network")
                                Text(runtimeModel.officialStatusError ?? runtimeModel.officialStatus?.message
                                    ?? L10n.text("insights.status_loading"))
                                    .lineLimit(3)
                                if let status = runtimeModel.officialStatus {
                                    Text(L10n.text("insights.checked_at", status.checkedAt.formatted(date: .omitted, time: .shortened)))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(runtimeModel.officialStatusError != nil || runtimeModel.officialStatus?.hasIncident == true
                                ? Color.orange : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if let error = runtimeModel.insightError {
                        Text(error).font(.caption).foregroundStyle(.orange).padding(12)
                    }
                    if snapshot.accountRows.isEmpty {
                        Text(L10n.text("menu_bar.empty.message"))
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                    ForEach(Array(snapshot.accountRows.enumerated()), id: \.element.id) { index, row in
                        AccountRowView(row: row, number: index + 1, updatedText: snapshot.updatedText,
                            isSwitching: runtimeModel.switchingAccountID != nil,
                            history: runtimeModel.usageHistory.filter { record in
                                runtimeModel.state.accounts.first(where: { $0.id == row.id })?.usageAnalyticsAccountKey == record.accountKey
                            }, switchAccount: switchAccount)
                        Divider().padding(.horizontal, CodexBarMenuStyle.horizontalPadding)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            if let message = runtimeModel.lastSwitchMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(3).padding(10)
            }
            HStack {
                Button {
                    Task { @MainActor in await runtimeModel.syncNowWithTimeout() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.text("menu_bar.action.sync_now"))
                .accessibilityLabel(L10n.text("menu_bar.action.sync_now"))
                .disabled(snapshot.isSyncing)
                if snapshot.isSyncing || runtimeModel.switchingAccountID != nil {
                    ProgressView().controlSize(.small)
                }
                warningPopoverButton
                Spacer()
                Button(L10n.text("menu_bar.action.open_dashboard"), action: openDashboard)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(12)
        }
        .frame(width: CodexBarMenuStyle.width)
        .frame(height: min(620, max(160, contentHeight + 48 + (runtimeModel.lastSwitchMessage == nil ? 0 : 60))))
        .background(CodexBarMenuMaterial())
        .task { runtimeModel.bootstrapIfNeeded() }
    }

    @ViewBuilder
    private var warningPopoverButton: some View {
        if !snapshot.warningRows.isEmpty {
            Button { isWarningPopoverPresented.toggle() } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .help(L10n.text("menu_bar.section.warnings"))
            .accessibilityLabel(L10n.text("menu_bar.section.warnings"))
            .popover(isPresented: $isWarningPopoverPresented) {
                WarningsPopoverView(rows: snapshot.warningRows)
            }
        }
    }
}

// Header, metric, reset-credit layout and typography adapted from CodexBar's MenuCardView.
// Copyright (c) 2026 Peter Steinberger. MIT; see ThirdPartyNotices/CodexBar.txt.
private struct AccountRowView: View {
    @State private var isAccountWarningPopoverPresented = false
    @State private var isResetCreditNotePopoverPresented = false
    @State private var isSubscriptionPopoverPresented = false
    @State private var isHistoryPresented = false
    let row: MenuBarAccountRow
    var number: Int = 1
    var updatedText: String = ""
    var isSwitching = false
    var history: [UsageAnalyticsRecord] = []
    let switchAccount: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: CodexBarMenuStyle.headerContentSpacing) {
                header
                Divider()
            }
            .padding(.horizontal, CodexBarMenuStyle.horizontalPadding)
            .padding(.vertical, CodexBarMenuStyle.headerVerticalPadding)

            VStack(alignment: .leading, spacing: CodexBarMenuStyle.sectionSpacing) {
                ForEach(row.usageWindows) { window in
                    CodexBarMetricRow(window: window)
                }
                if row.usageWindows.isEmpty {
                    Text("—").font(.footnote).foregroundStyle(CodexBarMenuStyle.secondary)
                }
                if !row.usageWindows.isEmpty {
                    Button(L10n.text("insights.history_title")) { isHistoryPresented = true }
                        .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                        .popover(isPresented: $isHistoryPresented) { UsageHistoryPopover(records: history) }
                }
                if let count = row.resetCreditCount, count > 0 {
                    Divider()
                    resetCredits(count: count)
                }
            }
            .padding(.horizontal, CodexBarMenuStyle.horizontalPadding)
            .padding(.top, CodexBarMenuStyle.usageTopPadding)
            .padding(.bottom, CodexBarMenuStyle.sectionBottomPadding)
        }
        .foregroundStyle(CodexBarMenuStyle.primary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CodexBarMenuStyle.headerLineSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: CodexBarMenuStyle.headerColumnSpacing) {
                Text("#\(number)")
                    .font(.headline).fontWeight(.semibold)
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(row.name).font(.subheadline)
                        .foregroundStyle(CodexBarMenuStyle.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(row.name)
                    if row.isActive {
                        Text(L10n.text("account.current_badge"))
                            .font(.caption)
                            .foregroundStyle(CodexBarMenuStyle.secondary)
                            .fixedSize()
                            .accessibilityLabel(L10n.text("menu_bar.section.active"))
                    } else {
                        Button(L10n.text("menu_bar.action.switch")) { switchAccount(row.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .fixedSize()
                            .disabled(isSwitching)
                            .accessibilityLabel(L10n.text("menu_bar.action.switch") + " " + row.name)
                    }
                }

            }
            HStack(alignment: .firstTextBaseline, spacing: CodexBarMenuStyle.headerColumnSpacing) {
                if let warning = row.warningText, !warning.isEmpty {
                    Button { isAccountWarningPopoverPresented = true } label: {
                        Text(warning).font(.footnote).foregroundStyle(Color(nsColor: .systemRed))
                            .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isAccountWarningPopoverPresented) {
                        Text(warning).padding(12).frame(width: 280)
                    }
                } else {
                    Text(updatedText).font(.footnote)
                        .foregroundStyle(CodexBarMenuStyle.secondary).lineLimit(1).layoutPriority(1)
                }
                Spacer(minLength: 0)
                plan
            }
        }
    }

    @ViewBuilder
    private var plan: some View {
        if let planText = row.planBadgeText {
            if let subscription = row.subscription {
                Button { isSubscriptionPopoverPresented = true } label: {
                    HStack(spacing: 3) {
                        Text(planText + " · " + subscription.compactDateText)
                        if subscription.needsUpdate { Image(systemName: "clock.badge.exclamationmark") }
                    }
                    .font(.footnote).lineLimit(1)
                    .foregroundStyle(CodexBarMenuStyle.secondary)
                }
                .buttonStyle(.plain)
                .help(subscription.text + "\n" + subscription.detail)
                .accessibilityLabel(planText + ". " + subscription.text)
                .popover(isPresented: $isSubscriptionPopoverPresented) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(subscription.text).font(.headline)
                        Text(subscription.detail).font(.callout)
                    }
                    .padding(12).frame(width: 280)
                }
            } else {
                Text(planText).font(.footnote).foregroundStyle(CodexBarMenuStyle.secondary).lineLimit(1)
            }
        }
    }

    private func resetCredits(count: Int) -> some View {
        Button { isResetCreditNotePopoverPresented = true } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("codexbar.reset_credits"))
                    .font(.body).fontWeight(.medium).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.text("menu_bar.reset_credit.count_format", count))
                        .font(.footnote.weight(.semibold)).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 8)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "clock").font(.caption2)
                        Text(row.resetCreditCountdown ?? "—").font(.caption)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(CodexBarMenuStyle.secondary)
                    .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(row.resetCreditDetailText ?? "")
        .accessibilityLabel(row.resetCreditAccessibilityLabel ?? "")
        .popover(isPresented: $isResetCreditNotePopoverPresented) {
            Text([row.resetCreditDetailText, row.resetCreditNoteText].compactMap { $0 }.joined(separator: "\n"))
                .font(.callout).padding(12).frame(width: 280)
        }
    }
}

private struct CodexBarMetricRow: View {
    let window: MenuBarUsageWindow

    private var title: String {
        "\(window.title) \(window.remainingPercent)% \(L10n.text("codexbar.left"))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reset = window.resetText {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleLabel.fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 8)
                        resetLabel(reset).fixedSize(horizontal: true, vertical: false)
                    }
                    VStack(alignment: .trailing, spacing: 2) {
                        titleLabel.frame(maxWidth: .infinity, alignment: .leading)
                        resetLabel(reset)
                    }
                }
            } else {
                titleLabel
            }
            CodexBarUsageProgressBar(percent: Double(window.remainingPercent),
                pacePercent: window.pace?.expectedRemainingPercent,
                paceOnTop: window.pace?.isInReserve ?? true)
            if let pace = window.pace {
                Text(pace.text)
                    .font(.footnote).foregroundStyle(CodexBarMenuStyle.secondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .help(pace.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleLabel: some View {
        Text(title).font(.body).fontWeight(.medium).lineLimit(1)
    }

    private func resetLabel(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(CodexBarMenuStyle.secondary)
            .lineLimit(2).multilineTextAlignment(.trailing)
    }
}

private struct WarningRowView: View {
    let row: MenuBarWarningRow

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(row.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var tint: Color {
        switch row.kind {
        case .oauthExpired, .syncFailed:
            return .orange
        case .relayUsageUnavailable:
            return .blue
        case .excluded:
            return .secondary
        }
    }

    private var systemImage: String {
        switch row.kind {
        case .oauthExpired:
            return "person.crop.circle.badge.exclamationmark"
        case .relayUsageUnavailable:
            return "key.horizontal"
        case .syncFailed:
            return "exclamationmark.triangle"
        case .excluded:
            return "minus.circle"
        }
    }
}

private struct WarningsPopoverView: View {
    let rows: [MenuBarWarningRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("menu_bar.section.warnings"))
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        WarningRowView(row: row)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .frame(maxHeight: 360, alignment: .topLeading)
    }
}

#if DEBUG
extension MenuBarDashboardView {
    @MainActor
    static func debugAccountRowView(
        row: MenuBarAccountRow,
        updatedText: String = "",
        switchAccount: @escaping (UUID) -> Void = { _ in }
    ) -> some View {
        AccountRowView(row: row, updatedText: updatedText, switchAccount: switchAccount)
    }

    @MainActor
    static func debugUsageHistoryView(records: [UsageAnalyticsRecord], now: Date) -> some View {
        UsageHistoryPopover(records: records, now: now)
    }

    @MainActor
    static func debugWarningsPopoverView(rows: [MenuBarWarningRow]) -> some View {
        WarningsPopoverView(rows: rows)
    }

    @MainActor
    static func debugWarningPopoverButtonView(runtimeModel: AppPoolRuntimeModel) -> some View {
        MenuBarDashboardView(
            runtimeModel: runtimeModel,
            openDashboard: {},
            switchAccount: { _ in }
        )
        .warningPopoverButton
    }
}
#endif

private struct UsageHistoryPopover: View {
    let records: [UsageAnalyticsRecord]
    var now = Date()
    private var days: [(date: Date, usage: Int)] {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now)) ?? now
        let groups = Dictionary(grouping: records.filter { $0.timestamp >= start && $0.timestamp <= now }, by: { calendar.startOfDay(for: $0.timestamp) })
        return groups.map { (date: $0.key, usage: $0.value.reduce(0) { $0 + $1.weeklyDeltaPercent }) }
            .sorted { $0.date < $1.date }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("insights.history_title")).font(.headline)
            if days.isEmpty { Text(L10n.text("insights.history_empty")).foregroundStyle(.secondary) }
            else {
                Chart(days, id: \.date) { day in
                    BarMark(x: .value("Date", day.date, unit: .day), y: .value("%", day.usage))
                }.frame(height: 150)
            }
            Text(L10n.text("insights.history_hint")).font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 320)
    }
}
