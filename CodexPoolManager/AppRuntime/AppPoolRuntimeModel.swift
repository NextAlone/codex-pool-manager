import Combine
import Foundation

enum AppPoolRuntimeSyncOutcomeStatus: Sendable {
    case success
    case failure
    case timeout
    case staleDiscard
}

struct AppPoolRuntimeSyncOutcome: Identifiable {
    let id: UUID
    let status: AppPoolRuntimeSyncOutcomeStatus
    let previousState: AccountPoolState
    let previousSyncError: String?
    let outputViewState: PoolDashboardViewState
    let syncError: String?
    let stateApplied: Bool
    let resultingState: AccountPoolState
}

@MainActor
final class AppPoolRuntimeModel: ObservableObject {
    typealias SyncOutcome = AppPoolRuntimeSyncOutcome

    private enum SyncOrigin {
        case manual
        case autoSync
    }

    typealias SyncRunner = @MainActor (
        _ state: AccountPoolState,
        _ viewState: PoolDashboardViewState
    ) async -> PoolDashboardUsageSyncFlowCoordinator.Output
    typealias WidgetPublisher = @MainActor (_ snapshot: AccountPoolSnapshot) -> Void
    typealias MenuBarNowProvider = @MainActor () -> Date
    struct OfficialSwitchRequest {
        let account: AgentAccount
        let switchWithoutLaunching: Bool
        let launchTarget: CodexLaunchTarget
    }

    enum SwitchResult: Equatable {
        case success(String)
        case failure(String)
    }

    typealias OfficialSwitchRunner = @MainActor (_ request: OfficialSwitchRequest) async -> SwitchResult
    typealias RelaySwitchRunner = @MainActor (
        _ request: PoolDashboardRelayAccountCoordinator.SwitchRequest
    ) async -> SwitchResult

    @Published private(set) var state: AccountPoolState
    @Published private(set) var isSyncingUsage = false
    @Published private(set) var lastSyncError: String?
    @Published private(set) var lastSyncOutcome: SyncOutcome?
    @Published private(set) var switchingAccountID: UUID?
    @Published private(set) var lastSwitchMessage: String?
    @Published private(set) var menuBarNow: Date

    @Published private(set) var usageHistory: [UsageAnalyticsRecord] = []
    @Published private(set) var historyError: String?
    @Published private(set) var reminderError: String?
    var insightError: String? { historyError ?? reminderError }
    @Published private(set) var officialStatus: OfficialServiceStatus?
    @Published private(set) var officialStatusError: String?
    private var lastStatusAttempt: Date?
    private var insightsTask: Task<Void, Never>?
    var statusFetcher: (Date) async throws -> OfficialServiceStatus = { try await OfficialServiceStatus.fetch(now: $0) }
    var reminderSender: (ResetExpiryReminder) async throws -> Bool = { try await DesktopNotifier.deliverExpiryReminder($0) }

    var forecastWorkDays: Int? {
        let value = defaults.integer(forKey: UsageInsightsSettings.workDaysKey)
        return [4, 5, 7].contains(value) ? value : nil
    }

    var showsOfficialStatus: Bool {
        UsageInsightsSettings.enabled(UsageInsightsSettings.serviceStatusKey, defaults: defaults)
    }

    private let store: AccountPoolStoring
    private let syncRunner: SyncRunner
    private let officialSwitchRunner: OfficialSwitchRunner
    private let relaySwitchRunner: RelaySwitchRunner
    private let defaults: UserDefaults
    private let widgetPublisher: WidgetPublisher
    private let syncTimeoutNanoseconds: UInt64
    private let menuBarClockIntervalNanoseconds: UInt64
    private let menuBarNowProvider: MenuBarNowProvider
    private var stateRevision = 0
    private var autoSyncTask: Task<Void, Never>?
    private var menuBarClockTask: Task<Void, Never>?
    private var activeSyncID: UUID?
    private var activeSyncOrigin: SyncOrigin?
    private var didBootstrap = false
    private var didLoadFromStore = false

