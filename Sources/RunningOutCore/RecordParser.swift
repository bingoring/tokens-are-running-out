import Foundation

public enum CacheTTL: String, Sendable, Equatable {
    case oneHour = "1h"
    case fiveMinutes = "5m"
}

/// The usage of one sampling step inside a call (`usage.iterations`). An advisor consult is a step of its own,
/// run on its own model.
public struct UsagePart: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable {
        case message
        case advisor
    }

    public var kind: Kind
    /// The model of this step; nil means the call's model.
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var cacheWrite1h: Int
    public var cacheWrite5m: Int

    public init(
        kind: Kind = .message, model: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0,
        cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, cacheWrite1h: Int = 0, cacheWrite5m: Int = 0
    ) {
        self.kind = kind
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWrite1h = cacheWrite1h
        self.cacheWrite5m = cacheWrite5m
    }
}

/// One API call as recorded in a transcript line.
public struct CallRecord: Sendable, Equatable {
    public var messageID: String
    public var timestamp: Double
    public var model: String
    public var version: String?
    public var lineSessionID: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var cacheWrite1h: Int
    public var cacheWrite5m: Int
    public var ttl: CacheTTL?
    /// The steps of the call, each priced at its own model. Empty when the call is a single step that the
    /// top-level fields already describe.
    public var iterations: [UsagePart] = []

    public init(
        messageID: String, timestamp: Double, model: String, version: String?, lineSessionID: String?,
        inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, cacheWrite1h: Int,
        cacheWrite5m: Int, ttl: CacheTTL?, iterations: [UsagePart] = []
    ) {
        self.messageID = messageID
        self.timestamp = timestamp
        self.model = model
        self.version = version
        self.lineSessionID = lineSessionID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWrite1h = cacheWrite1h
        self.cacheWrite5m = cacheWrite5m
        self.ttl = ttl
        self.iterations = iterations
    }

    /// The top-level fields as one step. They cover the call's own model only: Claude Code leaves an advisor
    /// consult's input and output out of them, and keeps the TTL breakdown of the first step only.
    public var topLevel: UsagePart {
        UsagePart(
            inputTokens: inputTokens, outputTokens: outputTokens, cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens, cacheWrite1h: cacheWrite1h, cacheWrite5m: cacheWrite5m)
    }

    /// What was used and billed, step by step.
    public var parts: [UsagePart] { iterations.isEmpty ? [topLevel] : iterations }

    /// The prompt of the call's last main-model step: what the cache holds after this call.
    public var contextTokens: Int {
        let last = parts.last { $0.kind == .message } ?? topLevel
        return last.inputTokens + last.cacheReadTokens + last.cacheWriteTokens
    }
}

public enum ParsedLine: Sendable, Equatable {
    /// The line cannot hold anything the index uses (rule R1).
    case notCandidate
    case call(CallRecord)
    case compaction(timestamp: Double?)
    case title(sessionID: String, title: String)
    /// A top-level assistant record that is not an API call: a synthetic message, or a record whose shape
    /// changed. Counted to notice a format change (2-3 BR-I4).
    case assistantWithoutCall(timestamp: Double?)
    /// A candidate that turned out not to be a call, mark or title (rule R2).
    case rejected
    /// A candidate whose JSON could not be decoded (rule R3).
    case malformed
}

