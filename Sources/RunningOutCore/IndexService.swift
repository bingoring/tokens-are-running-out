import Foundation

/// Serializes all index access, so FSEvents batches and queries never touch SQLite at once.
public actor IndexService {
    private let indexer: Indexer
    private var prices: PriceTable?

    public init(root: URL, databaseURL: URL) throws {
        indexer = try Indexer(root: root, databaseURL: databaseURL)
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

    public func health(now: Double = Date().timeIntervalSince1970) throws -> IndexHealth {
        try indexer.health(now: now)
    }

    public func lastCall(ofSession sessionID: String) throws -> LastCall? { try indexer.lastCall(ofSession: sessionID) }

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
