import Foundation
import RunningOutCore

/// The user's settings, stored in `UserDefaults` (2-3 domain-entities `AppSettings`).
public struct AppSettings: Equatable, Sendable {
    public var notifyBeforeExpiry = false
    public var notifyLeadMinutes = 10
    public var warningContextTokens = ExpiryCalculator.defaultWarningContextTokens
    public var rebuildThresholdTokens = RebuildClassifier.rebuildThreshold
    public var selectedPeriod = ReportPeriod.today
    public var showAllRebuildCauses = false

    public static let leadChoices = [5, 10, 15, 20]
    public static let warningChoices = [50_000, 100_000, 200_000, 500_000]
    public static let thresholdChoices = [10_000, 20_000, 30_000, 50_000, 75_000, 100_000]

    public init() {}

    private static let prefix = "tokensAreRunningOut."

    /// Values outside the allowed sets read as the default.
    public static func load(from defaults: UserDefaults) -> AppSettings {
        var settings = AppSettings()
        func int(_ key: String, in choices: [Int]) -> Int? {
            guard defaults.object(forKey: prefix + key) != nil else { return nil }
            let value = defaults.integer(forKey: prefix + key)
            return choices.contains(value) ? value : nil
        }
        settings.notifyBeforeExpiry = defaults.bool(forKey: prefix + "notifyBeforeExpiry")
        settings.notifyLeadMinutes = int("notifyLeadMinutes", in: leadChoices) ?? settings.notifyLeadMinutes
        settings.warningContextTokens = int("warningContextTokens", in: warningChoices) ?? settings.warningContextTokens
        settings.rebuildThresholdTokens =
            int("rebuildThresholdTokens", in: thresholdChoices) ?? settings.rebuildThresholdTokens
        settings.selectedPeriod =
            defaults.string(forKey: prefix + "selectedPeriod").flatMap(ReportPeriod.init(rawValue:))
            ?? settings.selectedPeriod
        settings.showAllRebuildCauses = defaults.bool(forKey: prefix + "showAllRebuildCauses")
        return settings
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(notifyBeforeExpiry, forKey: Self.prefix + "notifyBeforeExpiry")
        defaults.set(notifyLeadMinutes, forKey: Self.prefix + "notifyLeadMinutes")
        defaults.set(warningContextTokens, forKey: Self.prefix + "warningContextTokens")
        defaults.set(rebuildThresholdTokens, forKey: Self.prefix + "rebuildThresholdTokens")
        defaults.set(selectedPeriod.rawValue, forKey: Self.prefix + "selectedPeriod")
        defaults.set(showAllRebuildCauses, forKey: Self.prefix + "showAllRebuildCauses")
    }

    public var usesDefaultRebuildThreshold: Bool { rebuildThresholdTokens == RebuildClassifier.rebuildThreshold }
}
