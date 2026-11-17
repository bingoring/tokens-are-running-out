import Foundation

/// Serializes all index access, so FSEvents batches and queries never touch SQLite at once.
public actor IndexService {
    private let indexer: Indexer
    private let prices: PriceTable

    public init(root: URL, databaseURL: URL) throws {
        indexer = try Indexer(root: root, databaseURL: databaseURL)
        prices = try PriceTable.bundled()
    }

    public func report(from: Double, to: Double) throws -> UsageReport {
        try UsageAnalyzer(indexer: indexer, prices: prices).report(from: from, to: to)
    }

    public func report(period: ReportPeriod, now: Date = Date()) throws -> UsageReport {
        let window = period.window(now: now)
        return try report(from: window.from, to: window.to)
    }

    public func indexAll() throws -> IndexSummary { try indexer.indexAll() }

    public func update(paths: [URL]) throws -> IndexSummary { try indexer.update(paths: paths) }

    public func stats(from: Double, to: Double) throws -> UsageTotals { try indexer.stats(from: from, to: to) }

    public func owner(of messageID: String) throws -> URL? { try indexer.owner(of: messageID) }

    public func timeline(of file: URL) throws -> [TimelineEvent] { try indexer.timeline(of: file) }

    public func title(of sessionID: String) throws -> String? { try indexer.title(of: sessionID) }

    public func usageMismatchCount() throws -> Int { try indexer.usageMismatchCount() }
}
