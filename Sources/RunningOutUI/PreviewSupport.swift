import Foundation
import RunningOutCore

/// No-op system services and a model filled with given state, for screenshots of each screen state.
/// Only synthetic values go in here.
@MainActor
public final class PreviewServices: NotificationScheduling, LoginItemControlling, URLOpening,
    PasteboardWriting
{
    public var notificationStatus: NotificationAuthorization
    public var status: LoginItemStatus

    public init(notificationStatus: NotificationAuthorization = .authorized, loginItem: LoginItemStatus = .disabled) {
        self.notificationStatus = notificationStatus
        self.status = loginItem
    }

    public func authorization() async -> NotificationAuthorization { notificationStatus }
    public func requestAuthorization() async -> NotificationAuthorization { notificationStatus }
    public func pendingIdentifiers() async -> [String] { [] }
    public func remove(identifiers: [String]) {}
    public func add(_ request: ExpiryNotificationRequest) async {}
    public func setEnabled(_ enabled: Bool) throws {}
    public func openSystemSettings() {}
    public func open(_ url: URL) {}
    public func write(_ text: String) -> Bool { true }
}

extension AppModel {
    public static func preview(
        phase: Phase, now: Date, report: UsageReport? = nil, warnings: [ExpiryWarning] = [],
        largeSessions: [LargeSession] = [],
        health: IndexHealth = IndexHealth(), settings: AppSettings = AppSettings(),
        services: PreviewServices = PreviewServices()
    ) -> AppModel {
        let suite = "preview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        settings.save(to: defaults)
        let missing = URL(fileURLWithPath: "/nonexistent-preview")
        let model = AppModel(
            environment: Environment(
                root: missing, database: missing, sessions: missing, defaults: defaults, automaticUpdates: false),
            scheduler: services, loginItem: services, urlOpener: services, pasteboard: services, clock: { now })
        model.phase = phase
        model.todayReport = report
        model.selectedReport = report
        model.warnings = warnings
        model.largeSessions = largeSessions
        model.health = health
        model.notificationAuthorization = services.notificationStatus
        defaults.removePersistentDomain(forName: suite)
        return model
    }
}
