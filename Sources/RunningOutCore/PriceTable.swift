import Foundation

/// Prices in thousandths of a USD per million tokens, so every official price is a whole number
/// ($0.125 -> 125) and costs add up exactly in any order.
public struct Prices: Sendable, Equatable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int

    public init(input: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int, output: Int) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead
        self.output = output
    }
}

public struct ModelPricing: Sendable, Equatable {
    public struct LongContext: Sendable, Equatable {
        public var overPromptTokens: Int
        public var prices: Prices
    }

    public var base: Prices
    public var longContext: LongContext?
}

/// A cost in nano-USD (1e-9 USD): tokens x price in thousandths of a USD per million tokens.
public struct CallCost: Sendable, Equatable {
    public var cacheWrite: Int
    public var other: Int
    /// What the written cache tokens would have cost as a cache read.
    public var writtenAsRead: Int
    /// False when the model was missing from the table and priced as the fallback.
    public var known: Bool
    public var total: Int { cacheWrite + other }
}

public struct PriceTableError: Error, CustomStringConvertible {
    public let description: String
}

/// The official per-model list prices (standard speed, global inference), from `pricing.json`.
public struct PriceTable: Sendable {
    public static let fallbackModel = "claude-opus-5-5"
    public let models: [String: ModelPricing]

    public init(json: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
            let rawModels = root["models"] as? [String: Any], !rawModels.isEmpty
        else { throw PriceTableError(description: "pricing table has no models") }
        var models: [String: ModelPricing] = [:]
        for (id, value) in rawModels {
            guard let raw = value as? [String: Any] else { throw PriceTableError(description: "\(id): not an object") }
            var pricing = ModelPricing(base: try Self.prices(raw, model: id), longContext: nil)
            if let long = raw["long_context"] as? [String: Any] {
                guard let over = long["over_prompt_tokens"] as? Int, over > 0 else {
                    throw PriceTableError(description: "\(id): long_context needs over_prompt_tokens")
                }
                pricing.longContext = .init(overPromptTokens: over, prices: try Self.prices(long, model: id))
            }
            models[id] = pricing
        }
        guard models[Self.fallbackModel] != nil else {
            throw PriceTableError(description: "pricing table lacks the fallback model \(Self.fallbackModel)")
        }
        self.models = models
    }

    /// The table shipped with the app, embedded in the binary (see `scripts/embed-pricing.py`).
    public static func bundled() throws -> PriceTable {
        try PriceTable(json: Data(embeddedJSON.utf8))
    }

    /// The key that equals the model id, or the key it extends with a date such as `-20250929`. Anything else,
    /// a new minor version included, is unknown and priced as the fallback model.
    public func lookup(model: String, promptTokens: Int) -> (prices: Prices, known: Bool) {
        let dated = Self.family(ofDated: model).flatMap { models[$0] != nil ? $0 : nil }
        let match = models[model] != nil ? model : dated
        let pricing = models[match ?? Self.fallbackModel] ?? ModelPricing(base: Self.free, longContext: nil)
        if let long = pricing.longContext, promptTokens > long.overPromptTokens {
            return (long.prices, match != nil)
        }
        return (pricing.base, match != nil)
    }

    /// The sum of the call's parts, each at its own model and tier.
    public func cost(of call: CallRecord) -> CallCost {
        call.parts.reduce(CallCost(cacheWrite: 0, other: 0, writtenAsRead: 0, known: true)) { sum, part in
            let cost = cost(of: part, model: part.model ?? call.model)
            return CallCost(
                cacheWrite: sum.cacheWrite + cost.cacheWrite, other: sum.other + cost.other,
                writtenAsRead: sum.writtenAsRead + cost.writtenAsRead, known: sum.known && cost.known)
        }
    }

    public func cost(of part: UsagePart, model: String) -> CallCost {
        let promptTokens = part.inputTokens + part.cacheReadTokens + part.cacheWriteTokens
        let (p, known) = lookup(model: model, promptTokens: promptTokens)
        // Writes the TTL breakdown does not cover (older transcripts have none) are priced as one-hour writes.
        let write5m = min(part.cacheWrite5m, part.cacheWriteTokens)
        let write1h = part.cacheWriteTokens - write5m
        return CallCost(
            cacheWrite: write1h * p.cacheWrite1h + write5m * p.cacheWrite5m,
            other: part.inputTokens * p.input + part.outputTokens * p.output + part.cacheReadTokens * p.cacheRead,
            writtenAsRead: part.cacheWriteTokens * p.cacheRead,
            known: known)
    }

    private static let free = Prices(input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0)

    /// `claude-sonnet-4-5` for `claude-sonnet-4-5-20250929`; nil unless the id ends in "-" and eight digits.
    private static func family(ofDated model: String) -> String? {
        let suffix = model.suffix(9)
        guard suffix.count == 9, suffix.first == "-", suffix.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return String(model.dropLast(9))
    }

    init(models: [String: ModelPricing]) { self.models = models }

    private static func prices(_ raw: [String: Any], model: String) throws -> Prices {
        func milli(_ key: String) throws -> Int {
            guard let dollars = (raw[key] as? NSNumber)?.doubleValue, dollars >= 0 else {
                throw PriceTableError(description: "\(model): \(key) must be a non-negative number")
            }
            let value = (dollars * 1000).rounded()
            guard abs(value - dollars * 1000) < 1e-6 else {
                throw PriceTableError(description: "\(model): \(key) has more than three decimals")
            }
            return Int(value)
        }
        return Prices(
            input: try milli("input"), cacheWrite5m: try milli("cache_write_5m"),
            cacheWrite1h: try milli("cache_write_1h"), cacheRead: try milli("cache_read"), output: try milli("output"))
    }
}
