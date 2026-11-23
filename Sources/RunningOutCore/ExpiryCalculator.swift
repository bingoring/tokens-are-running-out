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
    public enum Status: Sendable, Equatable {
        /// The running-session file says the session is idle or waiting for the user.
        case idle
        /// The running-session file has a status this version does not know.
        case unknownStatus
        /// The running-session files could not be read.
        case unreadable
    }

    public var status: Status

    public init(
        sessionID: String, title: String?, expiresAt: Double, ttl: CacheTTL, contextTokens: Int, rebuildCost: Int,
        model: String, priced: Bool, status: Status
    ) {
        self.sessionID = sessionID
        self.title = title
        self.expiresAt = expiresAt
        self.ttl = ttl
        self.contextTokens = contextTokens
        self.rebuildCost = rebuildCost
        self.model = model
        self.priced = priced
        self.status = status
    }
}

public enum ExpiryCalculator {
    public static let defaultWarningContextTokens = 100_000

    /// Warnings sorted by expiry, soonest first.
    public static func warnings(
        registry: RegistryState, now: Double, warningContextTokens: Int, prices: PriceTable,
        lastCall: (String) throws -> LastCall?, sessionsWithCallsSince: (Double) throws -> [String]
    ) throws -> [ExpiryWarning] {
        var candidates: [(session: RunningSession?, status: ExpiryWarning.Status, sessionID: String)] = []
        switch registry {
        case .available(let sessions):
            // Two processes can resume one session: warn once, preferring the one known to be idle.
            // Idle and waiting for the user both mean no call is running.
            func known(_ status: RunningSession.Status) -> Bool { status == .idle || status == .waiting }
            var byID: [String: RunningSession] = [:]
            for session in sessions where session.status != .busy {
                if let kept = byID[session.sessionID], known(kept.status) { continue }
                byID[session.sessionID] = session
            }
            for session in byID.values {
                candidates.append((session, known(session.status) ? .idle : .unknownStatus, session.sessionID))
            }
        case .unavailable:
            // Any main session whose last call may still be cached (TTLs are at most one hour).
            for sessionID in try sessionsWithCallsSince(now - CacheTTL.oneHour.seconds) {
                candidates.append((nil, .unreadable, sessionID))
            }
        }
        var warnings: [ExpiryWarning] = []
        for candidate in candidates {
            // After a compaction the next message rewrites only the summary, so there is nothing to warn about.
            guard let last = try lastCall(candidate.sessionID), !last.compactedAfter else { continue }
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
                    status: candidate.status))
        }
        return warnings.sorted { ($0.expiresAt, $0.sessionID) < ($1.expiresAt, $1.sessionID) }
    }
}
