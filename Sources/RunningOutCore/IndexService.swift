import Foundation

/// Serializes all index access, so FSEvents batches and queries never touch SQLite at once.
public actor IndexService {
    private let indexer: Indexer

    public init(root: URL, databaseURL: URL) throws {
        indexer = try Indexer(root: root, databaseURL: databaseURL)
    }

    public func indexAll() throws -> IndexSummary { try indexer.indexAll() }

    public func update(paths: [URL]) throws -> IndexSummary { try indexer.update(paths: paths) }

    public func stats(from: Double, to: Double) throws -> UsageTotals { try indexer.stats(from: from, to: to) }
}