    var menuBarSnapshot: MenuBarDashboardSnapshot {
        MenuBarDashboardPresenter.makeSnapshot(
            from: state,
            isSyncing: isSyncingUsage,
            lastSyncError: lastSyncError,
            now: menuBarNow,
            workDays: forecastWorkDays, history: usageHistory
        )
    }

    convenience init(
        initialState: AccountPoolState? = nil,
        syncTimeoutNanoseconds: UInt64 = 45_000_000_000,
        menuBarClockIntervalNanoseconds: UInt64 = 15_000_000_000,
        menuBarNowProvider: @escaping MenuBarNowProvider = { Date() },
        widgetPublisher: @escaping WidgetPublisher = { WidgetBridgePublisher.publish(from: $0) },
        syncRunner: @escaping SyncRunner = { state, viewState in
            await PoolDashboardUsageSyncFlowCoordinator()
                .syncCodexUsage(from: state, viewState: viewState)
        },
        officialSwitchRunner: OfficialSwitchRunner? = nil,
        relaySwitchRunner: RelaySwitchRunner? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.init(
            store: AppRuntimeStorage.accountPoolStore,
            initialState: initialState,
            syncTimeoutNanoseconds: syncTimeoutNanoseconds,
            menuBarClockIntervalNanoseconds: menuBarClockIntervalNanoseconds,
            menuBarNowProvider: menuBarNowProvider,
            widgetPublisher: widgetPublisher,
            syncRunner: syncRunner,
            officialSwitchRunner: officialSwitchRunner,
            relaySwitchRunner: relaySwitchRunner,
            defaults: defaults
        )
    }

    init(
        store: AccountPoolStoring,
        initialState: AccountPoolState? = nil,
        syncTimeoutNanoseconds: UInt64 = 45_000_000_000,
        menuBarClockIntervalNanoseconds: UInt64 = 15_000_000_000,
        menuBarNowProvider: @escaping MenuBarNowProvider = { Date() },
        widgetPublisher: @escaping WidgetPublisher = { WidgetBridgePublisher.publish(from: $0) },
        syncRunner: @escaping SyncRunner = { state, viewState in
            await PoolDashboardUsageSyncFlowCoordinator()
                .syncCodexUsage(from: state, viewState: viewState)
        },
        officialSwitchRunner: OfficialSwitchRunner? = nil,
        relaySwitchRunner: RelaySwitchRunner? = nil,
        defaults: UserDefaults? = nil
    ) {
        self.store = store
        self.defaults = defaults ?? AppRuntimeStorage.defaults
        self.officialSwitchRunner = officialSwitchRunner ?? Self.makeOfficialSwitchRunner()
        self.relaySwitchRunner = relaySwitchRunner ?? Self.makeRelaySwitchRunner()
        self.menuBarClockIntervalNanoseconds = menuBarClockIntervalNanoseconds
        self.menuBarNowProvider = menuBarNowProvider
        self.menuBarNow = menuBarNowProvider()
        if let initialState {
            self.state = initialState
            self.didLoadFromStore = true
        } else if let snapshot = store.load() {
            self.state = AccountPoolState(snapshot: snapshot)
            self.didLoadFromStore = true
            self.stateRevision = 1
        } else {
            self.state = AccountPoolState(accounts: [])
            self.didLoadFromStore = true
        }
        self.widgetPublisher = widgetPublisher
        self.syncRunner = syncRunner
        self.syncTimeoutNanoseconds = syncTimeoutNanoseconds
    }

    deinit {
        autoSyncTask?.cancel()
        menuBarClockTask?.cancel()
        insightsTask?.cancel()
    }

    func load() {
        if let snapshot = store.load() {
            state = AccountPoolState(snapshot: snapshot)
            stateRevision += 1
        }
        didLoadFromStore = true
        publishWidgetSnapshot()
    }

