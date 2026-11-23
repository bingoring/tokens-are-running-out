import Foundation

/// A running session whose context is large enough that compacting it is worth suggesting (2-5 BR-C1).
public struct LargeSession: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// Found in Claude Code's running-session files.
        case running
        /// The running-session files could not be read; the session had a call in the last hour.
        case unreadable
    }

    public var sessionID: String
    /// The session title, else its name, else its folder name; nil when none is known.
    public var title: String?
    public var contextTokens: Int
    /// nano-USD: one call re-reading the whole context from the cache, at the list price (2-5 BR-C6).
    public var readCost: Int
    public var model: String
    /// False when the model is missing from the price table and was priced as the fallback.
    public var priced: Bool
    public var status: Status

    public init(
        sessionID: String, title: String?, contextTokens: Int, readCost: Int, model: String, priced: Bool,
        status: Status
    ) {
        self.sessionID = sessionID
        self.title = title
        self.contextTokens = contextTokens
        self.readCost = readCost
        self.model = model
        self.priced = priced
        self.status = status
    }
}

public enum LargeSessionFinder {
    public static let defaultThresholdTokens = 200_000

    /// Largest context first, then by session ID.
    public static func sessions(
        registry: RegistryState, now: Double, thresholdTokens: Int, prices: PriceTable,
        lastCall: (String) throws -> LastCall?, sessionsWithCallsSince: (Double) throws -> [String]
    ) throws -> [LargeSession] {
        var candidates: [(session: RunningSession?, status: LargeSession.Status, sessionID: String)] = []
        switch registry {
        case .available(let running):
            // Any status: a busy session can take the prompt once its turn ends. One row per session ID.
            var seen = Set<String>()
            for session in running where seen.insert(session.sessionID).inserted {
                candidates.append((session, .running, session.sessionID))
            }
        case .unavailable:
            for sessionID in try sessionsWithCallsSince(now - CacheTTL.oneHour.seconds) {
                candidates.append((nil, .unreadable, sessionID))
            }
        }
        var found: [LargeSession] = []
        for candidate in candidates {
            guard let last = try lastCall(candidate.sessionID), !last.compactedAfter,
                last.contextTokens >= thresholdTokens
            else { continue }
            let (price, known) = prices.lookup(model: last.model, promptTokens: last.contextTokens)
            let folder = candidate.session?.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            found.append(
                LargeSession(
                    sessionID: candidate.sessionID, title: last.title ?? candidate.session?.name ?? folder,
                    contextTokens: last.contextTokens, readCost: last.contextTokens * price.cacheRead,
                    model: last.model, priced: known, status: candidate.status))
        }
        return found.sorted { ($1.contextTokens, $0.sessionID) < ($0.contextTokens, $1.sessionID) }
    }
}
