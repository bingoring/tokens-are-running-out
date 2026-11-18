import AppKit
import Foundation
import ServiceManagement
import UserNotifications

public enum NotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}

/// One scheduled "cache expires soon" notification (2-3 domain-entities `ScheduledExpiryNotification`).
public struct ExpiryNotificationRequest: Equatable, Sendable {
    public var identifier: String
    public var fireAt: Date
    public var title: String
    public var body: String
}

/// The system notification center, behind a protocol so the app model can be tested.
@MainActor public protocol NotificationScheduling: AnyObject {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
    func pendingIdentifiers() async -> [String]
    func remove(identifiers: [String])
    func add(_ request: ExpiryNotificationRequest) async
}

public enum LoginItemStatus: Sendable, Equatable {
    case enabled
    case disabled
    /// Registered, but the user still has to allow it in System Settings.
    case requiresApproval
    case unavailable
}

@MainActor public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor public protocol URLOpening: AnyObject {
    func open(_ url: URL)
}

/// `UNUserNotificationCenter`. Only usable inside an app bundle.
public final class UserNotificationScheduler: NotificationScheduling {
    private let center = UNUserNotificationCenter.current()

    public init() {}

    public func authorization() async -> NotificationAuthorization {
        Self.map(await center.notificationSettings().authorizationStatus)
    }

    public func requestAuthorization() async -> NotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    public func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    public func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func add(_ request: ExpiryNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, request.fireAt.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger))
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

/// `SMAppService.mainApp`: open at login.
public final class MainAppLoginItem: LoginItemControlling {
    public init() {}

    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    public func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Hands links to the default browser or System Settings. The app itself never uses the network.
public final class WorkspaceURLOpener: URLOpening {
    public init() {}
    public func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
