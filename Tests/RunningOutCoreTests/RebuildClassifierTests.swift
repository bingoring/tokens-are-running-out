import Foundation
import Testing

@testable import RunningOutCore

@Suite("RebuildClassifier")
struct RebuildClassifierTests {
    private var seq = 0

    /// A call event. `write` defaults to a rebuild-sized write with nothing read.
    private mutating func call(
        _ id: String, at ts: Double, model: String = "claude-opus-5-5", version: String = "2.1.325",
        read: Int = 0, write: Int = 60_000, ttl: CacheTTL? = .oneHour, owned: Bool = true,
        iterations: [UsagePart] = []
    ) -> TimelineEvent {
        defer { seq += 1 }
        let record = CallRecord(
            messageID: id, timestamp: ts, model: model, version: version, lineSessionID: nil, inputTokens: 2,
            outputTokens: 10, cacheReadTokens: read, cacheWriteTokens: write,
            cacheWrite1h: ttl == .oneHour ? write : 0, cacheWrite5m: ttl == .fiveMinutes ? write : 0, ttl: ttl,
            iterations: iterations)
        return TimelineEvent(seq: seq, kind: .call(record, owned: owned))
    }

    private mutating func compaction(at ts: Double) -> TimelineEvent {
        defer { seq += 1 }
        return TimelineEvent(seq: seq, kind: .compaction(timestamp: ts))
    }

    /// Causes of the classified rebuilds, by message id. Non-rebuilds map to "-".
    private func causes(_ events: [TimelineEvent], kind: TranscriptKind = .main, from: Double = 0, to: Double = 1e12)
        -> [String: String]
    {
        var result: [String: String] = [:]
        for c in RebuildClassifier.classify(events, kind: kind, from: from, to: to) {
            result[c.call.messageID] = c.isRebuild ? (c.cause?.rawValue ?? "rebuild") : "-"
        }
        return result
    }

    @Test("a rebuild is a write of at least 50,000 tokens that is larger than what was read")
    mutating func rebuildThreshold() {
        let events = [
            call("a", at: 0, read: 0, write: 50_000),
            call("b", at: 10, read: 0, write: 49_999),
            call("c", at: 20, read: 60_000, write: 60_000),
            call("d", at: 30, read: 60_000, write: 60_001),
        ]
        let found = causes(events)
        #expect(found["a"] == "sessionStart")
        #expect(found["b"] == "-")
        #expect(found["c"] == "-")
        #expect(found["d"] == "unknown")
    }

    @Test("a compaction mark makes the next call's rebuild 'after compaction', and only that call")
    mutating func compactionOnlyForNextCall() {
        var events = [call("a", at: 0)]
        events.append(compaction(at: 100))
        events.append(call("b", at: 200))
        events.append(compaction(at: 300))
        events.append(call("c", at: 400, read: 70_000, write: 100))
        events.append(call("d", at: 500))
        let found = causes(events)
        #expect(found["b"] == "afterCompaction")
        #expect(found["c"] == "-")
        #expect(found["d"] == "unknown")
    }

    @Test("a model change wins over an expired cache")
    mutating func modelChangeFirst() {
        let events = [call("a", at: 0), call("b", at: 10_000, model: "claude-fable-5-2")]
        #expect(causes(events)["b"] == "modelChanged")
    }

    @Test("the cache expires only when the gap is longer than the previous call's TTL")
    mutating func ttlBoundary() {
        let atLimit = [call("a", at: 0), call("b", at: 3_600)]
        let pastLimit = [call("c", at: 0), call("d", at: 3_601)]
        #expect(causes(atLimit)["b"] == "unknown")
        #expect(causes(pastLimit)["d"] == "expiredShortBreak")
    }

    @Test("a break of up to three hours is short, anything longer is long")
    mutating func breakBoundary() {
        let short = [call("a", at: 0), call("b", at: 10_800)]
        let long = [call("c", at: 0), call("d", at: 10_801)]
        #expect(causes(short)["b"] == "expiredShortBreak")
        #expect(causes(long)["d"] == "expiredLongBreak")
    }

    @Test("a five-minute TTL expires after five minutes")
    mutating func fiveMinuteTTL() {
        let events = [call("a", at: 0, ttl: .fiveMinutes), call("b", at: 360, ttl: .fiveMinutes)]
        #expect(causes(events)["b"] == "expiredShortBreak")
    }

