import Foundation
import RunningOutCore
import SQLite3
import Testing

@testable import RunningOutUI

/// A one-time checkpoint: the code under test waits at `pass()` until the test opens it.
actor Gate {
    private var arrived = false
    private var opened = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var passWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        arrived = true
        for waiter in arrivalWaiters { waiter.resume() }
        arrivalWaiters = []
        guard !opened else { return }
        await withCheckedContinuation { passWaiters.append($0) }
    }

    func untilArrived() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in passWaiters { waiter.resume() }
        passWaiters = []
    }
}

/// The real index, with calls a test can hold at a gate or make fail once.
actor ControlledIndex: IndexServing {
    let real: IndexService
    private var indexAllGate: Gate?
    private var updateGates: [Gate] = []
    private var updateFailures: [any Error] = []

    init(_ real: IndexService) { self.real = real }

    func holdIndexAll(at gate: Gate) { indexAllGate = gate }
    func holdNextUpdate(at gate: Gate) { updateGates.append(gate) }
    func failNextUpdate(with error: any Error) { updateFailures.append(error) }

    func indexAll(progress: (@Sendable (IndexProgress) -> Void)?) async throws -> IndexSummary {
        let summary = try await real.indexAll(progress: progress)
        if let gate = indexAllGate {
            indexAllGate = nil
            await gate.pass()
        }
        return summary
    }

    func update(paths: [URL]) async throws -> IndexSummary {
        if !updateGates.isEmpty { await updateGates.removeFirst().pass() }
        if !updateFailures.isEmpty { throw updateFailures.removeFirst() }
        return try await real.update(paths: paths)
    }

    func hasIndexedFiles() async throws -> Bool { try await real.hasIndexedFiles() }
    func report(period: ReportPeriod, now: Date, rebuildThreshold: Int) async throws -> UsageReport {
        try await real.report(period: period, now: now, rebuildThreshold: rebuildThreshold)
    }
    func expiryWarnings(registry: RegistryState, now: Double, warningContextTokens: Int) async throws
        -> [ExpiryWarning]
    {
        try await real.expiryWarnings(registry: registry, now: now, warningContextTokens: warningContextTokens)
    }
    func largeSessions(registry: RegistryState, now: Double, thresholdTokens: Int) async throws -> [LargeSession] {
        try await real.largeSessions(registry: registry, now: now, thresholdTokens: thresholdTokens)
    }
    func health(now: Double) async throws -> IndexHealth { try await real.health(now: now) }
}

/// Records how the model asked to open the index.
final class OpeningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [IndexOpening] = []
    func append(_ opening: IndexOpening) { lock.withLock { entries.append(opening) } }
    var all: [IndexOpening] { lock.withLock { entries } }
}

/// R-1: the app's state machine under races and failures. Synthetic transcripts only.
@MainActor
@Suite("AppModel recovery")
struct AppModelRecoveryTests {
    static let now = Date(timeIntervalSince1970: 1_794_268_800 + 12 * 3600)
    let dir: URL
    let defaults: UserDefaults
    let index: ControlledIndex
    let openings = OpeningLog()

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("running-out-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("projects"), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "running-out-ui-\(UUID().uuidString)")!
        index = ControlledIndex(
            try IndexService(
                root: dir.appendingPathComponent("projects"), databaseURL: dir.appendingPathComponent("index.sqlite"))
        )
    }

    private func transcript(_ name: String) -> URL { dir.appendingPathComponent("projects/-p/\(name).jsonl") }

    /// Appends one call made `minutesAgo` before `now` to a transcript.
    private func addCall(_ id: String, to name: String, minutesAgo: Double = 10) throws {
        let at = Self.now.addingTimeInterval(-minutesAgo * 60).formatted(.iso8601)
        let line =
            #"{"type":"assistant","timestamp":"\#(at)","sessionId":"\#(name)","message":{"id":"\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":10}}}"#
            + "\n"
        let url = transcript(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try Data(line.utf8).write(to: url)
        }
    }

    private func makeModel(clock: @escaping () -> Date = { AppModelRecoveryTests.now }) -> AppModel {
        let (index, openings) = (self.index, self.openings)
        return AppModel(
            environment: .init(
                root: dir.appendingPathComponent("projects"), database: dir.appendingPathComponent("index.sqlite"),
                sessions: dir.appendingPathComponent("sessions"), defaults: defaults, automaticUpdates: false),
            scheduler: FakeScheduler(), loginItem: FakeLoginItem(), urlOpener: FakeOpener(),
            registry: SessionRegistry(directory: dir.appendingPathComponent("sessions"), isAlive: { _, _ in true }),
            clock: clock,
            openIndex: { _, _, opening in
                openings.append(opening)
                return index
            })
    }

