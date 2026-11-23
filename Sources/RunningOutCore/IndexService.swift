import Foundation

/// Serializes all index access, so FSEvents batches and queries never touch SQLite at once.
public actor IndexService {
    private let indexer: Indexer
    private var prices: PriceTable?

    public init(root: URL, databaseURL: URL, opening: IndexOpening = .refuseUnknown) throws {
        indexer = try Indexer(root: root, databaseURL: databaseURL, opening: opening)
    }

    public func report(from: Double, to: Double, rebuildThreshold: Int = RebuildClassifier.rebuildThreshold) throws
        -> UsageReport
    {
        try UsageAnalyzer(indexer: indexer, prices: priceTable(), rebuildThreshold: rebuildThreshold)
            .report(from: from, to: to)
    }

    /// Loaded on first use, so indexing never depends on the price table.
    private func priceTable() throws -> PriceTable {
        if let prices { return prices }
        let loaded = try PriceTable.bundled()
        prices = loaded
        return loaded
    }

    public func report(
        period: ReportPeriod, now: Date = Date(), rebuildThreshold: Int = RebuildClassifier.rebuildThreshold
    ) throws -> UsageReport {
        let window = period.window(now: now)
        return try report(from: window.from, to: window.to, rebuildThreshold: rebuildThreshold)
    }

    public func indexAll(progress: (@Sendable (IndexProgress) -> Void)? = nil) throws -> IndexSummary {
        try indexer.indexAll(progress: progress)
    }

    public func hasIndexedFiles() throws -> Bool { try indexer.hasIndexedFiles() }

    public func health(now: Double = Date().timeIntervalSince1970) throws -> IndexHealth {
        try indexer.health(now: now)
    }

    public func lastCall(ofSession sessionID: String) throws -> LastCall? { try indexer.lastCall(ofSession: sessionID) }

    /// Cache-expiry warnings for the running sessions (2-3 BR-E1).
    public func expiryWarnings(
        registry: RegistryState, now: Double = Date().timeIntervalSince1970,
        warningContextTokens: Int = ExpiryCalculator.defaultWarningContextTokens
    ) throws -> [ExpiryWarning] {
        try ExpiryCalculator.warnings(
            registry: registry, now: now, warningContextTokens: warningContextTokens, prices: priceTable(),
            lastCall: { try indexer.lastCall(ofSession: $0) },
            sessionsWithCallsSince: { try indexer.mainSessions(withCallsSince: $0) })
    }

    /// Running sessions with a large context, for the compact suggestion (2-5 BR-C1).
    public func largeSessions(
        registry: RegistryState, now: Double = Date().timeIntervalSince1970,
        thresholdTokens: Int = LargeSessionFinder.defaultThresholdTokens
    ) throws -> [LargeSession] {
        try LargeSessionFinder.sessions(
            registry: registry, now: now, thresholdTokens: thresholdTokens, prices: priceTable(),
            lastCall: { try indexer.lastCall(ofSession: $0) },
            sessionsWithCallsSince: { try indexer.mainSessions(withCallsSince: $0) })
    }

    public func mainSessions(withCallsSince since: Double) throws -> [String] {
        try indexer.mainSessions(withCallsSince: since)
    }

    public func update(paths: [URL]) throws -> IndexSummary { try indexer.update(paths: paths) }

    public func stats(from: Double, to: Double) throws -> UsageTotals { try indexer.stats(from: from, to: to) }

    public func owner(of messageID: String) throws -> URL? { try indexer.owner(of: messageID) }

    public func timeline(of file: URL) throws -> [TimelineEvent] { try indexer.timeline(of: file) }

    public func title(of sessionID: String) throws -> String? { try indexer.title(of: sessionID) }

    public func usageMismatchCount() throws -> Int { try indexer.usageMismatchCount() }
}
