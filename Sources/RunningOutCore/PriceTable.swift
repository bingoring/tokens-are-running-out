import Foundation

/// Prices in thousandths of a USD per million tokens, so every official price is a whole number
/// ($0.125 -> 125) and costs add up exactly in any order.
public struct Prices: Sendable, Equatable {
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    public var output: Int
}

public struct ModelPricing: Sendable, Equatable {
    public struct LongContext: Sendable, Equatable {
        public var overPromptTokens: Int
        public var prices: Prices
    }

    public var base: Prices
    public var longContext: LongContext?
}

/// One call's cost in nano-USD (1e-9 USD): tokens x price in thousandths of a USD per million tokens.
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
        self.models = models
    }

    public static func bundled() throws -> PriceTable {
        guard let url = Bundle.module.url(forResource: "pricing", withExtension: "json") else {
            throw PriceTableError(description: "pricing.json is missing from the bundle")
        }
        return try PriceTable(json: Data(contentsOf: url))
    }

    /// The longest table key that equals the model id or prefixes it followed by "-", so a dated id
    /// such as `claude-sonnet-4-5-20250929` finds `claude-sonnet-4-5`. Unknown models use the fallback.
    public func lookup(model: String, promptTokens: Int) -> (prices: Prices, known: Bool) {
        let match = models.keys.filter { model == $0 || model.hasPrefix($0 + "-") }.max { $0.count < $1.count }
        guard let pricing = models[match ?? Self.fallbackModel] else {
            return (Prices(input: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0, output: 0), false)
        }
        if let long = pricing.longContext, promptTokens > long.overPromptTokens {
            return (long.prices, match != nil)
        }
        return (pricing.base, match != nil)
    }

    public func cost(of call: CallRecord) -> CallCost {
        let promptTokens = call.inputTokens + call.cacheReadTokens + call.cacheWriteTokens
        let (p, known) = lookup(model: call.model, promptTokens: promptTokens)
        // Writes without a TTL breakdown (older transcripts) are priced as one-hour writes.
        let breakdownMissing = call.cacheWrite1h == 0 && call.cacheWrite5m == 0
        let write1h = breakdownMissing ? call.cacheWriteTokens : call.cacheWrite1h
        return CallCost(
            cacheWrite: write1h * p.cacheWrite1h + call.cacheWrite5m * p.cacheWrite5m,
            other: call.inputTokens * p.input + call.outputTokens * p.output + call.cacheReadTokens * p.cacheRead,
            writtenAsRead: call.cacheWriteTokens * p.cacheRead,
            known: known)
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
