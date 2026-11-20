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
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x",\
            "usage":{"service_tier":"standard"}}}
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

    @Test("an empty usage object or an empty id is not an API call (matches the prototype)")
    func emptyUsageOrID() {
        let emptyUsage =
            #"{"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x","usage":{}}}"#
        let emptyID =
            #"{"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"","model":"x","usage":{"output_tokens":1}}}"#
        #expect(parse(emptyUsage) == .assistantWithoutCall(timestamp: 1_794_268_800))
        #expect(parse(emptyID) == .assistantWithoutCall(timestamp: 1_794_268_800))
    }

    @Test("synthetic messages are not API calls")
    func syntheticRejected() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"<synthetic>","usage":{}}}
            """
        // A known record (an API error or limit reply), so it is not evidence of a format change either.
        #expect(parse(line) == .rejected)
    }

    @Test("an assistant line without usage is not a call even if the word appears in its text")
    func assistantWithoutUsage() {
        let line = """
            {"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x",\
            "content":[{"type":"text","text":"usage"}]}}
            """
        #expect(parse(line) == .assistantWithoutCall(timestamp: 1_794_268_800))
    }

    @Test("assistant lines missing an id or a timestamp are not calls")
    func missingIdentity() {
        let noID = #"{"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"model":"x","usage":{}}}"#
        let noTimestamp = #"{"type":"assistant","message":{"id":"m","model":"x","usage":{}}}"#
        #expect(parse(noID) == .assistantWithoutCall(timestamp: 1_794_268_800))
        #expect(parse(noTimestamp) == .assistantWithoutCall(timestamp: nil))
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

    // MARK: - Iterations (advisor consults and multi-step calls)

    @Test("each iteration becomes a usage part, and an advisor iteration keeps its own model")
    func iterationsBecomeParts() throws {
        let line = Fixture.call(
            id: "m1", at: "2026-11-10T00:00:00Z", input: 3, output: 30, read: 70_000, write: 60_300,
            iterations: [
                Fixture.iteration(input: 2, output: 10, write: 60_000),
                Fixture.iteration(type: "advisor_message", model: "claude-fable-5-2", input: 50_000, output: 800),
                Fixture.iteration(input: 1, output: 20, read: 70_000, write: 300),
            ])
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(
            call.parts == [
                UsagePart(inputTokens: 2, outputTokens: 10, cacheWriteTokens: 60_000, cacheWrite1h: 60_000),
                UsagePart(kind: .advisor, model: "claude-fable-5-2", inputTokens: 50_000, outputTokens: 800),
                UsagePart(
                    inputTokens: 1, outputTokens: 20, cacheReadTokens: 70_000, cacheWriteTokens: 300, cacheWrite1h: 300),
            ])
        // The top-level fields stay as recorded: they leave out the advisor's input and output.
        #expect(call.inputTokens == 3)
        #expect(call.outputTokens == 30)
    }

    @Test("the context size is the prompt of the last main-model step, not a trailing advisor step or the first step")
    func contextFromLastModelStep() {
        let line = Fixture.call(
            id: "m1", at: "2026-11-10T00:00:00Z", input: 3, output: 30, read: 70_000, write: 60_300,
            iterations: [
                Fixture.iteration(input: 2, output: 10, write: 60_000),
                Fixture.iteration(input: 1, output: 20, read: 70_000, write: 300),
                Fixture.iteration(type: "advisor_message", model: "claude-fable-5-2", input: 50_000, output: 800),
            ])
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.contextTokens == 1 + 70_000 + 300)
    }

    @Test("a single iteration that repeats the top-level usage adds nothing")
    func singleIterationIsTopLevel() {
        let line = Fixture.call(
            id: "m1", at: "2026-11-10T00:00:00Z", input: 2, output: 10, write: 100,
            iterations: [Fixture.iteration(input: 2, output: 10, write: 100)])
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.iterations.isEmpty)
        #expect(call.parts == [UsagePart(inputTokens: 2, outputTokens: 10, cacheWriteTokens: 100, cacheWrite1h: 100)])
    }

    @Test("an iterations field of another shape is ignored and the top-level usage is used")
    func oddIterationsIgnored() {
        let line = Fixture.call(id: "m1", at: "2026-11-10T00:00:00Z", output: 10)
            .replacingOccurrences(of: #""cache_creation":{"#, with: #""iterations":"x","cache_creation":{"#)
        guard case .call(let call) = parse(line) else {
            Issue.record("expected a call")
            return
        }
        #expect(call.parts == [UsagePart(inputTokens: 2, outputTokens: 10)])
    }

    @Test("a call with more than 1,000 iterations is malformed; 1,000 is still a call")
    func iterationLimit() {
        let at = "2026-11-10T00:00:00Z"
        let steps = Array(repeating: Fixture.iteration(input: 1, output: 1), count: 1_001)
        guard case .call(let call) = parse(Fixture.call(id: "m1", at: at, iterations: Array(steps.dropLast()))) else {
            Issue.record("1,000 iterations are still a call")
            return
        }
        #expect(call.iterations.count == 1_000)
        #expect(parse(Fixture.call(id: "m1", at: at, iterations: steps)) == .malformed)
    }

    @Test("a token count below zero or above one billion makes the line malformed, so one call's cost fits in Int64")
    func tokenLimits() {
        let at = "2026-11-10T00:00:00Z"
        #expect(parse(Fixture.call(id: "m1", at: at, input: -1)) == .malformed)
        #expect(parse(Fixture.call(id: "m1", at: at, output: 1_000_000_001)) == .malformed)
        #expect(
            parse(Fixture.call(id: "m1", at: at, iterations: [Fixture.iteration(input: 2_000_000_000)])) == .malformed)
        guard case .call = parse(Fixture.call(id: "m1", at: at, output: 1_000_000_000)) else {
            Issue.record("one billion is still a valid count")
            return
        }
    }

    @Test("an assistant line whose usage field was renamed is still seen, so a format change can be noticed")
    func renamedUsage() {
        let line =
            #"{"type":"assistant","timestamp":"2026-11-10T00:00:00Z","message":{"id":"m","model":"x","usage_v2":{}}}"#
        #expect(parse(line) == .assistantWithoutCall(timestamp: 1_794_268_800))
    }

    @Test("a user line that only mentions the word assistant is not a call and not an assistant line")
    func userMentionsAssistant() {
        #expect(parse(#"{"type":"user","message":{"role":"user","content":"ask the \"assistant\""}}"#) == .notCandidate)
        #expect(parse(#"{"type":"user","message":{"role":"assistant","content":"hi"}}"#) == .rejected)
    }
}
