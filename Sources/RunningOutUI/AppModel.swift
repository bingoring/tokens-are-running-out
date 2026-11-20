import AppKit
import Foundation
import Observation
import RunningOutCore

/// The index operations the app uses. A protocol so tests can pause or fail them (R-1).
public protocol IndexServing: AnyObject, Sendable {
    func indexAll(progress: (@Sendable (IndexProgress) -> Void)?) async throws -> IndexSummary
    func update(paths: [URL]) async throws -> IndexSummary
    func hasIndexedFiles() async throws -> Bool
    func report(period: ReportPeriod, now: Date, rebuildThreshold: Int) async throws -> UsageReport
    func expiryWarnings(registry: RegistryState, now: Double, warningContextTokens: Int) async throws
        -> [ExpiryWarning]
    func health(now: Double) async throws -> IndexHealth
}

extension IndexService: IndexServing {}

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

    public internal(set) var phase = Phase.starting
    public private(set) var settings: AppSettings
    public internal(set) var todayReport: UsageReport?
    public internal(set) var selectedReport: UsageReport?
    public private(set) var isComputing = false
    public internal(set) var warnings: [ExpiryWarning] = []
    public internal(set) var health = IndexHealth()
    public internal(set) var notificationAuthorization = NotificationAuthorization.notDetermined
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
    private let openIndex: @Sendable (_ root: URL, _ database: URL, _ opening: IndexOpening) throws -> any IndexServing
    private var service: (any IndexServing)?
    private var cache: [CacheKey: UsageReport] = [:]
    private var generation = 0
    private var watchers: [TranscriptWatcher] = []
    private var tickTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var parentWatcher: TranscriptWatcher?
    /// The transcripts watcher could not start: check for changes once a minute instead (§6).
    private var polling = false
    /// Changes reported before the index was ready, applied once it is (W1 starts watching first).
    private(set) var pendingChanges: [URL] = []
    private var reconciling = false
    private var reconcileAgain = false
    private var refreshingWarnings = false
    private var refreshWarningsAgain = false
    private var starting = false
    /// Try Again while a start runs: the start begins again once it finishes (R-1).
    private var restartRequested = false
    /// The index turned out damaged while running: the next start rebuilds it rather than reopening it.
    private var startOverRequested = false

    private struct CacheKey: Hashable {
        var period: ReportPeriod
        var threshold: Int
        var generation: Int
        /// Every period ends now, so a report is only reused within the same minute.
        var minute: Int
    }

    public init(
        environment: Environment, scheduler: NotificationScheduling, loginItem: LoginItemControlling,
        urlOpener: URLOpening, registry: SessionRegistry? = nil, clock: @escaping () -> Date = Date.init,
        openIndex:
            @escaping @Sendable (_ root: URL, _ database: URL, _ opening: IndexOpening) throws
            -> any IndexServing = { try IndexService(root: $0, databaseURL: $1, opening: $2) }
    ) {
        self.openIndex = openIndex
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

    /// Never runs twice at once: the menu bar, the popover and a retry can all ask. A retry that arrives
    /// meanwhile makes it start again when it finishes, so no request is lost and no half-torn state is left.
    public func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        repeat {
            restartRequested = false
            await startOnce()
        } while restartRequested
    }

    private func startOnce() async {
        stopWatching()
        service = nil
        polling = false
        if phase != .starting { phase = .starting }
        let opening: IndexOpening = startOverRequested ? .startOver : .replaceUnusable
        startOverRequested = false
        now = clock()
        notificationAuthorization = await scheduler.authorization()
        loginItemStatus = loginItem.status
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: environment.root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            phase = .noTranscripts
            watchForTranscriptsFolder()
            return
        }
        parentWatcher?.stop()
        parentWatcher = nil
        do {
            // Opening may rebuild the index after a schema change: keep it off the main thread.
            let (root, database, openIndex) = (environment.root, environment.database, openIndex)
            service = try await Task.detached { try openIndex(root, database, opening) }.value
        } catch {
            indexFailed(error)
            return
        }
        startWatching()
        // W1.5: with a completed index, show its results while the scan catches up.
        do {
            if try await service?.hasIndexedFiles() == true {
                phase = .ready
                await refreshAll()
            }
        } catch {
            log.error("checking the index failed: \(String(describing: error), privacy: .public)")
        }
        await indexAll()
    }

    /// Starts once; the menu bar label calls it when it first appears.
    public func startIfNeeded() async {
        guard phase == .starting, service == nil else { return }
        await start()
    }

    public func retry() async {
        if starting {
            restartRequested = true
            return
        }
        await start()
    }

    /// Damage is not retried on its own: it waits for Try Again, which then rebuilds the index (R-1).
    private func indexFailed(_ error: any Error) {
        phase = .indexError(String(describing: error))
        if (error as? SQLiteError)?.isCorruption == true { startOverRequested = true }
        log.error("the index failed: \(String(describing: error), privacy: .public)")
    }

    private func indexAll() async {
        guard let service else { return }
        do {
            // Weak in the outer closure too: the inner capture alone would still hold the model strongly.
            let summary = try await service.indexAll { [weak self] progress in
                guard progress.isInitial else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch self.phase {
                    case .starting, .indexing: self.phase = .indexing(progress)
                    default: break
                    }
                }
            }
            logSkipped(summary)
            // Changes keep arriving while the backlog is applied; nothing awaits between the last check and
            // `.ready`, so none is left behind.
            while !pendingChanges.isEmpty {
                let paths = pendingChanges
                pendingChanges = []
                logSkipped(try await service.update(paths: paths))
            }
            phase = .ready
            generation += 1
            await refreshAll()
        } catch {
            indexFailed(error)
        }
    }

    /// R13: files that could not be read are reported, by count only (their paths name the user's projects).
    private func logSkipped(_ summary: IndexSummary) {
        guard !summary.skippedFiles.isEmpty else { return }
        log.error("skipped \(summary.skippedFiles.count, privacy: .public) transcript files")
    }

    // MARK: - W2, W3 changes

    public func transcriptsChanged(_ urls: [URL]) async {
        // After an error (but not damage, which waits for Try Again), the next change tries again: one rescan
        // of the root also picks up whatever failed before.
        var recovering = false
        if case .indexError = phase, service != nil, !startOverRequested { recovering = true }
        guard let service, phase == .ready || recovering else {
            // Keep what changed during the first scan; a long backlog becomes one rescan of the root.
            pendingChanges = pendingChanges.count > 500 ? [environment.root] : pendingChanges + urls
            return
        }
        do {
            let summary = try await service.update(paths: recovering ? [environment.root] : urls)
            logSkipped(summary)
            if recovering {
                pendingChanges = []
                phase = .ready
                generation += 1
                await refreshAll()
                return
            }
            guard summary.filesRead > 0 || summary.filesRemoved > 0 || summary.filesReset > 0 else { return }
            generation += 1
            scheduleRefresh()
        } catch {
            indexFailed(error)
        }
    }

    /// Session files change at every status change: one refresh at a time, and one more if more arrived.
    public func sessionsChanged() async {
        if refreshingWarnings {
            refreshWarningsAgain = true
            return
        }
        refreshingWarnings = true
        defer { refreshingWarnings = false }
        repeat {
            refreshWarningsAgain = false
            await refreshWarnings()
        } while refreshWarningsAgain
    }

    /// W4: once a minute while something is counting down or the popover is open.
    public func minuteTick() async {
        if polling { await transcriptsChanged([environment.root]) }
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
            let period = new.selectedPeriod
            let found = await report(period)
            // A slower answer for a period the user already left must not replace the current one.
            if settings.selectedPeriod == period { selectedReport = found }
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
        do {
            try loginItem.setEnabled(enabled)
        } catch {
            log.error("changing the login item failed: \(error.localizedDescription, privacy: .public)")
        }
        loginItemStatus = loginItem.status
    }

    /// The settings window shows the live permission, which the user may change in System Settings.
    public func refreshSystemStatus() async {
        let before = notificationAuthorization
        notificationAuthorization = await scheduler.authorization()
        loginItemStatus = loginItem.status
        if notificationAuthorization != before { await reconcileNotifications() }
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
        if let service {
            do {
                health = try await service.health(now: now.timeIntervalSince1970)
            } catch {
                log.error("the format check failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func refreshReports() async {
        isComputing = true
        defer { isComputing = false }
        todayReport = await report(.today)
        let period = settings.selectedPeriod
        if period == .today {
            selectedReport = todayReport
        } else if popoverVisible {
            let found = await report(period)
            if settings.selectedPeriod == period { selectedReport = found }
        }
    }

    private func report(_ period: ReportPeriod) async -> UsageReport? {
        guard let service else { return nil }
        let key = CacheKey(
            period: period, threshold: settings.rebuildThresholdTokens, generation: generation,
            minute: Int(now.timeIntervalSince1970 / 60))
        if let cached = cache[key] { return cached }
        do {
            let found = try await service.report(
                period: period, now: now, rebuildThreshold: settings.rebuildThresholdTokens)
            // Older minutes and generations can never be asked for again.
            cache = cache.filter { $0.key.minute == key.minute && $0.key.generation == key.generation }
            cache[key] = found
            return found
        } catch {
            indexFailed(error)
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
            indexFailed(error)
            return
        }
        await reconcileNotifications()
        updateTicking()
    }

    /// Throttles bursts of transcript changes: the first change after a quiet spell refreshes after 2 s; while
    /// changes keep coming, at most every 10 s with the popover open and every 30 s with only the menu bar
    /// showing (a busy session writes every second). Recorded as a deviation from NFR "within 2 s".
    private func scheduleRefresh() {
        guard environment.automaticUpdates else { return }
        guard refreshTask == nil else { return }
        let interval: Double = popoverVisible ? 10 : 30
        let wait = max(2, interval - clock().timeIntervalSince(lastRefresh))
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
                // The lead time is part of the identifier, so changing it replaces what is scheduled.
                identifier:
                    "\(Self.notificationPrefix)\(warning.sessionID).\(Int(warning.expiresAt)).\(settings.notifyLeadMinutes)",
                fireAt: Date(timeIntervalSince1970: fireAt),
                title: Copy.notificationTitle(minutes: settings.notifyLeadMinutes),
                body: Copy.notificationBody(warning))
        }
    }

    /// One at a time: a second request while one runs makes it run once more (INV2).
    private func reconcileNotifications() async {
        if reconciling {
            reconcileAgain = true
            return
        }
        reconciling = true
        defer { reconciling = false }
        repeat {
            reconcileAgain = false
            await reconcileOnce()
        } while reconcileAgain
    }

    private func reconcileOnce() async {
        // Settings and permission changes come between ticks: a notification time that passed since the last
        // tick must not be scheduled (BR-N3).
        now = clock()
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
        if (try? transcripts.start()) != nil { watchers.append(transcripts) } else { polling = true }
        if (try? sessions.start()) != nil { watchers.append(sessions) }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.minuteTick() }
            })
        // A new day, time zone or clock moves "today" and the minutes left.
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.refreshAll() }
                })
        }
        // Notification permission may have changed in System Settings while the app was in the background.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in await self?.refreshSystemStatus() } })
        updateTicking()
    }

    /// W1.3: while there is no transcripts folder, watch its parent for it to appear.
    private func watchForTranscriptsFolder() {
        guard environment.automaticUpdates, parentWatcher == nil else { return }
        let parent = environment.root.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        let watcher = TranscriptWatcher(root: parent) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .noTranscripts,
                    FileManager.default.fileExists(atPath: self.environment.root.path)
                else { return }
                await self.retry()
            }
        }
        if (try? watcher.start()) != nil { parentWatcher = watcher }
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
                if phase == .noTranscripts {
                    await retry()
                    return
                }
                now = clock()
                // Every period ends now: recompute (a cache hit only within the same minute).
                let period = settings.selectedPeriod
                let found = await report(period)
                if settings.selectedPeriod == period { selectedReport = found }
                await minuteTick()
            }
        }
        updateTicking()
    }

    /// No timer at all unless a cache is counting down or the popover is open (NFR: idle CPU).
    private func updateTicking() {
        let wanted = environment.automaticUpdates && (!warnings.isEmpty || popoverVisible || polling)
        if !wanted {
            tickTask?.cancel()
            tickTask = nil
        } else if tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    // Wake at the next whole minute, or sooner when a warned cache expires before it,
                    // so an expired warning disappears at once rather than up to a minute later.
                    let current = Date().timeIntervalSince1970
                    let nextMinute = current - current.truncatingRemainder(dividingBy: 60) + 60
                    let nextExpiry = self?.warnings.map(\.expiresAt).filter { $0 > current }.min()
                    let wake = min(nextMinute, nextExpiry ?? nextMinute)
                    try? await Task.sleep(for: .seconds(wake - current + 0.05))
                    guard let self, !Task.isCancelled else { return }
                    await self.minuteTick()
                }
            }
        }
    }
}
