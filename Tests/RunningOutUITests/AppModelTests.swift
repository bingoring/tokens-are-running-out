import Foundation
import RunningOutCore
import Testing

@testable import RunningOutUI

@MainActor final class FakeScheduler: NotificationScheduling {
    var status = NotificationAuthorization.authorized
    var pending: [String: ExpiryNotificationRequest] = [:]
    var added: [ExpiryNotificationRequest] = []
    var removed: [String] = []
    var requested = 0

    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> NotificationAuthorization {
        requested += 1
        return status
    }
    func pendingIdentifiers() async -> [String] { pending.keys.sorted() }
    func remove(identifiers: [String]) {
        removed += identifiers
        for id in identifiers { pending[id] = nil }
    }
    func add(_ request: ExpiryNotificationRequest) async {
        added.append(request)
        pending[request.identifier] = request
    }
}

@MainActor final class FakeLoginItem: LoginItemControlling {
    var status = LoginItemStatus.disabled
    func setEnabled(_ enabled: Bool) throws { status = enabled ? .enabled : .disabled }
    func openSystemSettings() {}
}

@MainActor final class FakePasteboard: PasteboardWriting {
    var written: [String] = []
    var succeeds = true
    func write(_ text: String) -> Bool {
        written.append(text)
        return succeeds
    }
}

@MainActor final class FakeOpener: URLOpening {
    var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}

/// Synthetic transcripts only. Times are relative to `now` (2026-11-10T12:00:00Z).
@MainActor
@Suite("AppModel")
struct AppModelTests {
    static let now = Date(timeIntervalSince1970: 1_794_268_800 + 12 * 3600)
    let dir: URL
    let scheduler = FakeScheduler()
    let defaults: UserDefaults

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("running-out-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "running-out-ui-\(UUID().uuidString)")!
    }

