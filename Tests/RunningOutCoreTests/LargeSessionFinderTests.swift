import Foundation
import Testing

@testable import RunningOutCore

/// Opus 5.5 reads its cache at 200 thousandths of a USD per MTok, so a call re-reads 1 token for 200 nano-USD.
@Suite("LargeSessionFinder")
struct LargeSessionFinderTests {
    private let now: Double = 1_794_268_800

    private func running(_ id: String, _ status: RunningSession.Status = .idle, name: String? = nil) -> RunningSession {
        RunningSession(
            pid: 100, sessionID: id, name: name, status: status, statusSince: nil, cwd: "/work/\(id)-folder",
            processStart: nil)
    }

    private func last(
        _ id: String, context: Int = 250_000, model: String = "claude-opus-5-5", title: String? = nil,
        compactedAfter: Bool = false
    ) -> LastCall {
        LastCall(
            sessionID: id, file: URL(fileURLWithPath: "/p/\(id).jsonl"), timestamp: now - 60, ttl: .oneHour,
            model: model, contextTokens: context, title: title, compactedAfter: compactedAfter)
    }

    private func sessions(
        _ registry: RegistryState, _ calls: [LastCall], recent: [String] = []
    ) throws -> [LargeSession] {
        let byID = Dictionary(uniqueKeysWithValues: calls.map { ($0.sessionID, $0) })
        return try LargeSessionFinder.sessions(
            registry: registry, now: now, thresholdTokens: LargeSessionFinder.defaultThresholdTokens,
            prices: PriceTable.bundled(), lastCall: { byID[$0] },
            sessionsWithCallsSince: { since in
                #expect(since == now - 3600)
                return recent
            })
    }

    @Test("the threshold is 200,000 tokens, inclusive")
    func thresholdBoundary() throws {
        #expect(LargeSessionFinder.defaultThresholdTokens == 200_000)
        let found = try sessions(
            .available([running("below"), running("at")]),
            [last("below", context: 199_999), last("at", context: 200_000)])
        #expect(found.map(\.sessionID) == ["at"])
    }

    @Test("a busy session is listed too: the prompt can be pasted once its turn ends")
    func busySessionIncluded() throws {
        let found = try sessions(.available([running("s1", .busy)]), [last("s1")])
        #expect(found.map(\.status) == [.running])
    }

    @Test("a session opened by two processes is listed once")
    func duplicateSessionOnce() throws {
        let found = try sessions(.available([running("s1", .busy), running("s1", .idle)]), [last("s1")])
        #expect(found.map(\.sessionID) == ["s1"])
    }

    @Test("without the running-session files, sessions with a call in the last hour are listed as unreadable")
    func unreadableRegistryUsesRecentCalls() throws {
        let found = try sessions(.unavailable, [last("s1")], recent: ["s1"])
        #expect(found.map(\.sessionID) == ["s1"])
        #expect(found.map(\.status) == [.unreadable])
    }

    @Test("a session compacted after its last call is not listed")
    func compactedSessionExcluded() throws {
        #expect(try sessions(.available([running("s1")]), [last("s1", compactedAfter: true)]).isEmpty)
    }

    @Test("a running session without an indexed call is not listed")
    func sessionWithoutCallsHidden() throws {
        #expect(try sessions(.available([running("new")]), []).isEmpty)
    }

    @Test("each call re-reads the whole context at the cache-read price")
    func readCostIsContextTimesCacheRead() throws {
        let found = try sessions(.available([running("s1")]), [last("s1", context: 620_000, title: "Refactor parser")])
        #expect(
            found == [
                LargeSession(
                    sessionID: "s1", title: "Refactor parser", contextTokens: 620_000, readCost: 620_000 * 200,
                    model: "claude-opus-5-5", priced: true, status: .running)
            ])
    }

    @Test("a model missing from the price table is marked as estimated")
    func unpricedModelIsMarked() throws {
        let found = try sessions(.available([running("s1")]), [last("s1", model: "claude-unknown-9")])
        #expect(found.map(\.priced) == [false])
    }

    @Test("the largest context comes first, then by session ID")
    func sortedByContextThenID() throws {
        let found = try sessions(
            .available([running("b"), running("a"), running("c")]),
            [last("b", context: 300_000), last("a", context: 300_000), last("c", context: 900_000)])
        #expect(found.map(\.sessionID) == ["c", "a", "b"])
    }

    @Test("the title falls back to the running session's name, then its folder, like the warnings")
    func titleFallsBackLikeWarnings() throws {
        let named = try sessions(.available([running("s1", name: "my-session")]), [last("s1")])
        #expect(named.map(\.title) == ["my-session"])
        let folder = try sessions(.available([running("s2")]), [last("s2")])
        #expect(folder.map(\.title) == ["s2-folder"])
    }
}