public enum RecordParser {
    private static let compactMarker = Data(#""compact_boundary""#.utf8)
    private static let titleMarker = Data(#""custom-title""#.utf8)
    private static let assistantMarker = Data(#""assistant""#.utf8)

    public static func parse(_ line: Data) -> ParsedLine {
        // R1: decode only lines that can hold something the index uses. Assistant records are decoded even
        // without a usage field, so one that lost it is noticed (2-3 BR-I4).
        let maybeCall = line.range(of: assistantMarker) != nil
        let maybeCompaction = line.range(of: compactMarker) != nil
        let maybeTitle = line.range(of: titleMarker) != nil
        guard maybeCall || maybeCompaction || maybeTitle else { return .notCandidate }

        // R3: a candidate that does not decode is counted, never fatal.
        guard let raw = try? JSONDecoder().decode(RawLine.self, from: line) else { return .malformed }

        // The markers can also appear inside message text, so the record type decides.
        switch raw.type {
        case "system" where raw.subtype == "compact_boundary":
            return .compaction(timestamp: raw.timestamp.flatMap(Timestamp.parse))
        case "custom-title":
            guard let sessionID = raw.sessionId, let title = raw.customTitle else { return .rejected }
            return .title(sessionID: sessionID, title: title)
        case "assistant":
            return call(from: raw)
        default:
            return .rejected
        }
    }

    /// Token counts above this are not real usage. With `iterationLimit` it keeps one call's cost far inside Int64
    /// (about 1.2e17 nano-USD at the highest list price); sums over many calls saturate in `UsageAnalyzer` instead.
    static let tokenLimit = 1_000_000_000
    /// More steps than this in one call are not real usage, and the call is dropped as malformed.
    static let iterationLimit = 1_000

    /// R2: only real API calls with an id, a timestamp and usage.
    private static func call(from raw: RawLine) -> ParsedLine {
        // Matches the prototype oracle: an empty usage object or an empty id is not a call.
        // Synthetic messages (API errors, limit replies) are known records, not a sign of a format change.
        if raw.message?.model == "<synthetic>" { return .rejected }
        guard let message = raw.message, let usage = message.usage, usage.keyCount > 0,
            let id = message.id, !id.isEmpty, let model = message.model, !model.isEmpty,
            let timestamp = raw.timestamp.flatMap(Timestamp.parse)
        else { return .assistantWithoutCall(timestamp: raw.timestamp.flatMap(Timestamp.parse)) }

        guard (usage.iterations?.count ?? 0) <= iterationLimit else { return .malformed }
        let top = part(
            usage.input_tokens, usage.output_tokens, usage.cache_read_input_tokens, usage.cache_creation_input_tokens,
            usage.cache_creation)
        var iterations = (usage.iterations ?? []).map { step in
            var result = part(
                step.input_tokens, step.output_tokens, step.cache_read_input_tokens, step.cache_creation_input_tokens,
                step.cache_creation)
            result.kind = step.type == "advisor_message" ? .advisor : .message
            result.model = step.model == model ? nil : step.model
            return result
        }
        let counts = ([top] + iterations).flatMap {
            [
                $0.inputTokens, $0.outputTokens, $0.cacheReadTokens, $0.cacheWriteTokens, $0.cacheWrite1h,
                $0.cacheWrite5m,
            ]
        }
        guard counts.allSatisfy({ (0...tokenLimit).contains($0) }) else { return .malformed }
        if iterations == [top] { iterations = [] }

        let ttl: CacheTTL? = top.cacheWrite1h > 0 ? .oneHour : (top.cacheWrite5m > 0 ? .fiveMinutes : nil)
        return .call(
            CallRecord(
                messageID: id, timestamp: timestamp, model: model, version: raw.version,
                lineSessionID: raw.sessionId, inputTokens: top.inputTokens, outputTokens: top.outputTokens,
                cacheReadTokens: top.cacheReadTokens, cacheWriteTokens: top.cacheWriteTokens,
                cacheWrite1h: top.cacheWrite1h, cacheWrite5m: top.cacheWrite5m, ttl: ttl, iterations: iterations))
    }

    private static func part(
        _ input: Int?, _ output: Int?, _ read: Int?, _ write: Int?, _ breakdown: RawCacheCreation?
    ) -> UsagePart {
        UsagePart(
            inputTokens: input ?? 0, outputTokens: output ?? 0, cacheReadTokens: read ?? 0,
            cacheWriteTokens: write ?? 0, cacheWrite1h: breakdown?.ephemeral_1h_input_tokens ?? 0,
            cacheWrite5m: breakdown?.ephemeral_5m_input_tokens ?? 0)
    }
}

enum Timestamp {
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle()

    /// Parses an ISO 8601 UTC timestamp into seconds since 1970.
    static func parse(_ text: String) -> Double? {
        if let date = try? fractional.parse(text) { return date.timeIntervalSince1970 }
        if let date = try? whole.parse(text) { return date.timeIntervalSince1970 }
        return nil
    }
}

// The transcript's own key names, so the decoder needs no key mapping.
// swift-format-ignore: AlwaysUseLowerCamelCase
private struct RawLine: Decodable {
    var type: String?
    var subtype: String?
    var timestamp: String?
    var sessionId: String?
    var version: String?
    var customTitle: String?
    var message: RawMessage?

    enum CodingKeys: String, CodingKey {
        case type, subtype, timestamp, sessionId, version, customTitle, message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        subtype = try? c.decodeIfPresent(String.self, forKey: .subtype)
        timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        customTitle = try? c.decodeIfPresent(String.self, forKey: .customTitle)
        // `message` is an object for assistant lines but can be other shapes elsewhere.
        message = try? c.decodeIfPresent(RawMessage.self, forKey: .message)
    }
}

private struct RawMessage: Decodable {
    var id: String?
    var model: String?
    var usage: RawUsage?
}

// swift-format-ignore: AlwaysUseLowerCamelCase
private struct RawUsage: Decodable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_read_input_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_creation: RawCacheCreation?
    var iterations: [RawIteration]?
    /// How many keys the usage object had, known or not.
    var keyCount = 0

    enum CodingKeys: String, CodingKey {
        case input_tokens, output_tokens, cache_read_input_tokens, cache_creation_input_tokens, cache_creation
        case iterations
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        keyCount = try decoder.container(keyedBy: AnyKey.self).allKeys.count
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input_tokens = try c.decodeIfPresent(Int.self, forKey: .input_tokens)
        output_tokens = try c.decodeIfPresent(Int.self, forKey: .output_tokens)
        cache_read_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cache_read_input_tokens)
        cache_creation_input_tokens = try c.decodeIfPresent(Int.self, forKey: .cache_creation_input_tokens)
        cache_creation = try c.decodeIfPresent(RawCacheCreation.self, forKey: .cache_creation)
        // A newer field: when its shape is not the expected one, the top-level fields are used instead.
        iterations = try? c.decodeIfPresent([RawIteration].self, forKey: .iterations)
    }
}

// swift-format-ignore: AlwaysUseLowerCamelCase
private struct RawIteration: Decodable {
    var type: String?
    var model: String?
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_read_input_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_creation: RawCacheCreation?
}

// swift-format-ignore: AlwaysUseLowerCamelCase
private struct RawCacheCreation: Decodable {
    var ephemeral_1h_input_tokens: Int?
    var ephemeral_5m_input_tokens: Int?
}