    private func write(_ text: String, to path: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// One call `minutesAgo` before `now`, as Claude Code writes it.
    private func call(
        _ id: String, session: String = "s1", minutesAgo: Double, read: Int = 0, write: Int = 0, ttl: String = "1h"
    ) -> String {
        let at = Self.now.addingTimeInterval(-minutesAgo * 60).formatted(.iso8601)
        let w1 = ttl == "1h" ? write : 0
        let w5 = ttl == "5m" ? write : 0
        return
            #"{"type":"assistant","timestamp":"\#(at)","sessionId":"\#(session)","version":"2.1.325","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":10,"cache_read_input_tokens":\#(read),"cache_creation_input_tokens":\#(write),"cache_creation":{"ephemeral_1h_input_tokens":\#(w1),"ephemeral_5m_input_tokens":\#(w5)}}}}"#
            + "\n"
    }

    private func running(_ session: String, status: String = "idle", pid: Int = 4242) throws {
        try write(
            #"{"pid":\#(pid),"sessionId":"\#(session)","status":"\#(status)","name":"Refactor parser"}"#,
            to: "sessions/\(pid).json")
    }

    private func makeModel(
        clock: @escaping () -> Date = { AppModelTests.now }, pasteboard: FakePasteboard = FakePasteboard()
    ) -> AppModel {
        AppModel(
            environment: .init(
                root: dir.appendingPathComponent("projects"), database: dir.appendingPathComponent("index.sqlite"),
                sessions: dir.appendingPathComponent("sessions"), defaults: defaults, automaticUpdates: false),
            scheduler: scheduler, loginItem: FakeLoginItem(), urlOpener: FakeOpener(), pasteboard: pasteboard,
            registry: SessionRegistry(directory: dir.appendingPathComponent("sessions"), isAlive: { _, _ in true }),
            clock: clock)
    }

    @Test("without a transcripts folder the app says so")
    func noTranscripts() async {
        let model = makeModel()
        await model.start()
        #expect(model.phase == .noTranscripts)
    }

    @Test("starting indexes the transcripts and computes today's report")
    func startsReady() async throws {
        try write(
            call("m1", minutesAgo: 120, write: 60_000) + call("m2", minutesAgo: 10, read: 60_000),
            to: "projects/-p/s1.jsonl")
        let model = makeModel()
        await model.start()
        #expect(model.phase == .ready)
        #expect(model.todayReport?.calls == 2)
        #expect(model.health.kind == .none)
    }

    @Test("an idle session with a large cache is warned, and a notification is scheduled only when turned on")
    func warningAndNotification() async throws {
        try write(call("m1", minutesAgo: 10, write: 120_000), to: "projects/-p/s1.jsonl")
        try running("s1")
        let model = makeModel()
        await model.start()
        #expect(model.warnings.map(\.sessionID) == ["s1"])
        #expect(scheduler.added.isEmpty)

        await model.update { $0.notifyBeforeExpiry = true }
        let expiresAt = Self.now.timeIntervalSince1970 + 50 * 60
        #expect(scheduler.added.map(\.identifier) == ["expiry.s1.\(Int(expiresAt)).10"])
        #expect(scheduler.added.first?.fireAt == Date(timeIntervalSince1970: expiresAt - 600))
    }

    @Test("large sessions are refreshed with the warnings, from the same running-session read")
    func largeSessionsRefreshWithWarnings() async throws {
        try write(call("m1", minutesAgo: 10, read: 250_000), to: "projects/-p/s1.jsonl")
        try running("s1")
        let model = makeModel()
        await model.start()
        #expect(model.largeSessions.map(\.sessionID) == ["s1"])
        #expect(model.largeSessions.first?.contextTokens == 2 + 250_000)
    }

    @Test("copying puts the compact prompt on the pasteboard")
    func copyWritesThePrompt() {
        let pasteboard = FakePasteboard()
        let model = makeModel(pasteboard: pasteboard)
        #expect(model.copyCompactPrompt())
        #expect(pasteboard.written == [CompactPrompt.text])
    }

    @Test("a failed pasteboard write is reported, so the button does not say Copied")
    func failedCopyIsNotConfirmed() {
        let pasteboard = FakePasteboard()
        pasteboard.succeeds = false
        let model = makeModel(pasteboard: pasteboard)
        #expect(!model.copyCompactPrompt())
    }

    @Test("a denied permission schedules nothing, and turning notifications on asks only when undecided")
    func deniedPermission() async throws {
        try write(call("m1", minutesAgo: 10, write: 120_000), to: "projects/-p/s1.jsonl")
        try running("s1")
        scheduler.status = .denied
        let model = makeModel()
        await model.start()
        await model.update { $0.notifyBeforeExpiry = true }
        #expect(scheduler.added.isEmpty)
        #expect(scheduler.requested == 0)
        #expect(model.notificationAuthorization == .denied)
    }

    @Test("a new call moves the expiry: the old notification is removed and a new one scheduled")
    func rescheduleOnNewCall() async throws {
        try write(call("m1", minutesAgo: 30, write: 120_000), to: "projects/-p/s1.jsonl")
        try running("s1")
        defaults.set(true, forKey: "tokensAreRunningOut.notifyBeforeExpiry")
        let model = makeModel()
        await model.start()
        let first = try #require(scheduler.added.first?.identifier)
        try write(
            call("m1", minutesAgo: 30, write: 120_000) + call("m2", minutesAgo: 1, read: 120_000, write: 100),
            to: "projects/-p/s1.jsonl")
        await model.transcriptsChanged([dir.appendingPathComponent("projects/-p/s1.jsonl")])
        await model.refreshAll()
        #expect(scheduler.removed == [first])
        #expect(scheduler.pending.count == 1)
        #expect(scheduler.pending.keys.first != first)
    }

    @Test("a five-minute cache and a busy session get no notification")
    func noNotificationCases() async throws {
        try write(call("m1", session: "s1", minutesAgo: 1, write: 120_000, ttl: "5m"), to: "projects/-p/s1.jsonl")
        try write(call("m2", session: "s2", minutesAgo: 1, write: 120_000), to: "projects/-p/s2.jsonl")
        try running("s1", pid: 1)
        try running("s2", status: "busy", pid: 2)
        defaults.set(true, forKey: "tokensAreRunningOut.notifyBeforeExpiry")
        let model = makeModel()
        await model.start()
        #expect(model.warnings.map(\.sessionID) == ["s1"])
        #expect(scheduler.added.isEmpty)
    }

    @Test("changing the rebuild threshold recomputes the reports")
    func thresholdSetting() async throws {
        try write(call("m1", minutesAgo: 120, write: 60_000), to: "projects/-p/s1.jsonl")
        let model = makeModel()
        await model.start()
        #expect(model.todayReport?.rebuildCount == 1)
        await model.update { $0.rebuildThresholdTokens = 75_000 }
        #expect(model.todayReport?.rebuildCount == 0)
        #expect(AppSettings.load(from: defaults).rebuildThresholdTokens == 75_000)
    }

    @Test("an index that cannot be created is an error with a way to retry")
    func indexError() async throws {
        try write(call("m1", minutesAgo: 10), to: "projects/-p/s1.jsonl")
        try write("a file where the index folder should be", to: "blocked")
        let model = AppModel(
            environment: .init(
                root: dir.appendingPathComponent("projects"),
                database: dir.appendingPathComponent("blocked/index.sqlite"),
                sessions: dir.appendingPathComponent("sessions"), defaults: defaults, automaticUpdates: false),
            scheduler: scheduler, loginItem: FakeLoginItem(), urlOpener: FakeOpener(), clock: { AppModelTests.now })
        await model.start()
        guard case .indexError = model.phase else {
            Issue.record("expected an index error, got \(model.phase)")
            return
        }
    }

    @Test("settings outside the allowed values read as the defaults")
    func settingsValidation() {
        defaults.set(12_345, forKey: "tokensAreRunningOut.rebuildThresholdTokens")
        defaults.set(7, forKey: "tokensAreRunningOut.notifyLeadMinutes")
        let settings = AppSettings.load(from: defaults)
        #expect(settings.rebuildThresholdTokens == 50_000)
        #expect(settings.notifyLeadMinutes == 10)
    }

    @Test("another period's report waits until the popover opens")
    func selectedReportWaitsForPopover() async throws {
        try write(call("m1", minutesAgo: 120, write: 60_000), to: "projects/-p/s1.jsonl")
        defaults.set("last7Days", forKey: "tokensAreRunningOut.selectedPeriod")
        let model = makeModel()
        await model.start()
        #expect(model.todayReport != nil)
        #expect(model.selectedReport == nil)
        model.popoverVisible = true
        for _ in 0..<200 where model.selectedReport == nil { await Task.yield() }
        #expect(model.selectedReport?.calls == 1)
    }

    @Test("changing the lead time replaces the scheduled notification")
    func leadTimeChange() async throws {
        try write(call("m1", minutesAgo: 10, write: 120_000), to: "projects/-p/s1.jsonl")
        try running("s1")
        defaults.set(true, forKey: "tokensAreRunningOut.notifyBeforeExpiry")
        let model = makeModel()
        await model.start()
        let first = try #require(scheduler.added.first)
        await model.update { $0.notifyLeadMinutes = 15 }
        #expect(scheduler.removed == [first.identifier])
        #expect(scheduler.pending.count == 1)
        #expect(scheduler.pending.values.first?.fireAt == first.fireAt.addingTimeInterval(-5 * 60))
    }

    @Test("a moving window is recomputed when time has passed, even without new calls")
    func movingWindow() async throws {
        try write(call("m1", minutesAgo: 4 * 60, write: 100), to: "projects/-p/s1.jsonl")
        defaults.set("last5Hours", forKey: "tokensAreRunningOut.selectedPeriod")
        let clock = Clock(AppModelTests.now)
        let model = makeModel(clock: { clock.now })
        await model.start()
        model.popoverVisible = true
        for _ in 0..<200 where model.selectedReport == nil { await Task.yield() }
        #expect(model.selectedReport?.calls == 1)
        model.popoverVisible = false
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        model.popoverVisible = true
        for _ in 0..<200 where model.selectedReport?.calls != 0 { await Task.yield() }
        #expect(model.selectedReport?.calls == 0)
    }

    @Test("changes that arrive before the index is ready are kept and applied afterwards")
    func changesBeforeReady() async throws {
        let file = dir.appendingPathComponent("projects/-p/s1.jsonl")
        try write(call("m1", minutesAgo: 10), to: "projects/-p/s1.jsonl")
        let model = makeModel()
        await model.transcriptsChanged([file])
        #expect(model.pendingChanges == [file])
        await model.start()
        #expect(model.pendingChanges.isEmpty)
        #expect(model.phase == .ready)
    }
}

/// A clock the test moves by hand.
@MainActor final class Clock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
