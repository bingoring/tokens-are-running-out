import AppKit
import Foundation
import Observation
import RunningOutCore

/// The app's state: index, reports, warnings and notifications (2-3 business-logic-model W1 to W6).
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case starting
        /// The first index after install: nothing to show yet.
        case indexing(IndexProgress)
        case noTranscripts
        case indexError(String)
        case ready
    }

    public struct Environment {
        public var root: URL
        public var database: URL
        public var sessions: URL
        public var defaults: UserDefaults
        /// Watchers, the minute timer and debounced refreshes. Off in tests and snapshots.
        public var automaticUpdates: Bool

        public init(root: URL, database: URL, sessions: URL, defaults: UserDefaults, automaticUpdates: Bool) {
            self.root = root
            self.database = database
            self.sessions = sessions
            self.defaults = defaults
            self.automaticUpdates = automaticUpdates
        }

        public static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Environment {
            Environment(
                root: CLIParser.defaultRoot(home: home), database: CLIParser.defaultDatabase(home: home),
                sessions: SessionRegistry.defaultDirectory(home: home), defaults: .standard, automaticUpdates: true)
        }
    }

    public static let releasesURL = URL(string: "https://github.com/bingoring/tokens-are-running-out/releases")!
    public static let sourceURL = URL(string: "https://github.com/bingoring/tokens-are-running-out")!
    static let notificationPrefix = "expiry."

    public private(set) var phase = Phase.starting
    public private(set) var settings: AppSettings
    public private(set) var todayReport: UsageReport?
    public private(set) var selectedReport: UsageReport?
    public private(set) var isComputing = false
    public private(set) var warnings: [ExpiryWarning] = []
    public private(set) var health = IndexHealth()
    public private(set) var notificationAuthorization = NotificationAuthorization.notDetermined
    public private(set) var loginItemStatus: LoginItemStatus
    public private(set) var now: Date
    public var popoverVisible = false {
        didSet { if popoverVisible != oldValue { popoverVisibilityChanged() } }
    }

    private let environment: Environment
    private let scheduler: NotificationScheduling
    private let loginItem: LoginItemControlling
    private let urlOpener: URLOpening
    private let registry: SessionRegistry
    private let clock: () -> Date
    private var service: IndexService?
    private var cache: [CacheKey: UsageReport] = [:]
    private var generation = 0
    private var watchers: [TranscriptWatcher] = []
    private var tickTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private struct CacheKey: Hashable {
        var period: ReportPeriod
        var threshold: Int
        var generation: Int
        var day: Int
    }

    public init(
        environment: Environment, scheduler: NotificationScheduling, loginItem: LoginItemControlling,
        urlOpener: URLOpening, registry: SessionRegistry? = nil, clock: @escaping () -> Date = Date.init
    ) {
        self.environment = environment
        self.scheduler = scheduler
        self.loginItem = loginItem
        self.urlOpener = urlOpener
        self.registry = registry ?? SessionRegistry(directory: environment.sessions)
        self.clock = clock
        self.settings = AppSettings.load(from: environment.defaults)
        self.loginItemStatus = loginItem.status
        self.now = clock()
    }

    // MARK: - W1 start

    public func start() async {
        now = clock()
        notificationAuthorization = await scheduler.authorization()
        loginItemStatus = loginItem.status
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: environment.root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            phase = .noTranscripts
            return
        }
        do {
            service = try IndexService(root: environment.root, databaseURL: environment.database)
        } catch {
            phase = .indexError(String(describing: error))
            return
        }
        startWatching()
        await indexAll()
    }

    public func retry() async {
        stopWatching()
        service = nil
        phase = .starting
        await start()
    }

    private func indexAll() async {
        guard let service else { return }
        do {
            _ = try await service.indexAll { progress in
                guard progress.isInitial else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.phase != .ready else { return }
                    self.phase = .indexing(progress)
                }
            }
            phase = .ready
            await refreshAll()
        } catch {
            phase = .indexError(String(describing: error))
        }
    }

    // MARK: - W2, W3 changes

    public func transcriptsChanged(_ urls: [URL]) async {
        guard let service, phase == .ready else { return }
        do {
            let summary = try await service.update(paths: urls)
            guard summary.filesRead > 0 || summary.filesRemoved > 0 else { return }
            generation += 1
            scheduleRefresh()
        } catch {
            phase = .indexError(String(describing: error))
        }
    }

    public func sessionsChanged() async {
        await refreshWarnings()
    }

    /// W4: once a minute while something is counting down or the popover is open.
    public func minuteTick() async {
        let previous = now
        now = clock()
        if Calendar.current.startOfDay(for: previous) != Calendar.current.startOfDay(for: now) {
            await refreshAll()
        } else {
            await refreshWarnings()
        }
    }

    // MARK: - W5 user actions

    public func update(_ change: (inout AppSettings) -> Void) async {
        let old = settings
        var new = settings
        change(&new)
        guard new != old else { return }
        settings = new
        new.save(to: environment.defaults)
        if new.rebuildThresholdTokens != old.rebuildThresholdTokens {
            cache = [:]
            await refreshReports()
        } else if new.selectedPeriod != old.selectedPeriod {
            selectedReport = await report(new.selectedPeriod)
        }
        if new.notifyBeforeExpiry, !old.notifyBeforeExpiry, notificationAuthorization == .notDetermined {
            notificationAuthorization = await scheduler.requestAuthorization()
        }
        if new.warningContextTokens != old.warningContextTokens {
            await refreshWarnings()
        } else if new.notifyBeforeExpiry != old.notifyBeforeExpiry || new.notifyLeadMinutes != old.notifyLeadMinutes {
            await reconcileNotifications()
        }
    }

    public func setOpenAtLogin(_ enabled: Bool) {
        try? loginItem.setEnabled(enabled)
        loginItemStatus = loginItem.status
    }

    /// The settings window shows the live permission, which the user may change in System Settings.
    public func refreshSystemStatus() async {
        notificationAuthorization = await scheduler.authorization()
        loginItemStatus = loginItem.status
    }

    public func openReleasesPage() { urlOpener.open(Self.releasesURL) }
    public func openSource() { urlOpener.open(Self.sourceURL) }
    public func openLoginItemsSettings() { loginItem.openSystemSettings() }
    public func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            urlOpener.open(url)
        }
    }

    // MARK: - Refresh

    public func refreshAll() async {
        now = clock()
        cache = [:]
        lastRefresh = clock()
        await refreshReports()
        await refreshWarnings()
        if let service, let health = try? await service.health(now: now.timeIntervalSince1970) {
            self.health = health
        }
    }

    private func refreshReports() async {
        isComputing = true
        defer { isComputing = false }
        todayReport = await report(.today)
        selectedReport = settings.selectedPeriod == .today ? todayReport : await report(settings.selectedPeriod)
    }

    private func report(_ period: ReportPeriod) async -> UsageReport? {
        guard let service else { return nil }
        let day = Int(Calendar.current.startOfDay(for: now).timeIntervalSince1970)
        let key = CacheKey(
            period: period, threshold: settings.rebuildThresholdTokens, generation: generation, day: day)
        if let cached = cache[key] { return cached }
        do {
            let found = try await service.report(
                period: period, now: now, rebuildThreshold: settings.rebuildThresholdTokens)
            cache[key] = found
            return found
        } catch {
            phase = .indexError(String(describing: error))
            return nil
        }
    }

    private func refreshWarnings() async {
        guard let service else { return }
        now = clock()
        let state = registry.load()
        do {
            warnings = try await service.expiryWarnings(
                registry: state, now: now.timeIntervalSince1970, warningContextTokens: settings.warningContextTokens)
        } catch {
            phase = .indexError(String(describing: error))
            return
        }
        await reconcileNotifications()
        updateTicking()
    }

    /// Coalesces bursts of transcript changes: refresh 2 s after the last one, at most every 10 s.
    private func scheduleRefresh() {
        guard environment.automaticUpdates else { return }
        guard refreshTask == nil else { return }
        let wait = max(2, 10 - clock().timeIntervalSince(lastRefresh))
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            await self.refreshAll()
        }
    }

    // MARK: - W6 notifications

    func desiredNotifications() -> [ExpiryNotificationRequest] {
        guard settings.notifyBeforeExpiry, notificationAuthorization == .authorized else { return [] }
        let lead = Double(settings.notifyLeadMinutes * 60)
        return warnings.compactMap { warning in
            guard warning.ttl == .oneHour else { return nil }
            let fireAt = warning.expiresAt - lead
            guard fireAt > now.timeIntervalSince1970 else { return nil }
            return ExpiryNotificationRequest(
                identifier: "\(Self.notificationPrefix)\(warning.sessionID).\(Int(warning.expiresAt))",
                fireAt: Date(timeIntervalSince1970: fireAt),
                title: Copy.notificationTitle(minutes: settings.notifyLeadMinutes),
                body: Copy.notificationBody(warning))
        }
    }

    private func reconcileNotifications() async {
        let desired = desiredNotifications()
        let pending = await scheduler.pendingIdentifiers().filter { $0.hasPrefix(Self.notificationPrefix) }
        let wanted = Set(desired.map(\.identifier))
        let stale = pending.filter { !wanted.contains($0) }
        if !stale.isEmpty { scheduler.remove(identifiers: stale) }
        for request in desired where !pending.contains(request.identifier) {
            await scheduler.add(request)
        }
    }

    // MARK: - Watching and ticking

    private func startWatching() {
        guard environment.automaticUpdates else { return }
        let transcripts = TranscriptWatcher(root: environment.root) { [weak self] urls in
            Task { @MainActor in await self?.transcriptsChanged(urls) }
        }
        let sessions = TranscriptWatcher(root: environment.sessions) { [weak self] _ in
            Task { @MainActor in await self?.sessionsChanged() }
        }
        for watcher in [transcripts, sessions] where (try? watcher.start()) != nil { watchers.append(watcher) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.minuteTick() }
            })
        observers.append(
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) {
                [weak self] _ in Task { @MainActor in await self?.refreshAll() }
            })
    }

    private func stopWatching() {
        for watcher in watchers { watcher.stop() }
        watchers = []
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    private func popoverVisibilityChanged() {
        if popoverVisible {
            Task {
                if phase == .noTranscripts { await start() } else { await minuteTick() }
            }
        }
        updateTicking()
    }

    /// No timer at all unless a cache is counting down or the popover is open (NFR: idle CPU).
    private func updateTicking() {
        let wanted = environment.automaticUpdates && (!warnings.isEmpty || popoverVisible)
        if !wanted {
            tickTask?.cancel()
            tickTask = nil
        } else if tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    let seconds = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                    try? await Task.sleep(for: .seconds(seconds + 0.05))
                    guard let self, !Task.isCancelled else { return }
                    await self.minuteTick()
                }
            }
        }
    }
}
