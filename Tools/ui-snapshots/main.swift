import AppKit
import RunningOutCore
import RunningOutUI
import SwiftUI

// Renders each screen state to PNG, in light and dark, in the current app language, for design review.
// Every value below is made up. Usage (inside UISnapshots.app, see scripts/build-app.sh):
//   UISnapshots.app/Contents/MacOS/ui-snapshots <output folder> [-AppleLanguages '(ko)']

@MainActor
func render(_ view: some View, name: String, width: CGFloat, to folder: URL) throws {
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        let host = NSHostingView(rootView: view.frame(width: width).background(.background))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = folder.appendingPathComponent("\(name)-\(language)-\(suffix).png")
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.lastPathComponent)")
    }
}

@MainActor
func main() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    guard CommandLine.arguments.count >= 2 else {
        FileHandle.standardError.write(Data("usage: ui-snapshots <output folder>\n".utf8))
        exit(2)
    }
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let now = Date()
    let t = now.timeIntervalSince1970
    func event(
        _ id: String, _ title: String?, _ cause: RebuildCause, minutesAgo: Double, gap: Double?, tokens: Int,
        cost: Int, reducible: Int = 0, previousContext: Int? = nil
    ) -> RebuildEvent {
        RebuildEvent(
            messageID: id, timestamp: t - minutesAgo * 60, file: URL(fileURLWithPath: "/p/\(id).jsonl"),
            sessionID: id, title: title, cause: cause, previousTimestamp: gap.map { t - minutesAgo * 60 - $0 },
            gapSeconds: gap, previousTTL: .oneHour, previousModel: "claude-opus-5-5",
            model: cause == .modelChanged ? "claude-fable-5-2" : "claude-opus-5-5", previousVersion: "2.1.325",
            version: cause == .versionChanged ? "2.1.326" : "2.1.325", cacheWriteTokens: tokens,
            cacheWriteCost: cost, reducibleCost: reducible, previousContextTokens: previousContext)
    }
    var report = UsageReport(from: t - 86_400, to: t)
    report.calls = 4_133
    report.totalCost = 807_630_000_000
    report.bucketCosts = [
        .normalWork: 352_440_000_000, .shortBreakRebuild: 49_100_000_000, .longBreakRebuild: 98_030_000_000,
        .sessionStartAndCompaction: 4_580_000_000, .subagents: 103_380_000_000, .advisor: 188_280_000_000,
        .modelChangeAndUpdate: 11_820_000_000, .unknown: 0,
    ]
    report.shortBreak = BreakTotals(count: 16, tokens: 6_137_829, cost: 49_100_000_000)
    report.longBreak = BreakTotals(count: 34, tokens: 11_917_562, cost: 98_030_000_000)
    report.reducibleCost = 47_650_000_000
    report.rebuilds = [
        event(
            "a", "Refactor parser", .expiredShortBreak, minutesAgo: 30, gap: 62 * 60, tokens: 720_000,
            cost: 5_760_000_000, reducible: 5_616_000_000),
        event(
            "b", "Write release notes for the next version and update the changelog with every merged change",
            .expiredLongBreak, minutesAgo: 240, gap: 14 * 3600, tokens: 1_100_000, cost: 8_800_000_000,
            previousContext: 1_100_000),
        event(
            "c", "Data pipeline cleanup", .afterCompaction, minutesAgo: 90, gap: 120, tokens: 64_000, cost: 512_000_000),
        event("d", nil, .expiredShortBreak, minutesAgo: 400, gap: 95 * 60, tokens: 240_000, cost: 1_920_000_000),
        event(
            "e", "Fix flaky tests", .expiredLongBreak, minutesAgo: 600, gap: 5 * 3600, tokens: 380_000,
            cost: 3_040_000_000),
        event(
            "f", "Upgrade dependencies", .expiredShortBreak, minutesAgo: 700, gap: 70 * 60, tokens: 150_000,
            cost: 1_200_000_000),
    ]
    let warnings = [
        ExpiryWarning(
            sessionID: "s1", title: "Refactor parser", expiresAt: t + 8 * 60 - 1, ttl: .oneHour, contextTokens: 720_000,
            rebuildCost: 5_760_000_000, model: "claude-opus-5-5", priced: true, status: .idle),
        ExpiryWarning(
            sessionID: "s2", title: "Write release notes for the next version and update the changelog",
            expiresAt: t + 41 * 60, ttl: .oneHour, contextTokens: 168_000, rebuildCost: 1_344_000_000,
            model: "claude-opus-5-5", priced: true, status: .idle),
        ExpiryWarning(
            sessionID: "s3", title: "Quick question", expiresAt: t + 3 * 60, ttl: .fiveMinutes, contextTokens: 110_000,
            rebuildCost: 550_000_000, model: "claude-opus-5-5", priced: true, status: .unknownStatus),
    ]
    var changed = AppSettings()
    changed.rebuildThresholdTokens = 30_000
    changed.showAllRebuildCauses = true
    changed.selectedPeriod = .last7Days
    var notifying = AppSettings()
    notifying.notifyBeforeExpiry = true

    var empty = UsageReport(from: t - 86_400, to: t)
    empty.calls = 0
    var unhealthy = IndexHealth()
    unhealthy.kind = .unreadableLines(share: 0.32)

    // Seven warnings (five shown), the first priced as the fallback; a report with an unpriced model.
    var many: [ExpiryWarning] = (0..<7).map { n in
        ExpiryWarning(
            sessionID: "m\(n)", title: "Session \(n + 1)", expiresAt: t + Double(10 + n * 6) * 60, ttl: .oneHour,
            contextTokens: 300_000, rebuildCost: 2_400_000_000, model: "claude-opus-5-5", priced: true, status: .idle)
    }
    many[0].priced = false
    many[0].model = "claude-future-9"
    var estimated = report
    estimated.unpricedModels = ["claude-future-9": 3]
    var unpricedEvent = report.rebuilds[0]
    unpricedEvent.priced = false

    // Large sessions (2-5): each call re-reads the context at the Opus 5.5 cache-read price, 200 nano-USD a token.
    func large(
        _ id: String, _ title: String?, _ tokens: Int, priced: Bool = true, status: LargeSession.Status = .running
    ) -> LargeSession {
        LargeSession(
            sessionID: id, title: title, contextTokens: tokens, readCost: tokens * 200,
            model: priced ? "claude-opus-5-5" : "claude-future-9", priced: priced, status: status)
    }
    let largeTwo = [
        large("s4", "Refactor parser", 620_000),
        large("s5", "Write release notes for the next version and update the changelog", 240_000),
    ]
    let largeExpiring = [large("s1", "Refactor parser", 720_000), large("s5", "Migrate the billing tables", 240_000)]
    let largeMany = (0..<7).map { n in large("l\(n)", "Session \(n + 1)", 900_000 - n * 90_000) }
    let largeUnpriced = [
        large("u1", "Try the new model", 410_000, priced: false),
        large("u2", nil, 230_000, status: .unreadable),
    ]

    let states: [(String, AppModel)] = [
        ("popover-large-sessions", .preview(phase: .ready, now: now, report: report, largeSessions: largeTwo)),
        (
            "popover-large-expiring",
            .preview(phase: .ready, now: now, report: report, warnings: warnings, largeSessions: largeExpiring)
        ),
        ("popover-large-many", .preview(phase: .ready, now: now, report: report, largeSessions: largeMany)),
        ("popover-large-unpriced", .preview(phase: .ready, now: now, report: report, largeSessions: largeUnpriced)),
        ("popover-many-warnings", .preview(phase: .ready, now: now, report: estimated, warnings: many)),
        ("popover-ready", .preview(phase: .ready, now: now, report: report, warnings: warnings, settings: notifying)),
        ("popover-all-causes", .preview(phase: .ready, now: now, report: report, settings: changed)),
        (
            "popover-indexing",
            .preview(
                phase: .indexing(IndexProgress(bytesRead: 420_000_000, bytesTotal: 1_700_000_000, isInitial: true)),
                now: now)
        ),
        ("popover-no-transcripts", .preview(phase: .noTranscripts, now: now)),
        ("popover-index-error", .preview(phase: .indexError("disk full"), now: now)),
        ("popover-format-change", .preview(phase: .ready, now: now, report: report, health: unhealthy)),
        ("popover-empty", .preview(phase: .ready, now: now, report: empty)),
    ]
    for (name, model) in states {
        try render(PopoverView(model: model), name: name, width: 360, to: folder)
    }
    try render(RebuildDetailView(event: report.rebuilds[0]), name: "reason-short-break", width: 320, to: folder)
    try render(RebuildDetailView(event: report.rebuilds[1]), name: "reason-long-break", width: 320, to: folder)
    try render(RebuildDetailView(event: unpricedEvent), name: "reason-unpriced", width: 320, to: folder)
    let denied = AppModel.preview(
        phase: .ready, now: now, settings: notifying,
        services: PreviewServices(notificationStatus: .denied, loginItem: .requiresApproval))
    try render(SettingsView(model: denied), name: "settings-denied", width: 460, to: folder)
    try render(SettingsView(model: .preview(phase: .ready, now: now)), name: "settings-default", width: 460, to: folder)
    try render(
        MenuBarLabel(model: .preview(phase: .ready, now: now, report: report, warnings: warnings)),
        name: "menubar-expiring",
        width: 80, to: folder)
    try render(
        MenuBarLabel(model: .preview(phase: .ready, now: now, report: report)), name: "menubar-share", width: 80,
        to: folder)
    try render(
        MenuBarLabel(model: .preview(phase: .indexError("disk full"), now: now, report: report)),
        name: "menubar-index-error", width: 80, to: folder)
}

MainActor.assumeIsolated {
    do {
        try main()
    } catch {
        FileHandle.standardError.write(Data("ui-snapshots: \(error)\n".utf8))
        exit(1)
    }
}
