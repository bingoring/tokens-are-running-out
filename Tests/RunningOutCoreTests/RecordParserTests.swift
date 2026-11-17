import Foundation
import Testing

@testable import RunningOutCore

@Suite("RecordParser")
struct RecordParserTests {
    private func parse(_ json: String) -> ParsedLine {
        RecordParser.parse(Data(json.utf8))
    }

    @Test("an assistant line with usage becomes a call with every token field")
    func callWithOneHourCache() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-13T05:48:21.499Z","sessionId":"s-1","version":"2.1.325",\
            "message":{"id":"msg_A","model":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":471,\
            "cache_read_input_tokens":43567,"cache_creation_input_tokens":33980,\
            "cache_creation":{"ephemeral_1h_input_tokens":33980,"ephemeral_5m_input_tokens":0}}}}
            """
        let expected = CallRecord(
            messageID: "msg_A", timestamp: 1_794_548_901.499, model: "claude-opus-5-5", version: "2.1.325",
            lineSessionID: "s-1", inputTokens: 2, outputTokens: 471, cacheReadTokens: 43567,
            cacheWriteTokens: 33980, cacheWrite1h: 33980, cacheWrite5m: 0, ttl: .oneHour)
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.messageID == expected.messageID)
        #expect(abs(call.timestamp - expected.timestamp) < 0.001)
        #expect(call.model == expected.model)
        #expect(call.version == expected.version)
        #expect(call.lineSessionID == expected.lineSessionID)
        #expect(call.inputTokens == 2)
        #expect(call.outputTokens == 471)
        #expect(call.cacheReadTokens == 43567)
        #expect(call.cacheWriteTokens == 33980)
        #expect(call.cacheWrite1h == 33980)
        #expect(call.cacheWrite5m == 0)
        #expect(call.ttl == .oneHour)
    }

    @Test("a five-minute cache write sets the TTL to five minutes")
    func fiveMinuteTTL() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x",\
            "usage":{"cache_creation_input_tokens":10,"cache_creation":{"ephemeral_1h_input_tokens":0,\
            "ephemeral_5m_input_tokens":10}}}}
            """
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.ttl == .fiveMinutes)
        #expect(call.cacheWrite5m == 10)
        #expect(call.timestamp == 1_794_268_800)
    }

    @Test("missing token fields and cache details default to zero with no TTL")
    func missingFieldsDefaultToZero() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x","usage":{}}}
            """
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.inputTokens == 0)
        #expect(call.cacheWriteTokens == 0)
        #expect(call.ttl == nil)
        #expect(call.version == nil)
    }

    @Test("synthetic messages are not API calls")
    func syntheticRejected() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"<synthetic>","usage":{}}}
            """
        #expect(parse(line) == .rejected)
    }

    @Test("an assistant line without usage is rejected even if the word appears in its text")
    func assistantWithoutUsage() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x",\
            "content":[{"type":"text","text":"usage"}]}}
            """
        #expect(parse(line) == .rejected)
    }

    @Test("lines missing an id or a timestamp are rejected")
    func missingIdentity() {
        let noID = #"{"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"model":"x","usage":{}}}"#
        let noTimestamp = #"{"type":"assistant","message":{"id":"m","model":"x","usage":{}}}"#
        #expect(parse(noID) == .rejected)
        #expect(parse(noTimestamp) == .rejected)
    }

    @Test("other record types that echo assistant usage are rejected")
    func echoRejected() {
        let line = #"{"type":"api-request-blob","blob":{"messages":[{"role":"assistant","usage":{}}]}}"#
        #expect(parse(line) == .rejected)
    }

    @Test("a candidate line with broken JSON is malformed")
    func malformed() {
        #expect(parse(#"{"type":"assistant","usage": {"#) == .malformed)
    }

    @Test("a compact boundary record becomes a compaction mark")
    func compaction() {
        let line = #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-10T00:00:00Z"}"#
        #expect(parse(line) == .compaction(timestamp: 1_794_268_800))
    }

    @Test("a call whose text mentions compact_boundary is still a call")
    func mentionIsNotCompaction() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x",\
            "content":[{"type":"text","text":"compact_boundary"}],"usage":{"output_tokens":1}}}
            """
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.outputTokens == 1)
    }

    @Test("a custom title record becomes a title")
    func title() {
        let line = #"{"type":"custom-title","customTitle":"결제 화면 개편","sessionId":"s-1"}"#
        #expect(parse(line) == .title(sessionID: "s-1", title: "결제 화면 개편"))
    }

    @Test("ordinary lines are not candidates")
    func notCandidate() {
        #expect(parse(#"{"type":"user","message":{"role":"user","content":"hi"}}"#) == .notCandidate)
    }
}
