import Foundation

/// A session whose cache expires soon if it stays idle (2-3 BR-E1 to BR-E6).
public struct ExpiryWarning: Sendable, Equatable {
    public var sessionID: String
    /// The session title, else its name, else its folder name; nil when none is known.
    public var title: String?
    /// Seconds since 1970.
    public var expiresAt: Double
    public var ttl: CacheTTL
    public var contextTokens: Int
    /// nano-USD: rewriting the context at the TTL's write price.
    public var rebuildCost: Int
    public var model: String
    /// False when the model is missing from the price table and was priced as the fallback.
    public var priced: Bool
    /// False when the running-session files could not confirm the session is idle.
    public var statusKnown: Bool

    public init(
        sessionID: String, title: String?, expiresAt: Double, ttl: CacheTTL, contextTokens: Int, rebuildCost: Int,
        model: String, priced: Bool, statusKnown: Bool
    ) {
        self.sessionID = sessionID
        self.title = title
        self.expiresAt = expiresAt
        self.ttl = ttl
        self.contextTokens = contextTokens
        self.rebuildCost = rebuildCost
        self.model = model
        self.priced = priced
        self.statusKnown = statusKnown
    }
}

public enum ExpiryCalculator {
    public static let defaultWarningContextTokens = 100_000

    /// Warnings sorted by expiry, soonest first.
    public static func warnings(
        registry: RegistryState, now: Double, warningContextTokens: Int, prices: PriceTable,
        lastCall: (String) throws -> LastCall?, sessionsWithCallsSince: (Double) throws -> [String]
    ) throws -> [ExpiryWarning] {
        var candidates: [(session: RunningSession?, statusKnown: Bool, sessionID: String)] = []
        switch registry {
        case .available(let sessions):
            for session in sessions where session.status != .busy {
                candidates.append((session, session.status == .idle, session.sessionID))
            }
        case .unavailable:
            // Any main session whose last call may still be cached (TTLs are at most one hour).
            for sessionID in try sessionsWithCallsSince(now - CacheTTL.oneHour.seconds) {
                candidates.append((nil, false, sessionID))
            }
        }
        var warnings: [ExpiryWarning] = []
        for candidate in candidates {
            guard let last = try lastCall(candidate.sessionID) else { continue }
            let expiresAt = last.timestamp + last.ttl.seconds
            guard last.contextTokens >= warningContextTokens, now < expiresAt else { continue }
            let (price, known) = prices.lookup(model: last.model, promptTokens: last.contextTokens)
            let writePrice = last.ttl == .oneHour ? price.cacheWrite1h : price.cacheWrite5m
            let folder = candidate.session?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            warnings.append(
                ExpiryWarning(
                    sessionID: candidate.sessionID, title: last.title ?? candidate.session?.name ?? folder,
                    expiresAt: expiresAt, ttl: last.ttl, contextTokens: last.contextTokens,
                    rebuildCost: last.contextTokens * writePrice, model: last.model, priced: known,
                    statusKnown: candidate.statusKnown))
        }
        return warnings.sorted { ($0.expiresAt, $0.sessionID) < ($1.expiresAt, $1.sessionID) }
    }
}
