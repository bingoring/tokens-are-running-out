import Foundation
import Testing

@testable import RunningOutCore

/// Expected costs from the official prices: Opus 5.5 1h write 8000, 5m write 5000 (thousandths of a USD per MTok).
@Suite("ExpiryCalculator")
struct ExpiryCalculatorTests {
    private let now: Double = 1_794_268_800

    private func running(_ id: String, _ status: RunningSession.Status = .idle, name: String? = nil) -> RunningSession {
        RunningSession(
            pid: 100, sessionID: id, name: name, status: status, statusSince: nil, cwd: "/work/\(id)-folder",
            processStart: nil)
    }

    private func last(
        _ id: String, ago: Double, ttl: CacheTTL = .oneHour, context: Int = 120_000, model: String = "claude-opus-5-5",
        title: String? = nil, compactedAfter: Bool = false
    ) -> LastCall {
        LastCall(
            sessionID: id, file: URL(fileURLWithPath: "/p/\(id).jsonl"), timestamp: now - ago, ttl: ttl, model: model,
            contextTokens: context, title: title, compactedAfter: compactedAfter)
    }

    private func warnings(
        _ registry: RegistryState, _ calls: [LastCall], threshold: Int = 100_000, recent: [String] = []
    ) throws -> [ExpiryWarning] {
        let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.sessionID, $0) })
        return try ExpiryCalculator.warnings(
            registry: registry, now: now, warningContextTokens: threshold, prices: PriceTable.bundled(),
            lastCall: { byID[$0] },
            sessionsWithCallsSince: { since in
                #expect(since == now - 3600)
                return recent
            })
    }

    @Test("a session compacted after its last call gets no warning: the next message rebuilds only the summary")
    func compactedSessionHasNoWarning() throws {
        let found = try warnings(
            .available([running("s1")]), [last("s1", ago: 600, context: 620_000, compactedAfter: true)])
        #expect(found.isEmpty)
    }

    @Test("an idle session with a large context gets a warning with its expiry and rebuild cost")
    func idleWarning() throws {
        let found = try warnings(.available([running("s1")]), [last("s1", ago: 600, title: "Refactor parser")])
        #expect(
            found == [
                ExpiryWarning(
                    sessionID: "s1", title: "Refactor parser", expiresAt: now + 3000, ttl: .oneHour,
                    contextTokens: 120_000, rebuildCost: 120_000 * 8000, model: "claude-opus-5-5", priced: true,
                    status: .idle)
            ])
    }

    @Test("busy sessions, small contexts and expired caches get no warning")
    func exclusions() throws {
        let registry = RegistryState.available([
            running("busy", .busy), running("small"), running("gone"), running("edge"),
        ])
        let calls = [
            last("busy", ago: 60), last("small", ago: 60, context: 99_999), last("gone", ago: 3700),
            last("edge", ago: 3600),
        ]
        #expect(try warnings(registry, calls).isEmpty)
        #expect(try warnings(.available([running("small")]), [last("small", ago: 60, context: 100_000)]).count == 1)
    }

    @Test("an unknown status still warns, marked as not confirmed")
    func unknownStatus() throws {
        let found = try warnings(.available([running("s1", .other)]), [last("s1", ago: 60)])
        #expect(found.map(\.status) == [.unknownStatus])
    }

    @Test("without running-session files, recent main sessions warn as not confirmed")
    func unavailableRegistry() throws {
        let found = try warnings(.unavailable, [last("s1", ago: 60), last("s2", ago: 120)], recent: ["s1", "s2"])
        #expect(found.map(\.sessionID) == ["s2", "s1"])
        #expect(found.allSatisfy { $0.status == .unreadable })
    }

    @Test("the title falls back to the session name, then the folder name")
    func titleFallback() throws {
        let found = try warnings(
            .available([running("a", name: "Named session"), running("b")]), [last("a", ago: 60), last("b", ago: 90)])
        #expect(found.map(\.title) == ["b-folder", "Named session"])
    }

    @Test("a five-minute cache expires five minutes after the call and is priced as a five-minute write")
    func fiveMinute() throws {
        let found = try warnings(.available([running("s1")]), [last("s1", ago: 60, ttl: .fiveMinutes)])
        #expect(found.first?.expiresAt == now + 240)
        #expect(found.first?.rebuildCost == 120_000 * 5000)
    }

    @Test("a model missing from the price table is priced as the fallback and marked")
    func unpricedModel() throws {
        let found = try warnings(.available([running("s1")]), [last("s1", ago: 60, model: "claude-future-9")])
        #expect(found.first?.priced == false)
        #expect(found.first?.rebuildCost == 120_000 * 8000)
    }

    @Test("two processes on one session give one warning, preferring the idle one")
    func duplicateSessions() throws {
        var other = running("s1", .other)
        other.pid = 101
        let found = try warnings(.available([other, running("s1")]), [last("s1", ago: 60)])
        #expect(found.map(\.status) == [.idle])
    }

    @Test("a session waiting for the user makes no calls, so it is warned like an idle one")
    func waitingSession() throws {
        let found = try warnings(.available([running("s1", .waiting)]), [last("s1", ago: 60)])
        #expect(found.map(\.status) == [.idle])
    }
}
