import SwiftUI

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
                    if snapshot.accountRows.isEmpty {
                        Text(L10n.text("menu_bar.empty.message"))
                            .foregroundStyle(.secondary)
                            .padding(24)
                    }
                    ForEach(snapshot.accountRows) { row in
                        AccountRowView(row: row, updatedText: snapshot.updatedText,
                            isSwitching: runtimeModel.switchingAccountID != nil,
                            switchAccount: switchAccount)
                        Divider()
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
        .frame(width: 340)
        .frame(height: min(620, max(160, contentHeight + 48 + (runtimeModel.lastSwitchMessage == nil ? 0 : 60))))
        .background(Color(nsColor: .windowBackgroundColor))
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

private struct AccountRowView: View {
    @State private var isAccountWarningPopoverPresented = false
    @State private var isResetCreditNotePopoverPresented = false
    let row: MenuBarAccountRow
    var updatedText: String = ""
    var isSwitching = false
    let switchAccount: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Text(row.credentialLabel ?? "Codex").font(.headline)
                    if row.isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.teal)
                            .accessibilityLabel(L10n.text("menu_bar.section.active"))
                    }
                    Spacer(minLength: 6)
                    Menu {
                        Text(row.name)
                        Button(L10n.text("menu_bar.action.switch")) { switchAccount(row.id) }
                            .disabled(row.isActive || isSwitching)
                    } label: {
                        Text(row.name).lineLimit(1).truncationMode(.middle)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 210, alignment: .trailing)
                    .help(row.name)
                }
                HStack {
                    Text(updatedText)
                    Spacer()
                    Text(row.planBadgeText ?? "")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(row.usageWindows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).fontWeight(.semibold)
                        Text(L10n.text("usage.remaining_percent_format", window.remainingPercent))
                        Spacer(minLength: 2)
                        Text(L10n.text("account.weekly_resets_format", window.resetText))
                            .foregroundStyle(.secondary).font(.caption2)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(Color.secondary.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.teal)
                                    .frame(width: geometry.size.width * CGFloat(window.remainingPercent) / 100)
                            }
                    }
                    .frame(height: 5)
                    .accessibilityLabel("\(window.title) \(window.remainingPercent)%")
                }
                .padding(.bottom, 3)
            }
            if row.usageWindows.isEmpty {
                Text("—").foregroundStyle(.secondary)
            }
            if let count = row.resetCreditCount {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("menu_bar.reset_credit.detail.title")).fontWeight(.semibold)
                    HStack(spacing: 5) {
                        Text(L10n.text("menu_bar.reset_credit.count_format", count))
                        Spacer(minLength: 2)
                        Image(systemName: "clock")
                        Text(row.resetCreditCountdown ?? "—").lineLimit(1).truncationMode(.tail)
                    }
                    .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { isResetCreditNotePopoverPresented = true }
                .help(row.resetCreditDetailText ?? "")
                .accessibilityLabel(row.resetCreditAccessibilityLabel ?? "")
                .popover(isPresented: $isResetCreditNotePopoverPresented) {
                    Text([row.resetCreditDetailText, row.resetCreditNoteText].compactMap { $0 }.joined(separator: "\n"))
                        .font(.callout).padding(12).frame(width: 280)
                }
            }
            if let warningText = row.warningText, !warningText.isEmpty {
                Button { isAccountWarningPopoverPresented = true } label: {
                    Label(warningText, systemImage: "exclamationmark.circle.fill").lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .help(warningText)
                .popover(isPresented: $isAccountWarningPopoverPresented) {
                    Text(warningText).padding(12).frame(width: 280)
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(12)
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
        switchAccount: @escaping (UUID) -> Void = { _ in }
    ) -> some View {
        AccountRowView(row: row, switchAccount: switchAccount)
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