    // MEDIUM: a change that arrived while the backlog was being applied was left behind.
    @Test("changes that arrive while the backlog is applied are applied too")
    func backlogRace() async throws {
        try addCall("m1", to: "s1")
        let indexed = Gate()
        let applyingBacklog = Gate()
        await index.holdIndexAll(at: indexed)
        await index.holdNextUpdate(at: applyingBacklog)
        let model = makeModel()

        let starting = Task { await model.start() }
        await indexed.untilArrived()
        try addCall("m2", to: "s2")
        await model.transcriptsChanged([transcript("s2")])
        await indexed.open()
        await applyingBacklog.untilArrived()
        try addCall("m3", to: "s3")
        await model.transcriptsChanged([transcript("s3")])
        await applyingBacklog.open()
        await starting.value

        #expect(model.phase == .ready)
        #expect(model.todayReport?.calls == 3)
    }

    // MEDIUM: Try Again during a start left the model ready but with no index behind it.
    @Test("trying again during a start leaves a working model")
    func retryDuringStart() async throws {
        try addCall("m1", to: "s1")
        let indexed = Gate()
        await index.holdIndexAll(at: indexed)
        let model = makeModel()

        let starting = Task { await model.start() }
        await indexed.untilArrived()
        await model.retry()
        await indexed.open()
        await starting.value

        #expect(model.phase == .ready)
        #expect(model.todayReport?.calls == 1)
    }

    // MEDIUM: one failed update stopped indexing until the user found the Try Again button.
    @Test("an index error clears itself when the next change applies")
    func errorClearsItself() async throws {
        struct Busy: Error {}
        try addCall("m1", to: "s1")
        let model = makeModel()
        await model.start()
        #expect(model.phase == .ready)

        await index.failNextUpdate(with: Busy())
        try addCall("m2", to: "s1")
        await model.transcriptsChanged([transcript("s1")])
        guard case .indexError = model.phase else {
            Issue.record("expected an index error, got \(model.phase)")
            return
        }

        try addCall("m3", to: "s1")
        await model.transcriptsChanged([transcript("s1")])

        #expect(model.phase == .ready)
        #expect(model.todayReport?.calls == 3)
    }

    // MEDIUM: damage found while running came back after every Try Again.
    @Test("a damaged index found while running is not retried on its own, and Try Again starts over")
    func damageStartsOver() async throws {
        try addCall("m1", to: "s1")
        let model = makeModel()
        await model.start()

        await index.failNextUpdate(with: SQLiteError(code: SQLITE_CORRUPT, message: "database disk image is malformed"))
        try addCall("m2", to: "s1")
        await model.transcriptsChanged([transcript("s1")])
        try addCall("m3", to: "s1")
        await model.transcriptsChanged([transcript("s1")])
        guard case .indexError = model.phase else {
            Issue.record("a damaged index must wait for Try Again, got \(model.phase)")
            return
        }

        await model.retry()

        #expect(openings.all == [.replaceUnusable, .startOver])
        #expect(model.phase == .ready)
    }

    // LOW: a notification whose time had already passed was scheduled for one second later.
    @Test("a notification time that passed since the last tick is not scheduled")
    func staleNowNotScheduled() async throws {
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_794_268_800 + 12 * 3600) }
        let clock = Clock()
        let at = Self.now.addingTimeInterval(-10 * 60).formatted(.iso8601)
        let line =
            #"{"type":"assistant","timestamp":"\#(at)","sessionId":"s1","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":10,"cache_creation_input_tokens":120000,"cache_creation":{"ephemeral_1h_input_tokens":120000,"ephemeral_5m_input_tokens":0}}}}"#
            + "\n"
        try FileManager.default.createDirectory(
            at: transcript("s1").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: transcript("s1"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data(#"{"pid":4242,"sessionId":"s1","status":"idle"}"#.utf8).write(
            to: dir.appendingPathComponent("sessions/4242.json"))
        let scheduler = FakeScheduler()
        let (index, openings) = (self.index, self.openings)
        let model = AppModel(
            environment: .init(
                root: dir.appendingPathComponent("projects"), database: dir.appendingPathComponent("index.sqlite"),
                sessions: dir.appendingPathComponent("sessions"), defaults: defaults, automaticUpdates: false),
            scheduler: scheduler, loginItem: FakeLoginItem(), urlOpener: FakeOpener(),
            registry: SessionRegistry(directory: dir.appendingPathComponent("sessions"), isAlive: { _, _ in true }),
            clock: { clock.now },
            openIndex: { _, _, opening in
                openings.append(opening)
                return index
            })
        await model.start()
        #expect(model.warnings.map(\.sessionID) == ["s1"])

        // The cache expires 50 minutes from now and the notification is 10 minutes before that. Time moves
        // past it with no tick, then notifications are turned on.
        clock.now = Self.now.addingTimeInterval(41 * 60)
        await model.update { $0.notifyBeforeExpiry = true }

        #expect(scheduler.added.isEmpty)
    }
}