    func bootstrapIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        if didLoadFromStore {
            publishWidgetSnapshot()
        } else {
            load()
        }
        startAutoSyncIfNeeded()
        startMenuBarClockIfNeeded()
        loadUsageHistory()
        refreshInsightsIfNeeded()
    }

    func replaceStateFromDashboard(_ nextState: AccountPoolState) {
        guard state.snapshot != nextState.snapshot else { return }
        state = nextState
        stateRevision += 1
        saveAndPublish()
    }

    func switchAccount(_ accountID: UUID) async {
        guard switchingAccountID == nil,
              let account = state.accounts.first(where: { $0.id == accountID }) else { return }
        switchingAccountID = accountID
        lastSwitchMessage = nil
        defer { switchingAccountID = nil }

        let result: SwitchResult
        if account.isRelayAPIKeyAccount {
            do {
                let request = try PoolDashboardRelayAccountCoordinator.SwitchRequest(
                    account: account,
                    fallbackAPIKey: store.apiToken(for: accountID)
                )
                result = await relaySwitchRunner(request)
            } catch {
                result = .failure(error.localizedDescription)
            }
        } else {
            result = await officialSwitchRunner(OfficialSwitchRequest(
                account: account,
                switchWithoutLaunching: state.switchWithoutLaunching,
                launchTarget: selectedSwitchLaunchTarget()
            ))
        }

        switch result {
        case .success(let message):
            let previousSnapshot = state.snapshot
            state.markActiveAccountForSwitchLaunch(accountID)
            lastSwitchMessage = message
            guard state.snapshot != previousSnapshot else { return }
            stateRevision += 1
            saveAndPublish()
        case .failure(let message):
            lastSwitchMessage = message
        }
    }

    private static func makeOfficialSwitchRunner() -> OfficialSwitchRunner {
        { request in
            let output = await PoolDashboardSwitchLaunchFlowCoordinator().switchAndLaunch(
                using: request.account,
                switchWithoutLaunching: request.switchWithoutLaunching,
                launchTarget: request.launchTarget,
                currentAuthorizedAuthFileURL: nil,
                authFileAccessService: CodexAuthFileAccessService(bookmarkKey: "codex_auth_json_bookmark"),
                viewModel: LocalOAuthImportViewModel(),
                viewState: PoolDashboardViewState(),
                authorizeAuthFile: {
                    CodexAuthFilePanelService().pickAuthFileURL()
                }
            )
            if output.didSwitchAuth {
                return .success(output.viewState.lastSwitchLaunchLog)
            }
            return .failure(output.viewState.switchLaunchError ?? L10n.text("switch.error.prefix"))
        }
    }

    private static func makeRelaySwitchRunner() -> RelaySwitchRunner {
        { request in
            let output = await PoolDashboardRelayAccountCoordinator().switchToRelayAccount(
                request,
                switchWithoutLaunching: false,
                preserveOfficialAuth: false,
                launchTarget: .auto,
                diagnosticLog: nil,
                viewState: PoolDashboardViewState()
            )
            if output.didSwitchAuth {
                return .success(output.viewState.lastSwitchLaunchLog)
            }
            return .failure(output.viewState.switchLaunchError ?? L10n.text("relay.switch.failed_format", ""))
        }
    }

    private func selectedSwitchLaunchTarget() -> CodexLaunchTarget {
        guard let storedTarget = defaults.string(forKey: "pool_dashboard.switch_launch_target") else {
            return .auto
        }
        return CodexLaunchTarget(rawValue: CodexLaunchTarget.normalizedRawValue(storedTarget)) ?? .auto
    }

    private func startMenuBarClockIfNeeded() {
        guard menuBarClockTask == nil else { return }
        guard menuBarClockIntervalNanoseconds > 0 else { return }

        menuBarClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.menuBarClockIntervalNanoseconds else { return }
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled, let self else { return }
                self.menuBarNow = self.menuBarNowProvider()
                self.refreshInsightsIfNeeded()
            }
        }
    }

    func startAutoSyncIfNeeded() {
        guard autoSyncTask == nil else { return }
        guard state.autoSyncEnabled else { return }

        autoSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNowWithTimeout(origin: .autoSync)
                if Task.isCancelled { break }
                let sleepNanoseconds = self?.autoSyncSleepNanoseconds() ?? Self.minimumAutoSyncSleepNanoseconds
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }
        }
    }

    func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        cancelActiveSyncSilently(origin: .autoSync)
    }

    func restartAutoSyncIfNeeded() {
        stopAutoSync()
        startAutoSyncIfNeeded()
    }

    @discardableResult
    func syncNow() async -> SyncOutcome? {
        await syncNow(origin: .manual)
    }

    @discardableResult
    private func syncNow(origin: SyncOrigin) async -> SyncOutcome? {
        await syncNow(origin: origin, syncID: UUID())
    }

    @discardableResult
    private func syncNow(origin: SyncOrigin, syncID: UUID) async -> SyncOutcome? {
        guard !Task.isCancelled else { return nil }
        guard !isSyncingUsage else { return nil }

        activeSyncID = syncID
        activeSyncOrigin = origin
        isSyncingUsage = true
        defer {
            if activeSyncID == syncID {
                activeSyncID = nil
                activeSyncOrigin = nil
                isSyncingUsage = false
            }
        }

        let previousState = state
        let previousSyncError = lastSyncError
        let syncRevision = stateRevision
        let output = await syncRunner(state, PoolDashboardViewState())
        let syncError = Self.normalizedSyncError(output.viewState.syncError)
        guard syncRevision == stateRevision else {
            return publishSyncOutcome(
                status: .staleDiscard,
                previousState: previousState,
                previousSyncError: previousSyncError,
                outputViewState: output.viewState,
                syncError: nil,
                stateApplied: false,
                resultingState: state
            )
        }

        if let syncError, !syncError.isEmpty {
            lastSyncError = syncError
            return publishSyncOutcome(
                status: .failure,
                previousState: previousState,
                previousSyncError: previousSyncError,
                outputViewState: output.viewState,
                syncError: syncError,
                stateApplied: false,
                resultingState: state
            )
        }

        state = output.state
        stateRevision += 1
        lastSyncError = nil
        recordUsageHistory(now: state.lastUsageSyncAt ?? menuBarNowProvider())
        saveAndPublish()
        refreshInsightsIfNeeded()
        return publishSyncOutcome(
            status: .success,
            previousState: previousState,
            previousSyncError: previousSyncError,
            outputViewState: output.viewState,
            syncError: nil,
            stateApplied: true,
            resultingState: state
        )
    }

    func cancelSyncWithError(_ message: String) -> SyncOutcome? {
        guard activeSyncID != nil || isSyncingUsage else {
            return nil
        }

        let previousState = state
        let previousSyncError = lastSyncError
        var outputViewState = PoolDashboardViewState()
        outputViewState.syncError = message

        stateRevision += 1
        activeSyncID = nil
        activeSyncOrigin = nil
        isSyncingUsage = false
        lastSyncError = message
        return publishSyncOutcome(
            status: .timeout,
            previousState: previousState,
            previousSyncError: previousSyncError,
            outputViewState: outputViewState,
            syncError: message,
            stateApplied: false,
            resultingState: state
        )
    }

    @discardableResult
    func syncNowWithTimeout(
        timeoutNanoseconds: UInt64? = nil,
        timeoutErrorMessage: String? = nil
    ) async -> SyncOutcome? {
        await syncNowWithTimeout(
            timeoutNanoseconds: timeoutNanoseconds,
            timeoutErrorMessage: timeoutErrorMessage,
            origin: .manual
        )
    }

    @discardableResult
    private func syncNowWithTimeout(
        timeoutNanoseconds: UInt64? = nil,
        timeoutErrorMessage: String? = nil,
        origin: SyncOrigin
    ) async -> SyncOutcome? {
        let timeoutNanoseconds = timeoutNanoseconds ?? syncTimeoutNanoseconds
        let timeoutErrorMessage = timeoutErrorMessage ?? Self.defaultSyncTimeoutErrorMessage()
        let syncID = UUID()
        let syncTask = Task<SyncOutcome?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.syncNow(origin: origin, syncID: syncID)
        }
        let timeoutTask = Task<SyncOutcome?, Never> { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return nil
            }

            guard !Task.isCancelled else {
                return nil
            }

            guard let self else { return nil }
            return self.cancelSyncWithError(timeoutErrorMessage)
        }
        let resolver = SyncOutcomeRaceResolver()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task {
                    let shouldStartWaiters = await resolver.register(continuation)
                    guard shouldStartWaiters else { return }

                    Task {
                        let outcome = await syncTask.value
                        timeoutTask.cancel()
                        await resolver.resume(outcome)
                    }
                    Task {
                        let outcome = await timeoutTask.value
                        syncTask.cancel()
                        await resolver.resume(outcome)
                    }
                }
            }
        } onCancel: {
            syncTask.cancel()
            timeoutTask.cancel()
            Task {
                await self.cancelActiveSyncSilently(origin: origin, syncID: syncID)
                await resolver.cancel()
            }
        }
    }

    private func cancelActiveSyncSilently(origin: SyncOrigin) {
        cancelActiveSyncSilently(origin: origin, syncID: nil)
    }

    private func cancelActiveSyncSilently(origin: SyncOrigin, syncID: UUID?) {
        guard activeSyncID != nil || isSyncingUsage else { return }
        guard activeSyncOrigin == origin else { return }
        if let syncID {
            guard activeSyncID == syncID else { return }
        }

        stateRevision += 1
        activeSyncID = nil
        activeSyncOrigin = nil
        isSyncingUsage = false
    }

    private func readUsageHistory() throws -> UsageAnalyticsState {
        guard let raw = defaults.string(forKey: UsageInsightsSettings.historyKey), !raw.isEmpty else {
            return UsageAnalyticsState()
        }
        return try JSONDecoder().decode(UsageAnalyticsState.self, from: Data(raw.utf8))
    }

    private func loadUsageHistory() {
        do { usageHistory = try readUsageHistory().records }
        catch { historyError = L10n.text("insights.history_error") }
    }

    private func recordUsageHistory(now: Date) {
        do {
            let previous = try readUsageHistory()
            let eligible = state.accounts.filter {
                !$0.isRelayAPIKeyAccount && !$0.isUsageSyncExcluded && $0.usageSyncError?.isEmpty != false
            }
            let limit = defaults.object(forKey: "pool_dashboard.usage_analytics.max_stored_records") as? Int
                ?? UsageAnalyticsEngine.defaultMaxStoredRecords
            let next = UsageAnalyticsEngine.update(state: previous, accounts: eligible,
                activeAccountKey: state.activeAccount?.usageAnalyticsAccountKey, now: now, maxStoredRecords: limit)
            let data = try JSONEncoder().encode(next)
            defaults.set(String(decoding: data, as: UTF8.self), forKey: UsageInsightsSettings.historyKey)
            usageHistory = next.records
            historyError = nil
        } catch { historyError = L10n.text("insights.history_error") }
    }

    func refreshInsightsIfNeeded() {
        guard insightsTask == nil else { return }
        insightsTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshInsights(now: self.menuBarNow)
            self.insightsTask = nil
        }
    }

    func refreshInsights(now: Date) async {
        if UsageInsightsSettings.enabled(UsageInsightsSettings.resetReminderKey, defaults: defaults),
           let syncAt = state.lastUsageSyncAt, now.timeIntervalSince(syncAt) >= 0,
           now.timeIntervalSince(syncAt) < 3600 {
            var delivered = (defaults.dictionary(forKey: UsageInsightsSettings.deliveredKey) as? [String: Double] ?? [:])
                .filter { $0.value > now.timeIntervalSince1970 }
            for reminder in ResetExpiryReminder.pending(accounts: state.accounts, now: now) where delivered[reminder.key] == nil {
                do {
                    if try await reminderSender(reminder) {
                        reminderError = nil
                        delivered[reminder.key] = reminder.expiry.timeIntervalSince1970
                        defaults.set(delivered, forKey: UsageInsightsSettings.deliveredKey)
                    } else {
                        reminderError = L10n.text("insights.notification_denied")
                        break
                    }
                } catch { reminderError = L10n.text("insights.notification_error"); break }
            }
        }
        if !UsageInsightsSettings.enabled(UsageInsightsSettings.resetReminderKey, defaults: defaults) { reminderError = nil }
        guard showsOfficialStatus else {
            officialStatus = nil
            officialStatusError = nil
            lastStatusAttempt = nil
            return
        }
        guard lastStatusAttempt.map({ now.timeIntervalSince($0) >= 300 }) ?? true else { return }
        lastStatusAttempt = now
        do {
            let result = try await statusFetcher(now)
            guard showsOfficialStatus, !Task.isCancelled else { return }
            officialStatus = result
            officialStatusError = nil
        } catch {
            guard showsOfficialStatus, !Task.isCancelled else { return }
            officialStatusError = L10n.text("insights.status_error")
        }
    }

    private func saveAndPublish() {
        store.save(state.snapshot)
        publishWidgetSnapshot()
    }

    private func publishWidgetSnapshot() {
        widgetPublisher(state.snapshot)
    }

    private static func normalizedSyncError(_ syncError: String?) -> String? {
        let trimmed = syncError?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func publishSyncOutcome(
        status: AppPoolRuntimeSyncOutcomeStatus,
        previousState: AccountPoolState,
        previousSyncError: String?,
        outputViewState: PoolDashboardViewState,
        syncError: String?,
        stateApplied: Bool,
        resultingState: AccountPoolState
    ) -> SyncOutcome {
        let outcome = SyncOutcome(
            id: UUID(),
            status: status,
            previousState: previousState,
            previousSyncError: previousSyncError,
            outputViewState: outputViewState,
            syncError: syncError,
            stateApplied: stateApplied,
            resultingState: resultingState
        )
        lastSyncOutcome = outcome
        return outcome
    }

    static let defaultSyncTimeoutNanoseconds: UInt64 = 45_000_000_000
    private static let minimumAutoSyncSleepNanoseconds: UInt64 = 5_000_000_000

    private func autoSyncSleepNanoseconds() -> UInt64 {
        let clampedSeconds = max(5, state.autoSyncIntervalSeconds)
        return UInt64(clampedSeconds * 1_000_000_000)
    }

    private static func defaultSyncTimeoutErrorMessage() -> String {
        L10n.text(
            "sync.failure.with_description_format",
            L10n.text("sync.failure.prefix"),
            L10n.text("usage.sync.error.timeout")
        )
    }
}

private actor SyncOutcomeRaceResolver {
    private var didResume = false
    private var didCancel = false
    private var nilResultCount = 0
    private var continuation: CheckedContinuation<AppPoolRuntimeModel.SyncOutcome?, Never>?

    func register(
        _ continuation: CheckedContinuation<AppPoolRuntimeModel.SyncOutcome?, Never>
    ) -> Bool {
        guard !didResume else {
            continuation.resume(returning: nil)
            return false
        }

        self.continuation = continuation
        if didCancel {
            resumeNil()
            return false
        }

        return true
    }

    func resume(_ outcome: AppPoolRuntimeModel.SyncOutcome?) {
        guard !didResume else { return }
        guard let outcome else {
            nilResultCount += 1
            if nilResultCount == 2 {
                resumeNil()
            }
            return
        }

        resume(outcome)
    }

    func cancel() {
        guard !didResume else { return }
        didCancel = true
        if continuation != nil {
            resumeNil()
        }
    }

    private func resume(_ outcome: AppPoolRuntimeModel.SyncOutcome) {
        didResume = true
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func resumeNil() {
        didResume = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
