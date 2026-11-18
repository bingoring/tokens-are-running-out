import Foundation
import Testing

@testable import RunningOutCore

/// Expected prices come from https://platform.claude.com/docs/en/about-claude/pricing (2026-11-17),
/// in thousandths of a USD per million tokens. Costs are in nano-USD (tokens x that unit).
@Suite("PriceTable")
struct PriceTableTests {
    private func call(
        model: String = "claude-opus-5-5", input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0,
        write1h: Int = 0, write5m: Int = 0
    ) -> CallRecord {
        CallRecord(
            messageID: "m", timestamp: 0, model: model, version: nil, lineSessionID: nil, inputTokens: input,
            outputTokens: output, cacheReadTokens: read, cacheWriteTokens: write, cacheWrite1h: write1h,
            cacheWrite5m: write5m, ttl: nil)
    }

    @Test("the bundled table matches the official prices")
    func bundledPrices() throws {
        let table = try PriceTable.bundled()
        #expect(table.models.count == 21)
        #expect(
            table.models["claude-opus-5-5"]?.base
                == Prices(input: 4000, cacheWrite5m: 5000, cacheWrite1h: 8000, cacheRead: 200, output: 20000))
        #expect(table.models["claude-fable-5-2"]?.base.cacheRead == 200)
        #expect(table.models["claude-haiku-5-5"]?.longContext?.overPromptTokens == 100_000)
        #expect(table.models["claude-haiku-5-5"]?.longContext?.prices.input == 500)
    }

    @Test("a model id picks the longest matching key, so dated ids find their family")
    func longestPrefix() throws {
        let table = try PriceTable.bundled()
        #expect(table.lookup(model: "claude-opus-5-5", promptTokens: 0).prices.input == 4000)
        #expect(table.lookup(model: "claude-opus-5-20260101", promptTokens: 0).prices.input == 5000)
        #expect(table.lookup(model: "claude-sonnet-4-5-20250929", promptTokens: 0).prices.input == 3000)
        #expect(table.lookup(model: "claude-opus-5-5", promptTokens: 0).known)
    }

    @Test("a model missing from the table is priced as Claude Opus 5.5 and marked unknown")
    func unknownModel() throws {
        let found = try PriceTable.bundled().lookup(model: "claude-future-9", promptTokens: 0)
        #expect(!found.known)
        #expect(found.prices.input == 4000)
    }

    @Test("Claude Haiku 5.5 switches to long-context prices only above 100,000 prompt tokens")
    func haikuTier() throws {
        let table = try PriceTable.bundled()
        #expect(table.lookup(model: "claude-haiku-5-5", promptTokens: 100_000).prices.input == 100)
        #expect(table.lookup(model: "claude-haiku-5-5", promptTokens: 100_001).prices.input == 500)
        let long = table.cost(
            of: call(model: "claude-haiku-5-5", input: 1, read: 60_000, write: 40_000, write5m: 40_000))
        #expect(long.cacheWrite == 40_000 * 625)
    }

    @Test("a call's cost splits into cache write, everything else, and the write priced as a read")
    func callCost() throws {
        let cost = try PriceTable.bundled().cost(
            of: call(input: 2, output: 471, read: 43_567, write: 33_980, write1h: 33_980))
        #expect(cost.cacheWrite == 271_840_000)
        #expect(cost.other == 18_141_400)
        #expect(cost.writtenAsRead == 6_796_000)
        #expect(cost.total == 289_981_400)
        #expect(cost.known)
    }

    @Test("cache writes without a TTL breakdown are priced as one-hour writes")
    func missingBreakdown() throws {
        let cost = try PriceTable.bundled().cost(of: call(write: 1_000))
        #expect(cost.cacheWrite == 1_000 * 8000)
    }

    @Test("five-minute writes use the five-minute price")
    func fiveMinuteWrite() throws {
        let cost = try PriceTable.bundled().cost(of: call(model: "claude-sonnet-5-5", write: 1_000, write5m: 1_000))
        #expect(cost.cacheWrite == 1_000 * 2500)
    }

    @Test("a table with a negative or missing price is rejected")
    func invalidTable() {
        let negative = #"{"models":{"m":{"input":-1,"cache_write_5m":1,"cache_write_1h":1,"cache_read":1,"output":1}}}"#
        let missing = #"{"models":{"m":{"input":1,"cache_write_5m":1,"cache_write_1h":1,"cache_read":1}}}"#
        #expect(throws: (any Error).self) { try PriceTable(json: Data(negative.utf8)) }
        #expect(throws: (any Error).self) { try PriceTable(json: Data(missing.utf8)) }
    }

    @Test("each part is priced at its own model, so an advisor consult is charged at the advisor's prices")
    func partsPricedByModel() throws {
        var record = call(write: 60_000, write1h: 60_000)
        record.iterations = [
            UsagePart(cacheWriteTokens: 60_000, cacheWrite1h: 60_000),
            UsagePart(kind: .advisor, model: "claude-fable-5-2", inputTokens: 50_000, outputTokens: 800),
        ]
        let cost = try PriceTable.bundled().cost(of: record)
        // Opus 5.5 1h write 60,000 x 8000; Fable 5.2 input 50,000 x 8000 and output 800 x 40000.
        #expect(cost.cacheWrite == 480_000_000)
        #expect(cost.other == 400_000_000 + 32_000_000)
        #expect(cost.known)
    }

    @Test("writes beyond the TTL breakdown are priced as one-hour writes")
    func writesBeyondBreakdown() throws {
        let cost = try PriceTable.bundled().cost(of: call(write: 1_000, write5m: 400))
        #expect(cost.cacheWrite == 600 * 8000 + 400 * 5000)
    }

    @Test("the long-context tier is decided by each part's own prompt, not the call's sum")
    func tierPerPart() throws {
        var record = call(model: "claude-haiku-5-5", read: 120_000)
        record.iterations = [UsagePart(cacheReadTokens: 60_000), UsagePart(cacheReadTokens: 60_000)]
        #expect(try PriceTable.bundled().cost(of: record).other == 120_000 * 10)
    }

    @Test("a model id matches a key exactly or with a date suffix, so a new minor version is unpriced")
    func exactOrDated() throws {
        let table = try PriceTable.bundled()
        #expect(table.lookup(model: "claude-opus-5-5-20261201", promptTokens: 0).known)
        #expect(!table.lookup(model: "claude-opus-5-6", promptTokens: 0).known)
        #expect(!table.lookup(model: "claude-opus-5-5-fast", promptTokens: 0).known)
        #expect(!table.lookup(model: "claude-opus-5-202612", promptTokens: 0).known)
    }

    @Test("a table without the fallback model is rejected")
    func fallbackRequired() {
        let json =
            #"{"models":{"claude-x":{"input":1,"cache_write_5m":1,"cache_write_1h":1,"cache_read":1,"output":1}}}"#
        #expect(throws: PriceTableError.self) { try PriceTable(json: Data(json.utf8)) }
    }

    @Test("the embedded table is a verbatim copy of pricing.json, which the prototype reads")
    func embeddedMatchesFile() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RunningOutCore/Resources/pricing.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == PriceTable.embeddedJSON + "\n", "Run scripts/embed-pricing.py after editing pricing.json.")
    }
}