    @Test("a call without a TTL inherits the last TTL seen in the file, else the main default of one hour")
    mutating func ttlFallback() {
        let inherited = [
            call("a", at: 0, write: 100, ttl: .fiveMinutes), call("b", at: 10, read: 70_000, write: 0, ttl: nil),
            call("c", at: 400),
        ]
        let defaulted = [call("d", at: 0, write: 0, ttl: nil), call("e", at: 400)]
        #expect(causes(inherited)["c"] == "expiredShortBreak")
        #expect(causes(defaulted)["e"] == "unknown")
    }

    @Test("an update between calls is the cause when nothing else explains the rebuild")
    mutating func versionChanged() {
        let events = [call("a", at: 0), call("b", at: 60, version: "2.1.326")]
        #expect(causes(events)["b"] == "versionChanged")
    }

    @Test("copied calls and calls outside the window are not reported but still give context")
    mutating func contextFromUnreportedCalls() {
        let events = [
            call("copied", at: 0, owned: false),
            call("early", at: 50, read: 70_000, write: 100),
            call("inWindow", at: 20_000),
        ]
        let classified = RebuildClassifier.classify(events, kind: .main, from: 10_000, to: 30_000)
        #expect(classified.map(\.call.messageID) == ["inWindow"])
        #expect(classified.first?.cause == .expiredLongBreak)
        #expect(classified.first?.previous?.messageID == "early")
        #expect(classified.first?.previousTTL == .oneHour)
    }

    @Test("subagent rebuilds are counted without a cause")
    mutating func subagentNoCause() {
        let events = [call("a", at: 0, ttl: .fiveMinutes), call("b", at: 10_000, ttl: .fiveMinutes)]
        let classified = RebuildClassifier.classify(events, kind: .subagent, from: 0, to: 1e12)
        #expect(classified.map(\.isRebuild) == [true, true])
        #expect(classified.allSatisfy { $0.cause == nil })
    }

    @Test("a call rebuilds when one of its iterations does, even if a later iteration reads the cache back")
    mutating func rebuildPerIteration() {
        let events = [
            call(
                "a", at: 0, read: 70_000, write: 60_300,
                iterations: [
                    UsagePart(cacheWriteTokens: 60_000, cacheWrite1h: 60_000),
                    UsagePart(cacheReadTokens: 70_000, cacheWriteTokens: 300, cacheWrite1h: 300),
                ])
        ]
        #expect(causes(events)["a"] == "sessionStart")
    }

    @Test("an advisor iteration never makes a rebuild")
    mutating func advisorNeverRebuilds() {
        let events = [
            call(
                "a", at: 0, write: 0,
                iterations: [
                    UsagePart(inputTokens: 2),
                    UsagePart(kind: .advisor, model: "claude-fable-5-2", cacheWriteTokens: 60_000),
                ])
        ]
        #expect(causes(events)["a"] == "-")
    }

    @Test("a compaction outranks a model change")
    mutating func compactionBeforeModelChange() {
        var events = [call("a", at: 0)]
        events.append(compaction(at: 5))
        events.append(call("b", at: 10, model: "claude-fable-5-2"))
        #expect(causes(events)["b"] == "afterCompaction")
    }

    @Test("an expired cache outranks a version change")
    mutating func expiryBeforeVersionChange() {
        let events = [call("a", at: 0, version: "2.1.1"), call("b", at: 3_601, version: "2.1.2")]
        #expect(causes(events)["b"] == "expiredShortBreak")
    }

    @Test("the window includes its start and excludes its end")
    mutating func windowBounds() {
        let events = [call("a", at: 100), call("b", at: 200)]
        let found = causes(events, from: 100, to: 200)
        #expect(found["a"] == "sessionStart")
        #expect(found["b"] == nil)
    }

    @Test("the rebuild threshold can be set per classification")
    mutating func thresholdParameter() {
        let events = [call("a", at: 0, write: 40_000)]
        #expect(
            RebuildClassifier.classify(events, kind: .main, from: 0, to: 1e12, threshold: 30_000).first?.isRebuild
                == true)
        #expect(RebuildClassifier.classify(events, kind: .main, from: 0, to: 1e12).first?.isRebuild == false)
    }
}
