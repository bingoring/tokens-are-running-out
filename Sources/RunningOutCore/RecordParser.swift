import Foundation

public enum CacheTTL: String, Sendable, Equatable {
    case oneHour = "1h"
    case fiveMinutes = "5m"
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
}

public enum ParsedLine: Sendable, Equatable {
    /// The line cannot hold anything the index uses (rule R1).
    case notCandidate
    case call(CallRecord)
    case compaction(timestamp: Double?)
    case title(sessionID: String, title: String)
    /// A candidate that turned out not to be a call, mark or title (rule R2).
    case rejected
    /// A candidate whose JSON could not be decoded (rule R3).
    case malformed
}

public enum RecordParser {
    private static let compactMarker = Data(#""compact_boundary""#.utf8)
    private static let titleMarker = Data(#""custom-title""#.utf8)
    private static let assistantMarker = Data(#""assistant""#.utf8)
    private static let usageMarker = Data(#""usage""#.utf8)

    public static func parse(_ line: Data) -> ParsedLine {
        // R1: decode only lines that can hold something the index uses.
        let maybeCall = line.range(of: assistantMarker) != nil && line.range(of: usageMarker) != nil
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
            return call(from: raw).map(ParsedLine.call) ?? .rejected
        default:
            return .rejected
        }
    }

    /// R2: only real API calls with an id, a timestamp and usage.
    private static func call(from raw: RawLine) -> CallRecord? {
        guard let message = raw.message, let usage = message.usage,
            let id = message.id, let model = message.model, model != "<synthetic>",
            let timestamp = raw.timestamp.flatMap(Timestamp.parse)
        else { return nil }

        let write1h = usage.cache_creation?.ephemeral_1h_input_tokens ?? 0
        let write5m = usage.cache_creation?.ephemeral_5m_input_tokens ?? 0
        let ttl: CacheTTL? = write1h > 0 ? .oneHour : (write5m > 0 ? .fiveMinutes : nil)
        return CallRecord(
            messageID: id, timestamp: timestamp, model: model, version: raw.version,
            lineSessionID: raw.sessionId,
            inputTokens: usage.input_tokens ?? 0, outputTokens: usage.output_tokens ?? 0,
            cacheReadTokens: usage.cache_read_input_tokens ?? 0,
            cacheWriteTokens: usage.cache_creation_input_tokens ?? 0,
            cacheWrite1h: write1h, cacheWrite5m: write5m, ttl: ttl)
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
}

// swift-format-ignore: AlwaysUseLowerCamelCase
private struct RawCacheCreation: Decodable {
    var ephemeral_1h_input_tokens: Int?
    var ephemeral_5m_input_tokens: Int?
}
