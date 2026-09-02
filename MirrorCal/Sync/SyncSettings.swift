import Foundation
import MirrorCalKit

/// Everything the Configuration screen edits and every trigger needs to read, in one `Codable`
/// value — small enough (a handful of scalars, two calendar identifiers, a title set) that
/// `UserDefaults` is the right store, the same call as `SyncCache` choosing a plain JSON file:
/// nothing here is large enough to earn a database.
public struct SyncSettings: Codable, Sendable, Equatable {
    public var sourceCalendarIdentifier: String?
    public var destinationCalendarIdentifier: String?
    public var windowMonthsBack: Int
    public var windowMonthsForward: Int
    public var titlePolicyRawValue: FieldPolicyRawValue
    public var descriptionPolicyRawValue: FieldPolicyRawValue
    public var locationPolicyRawValue: FieldPolicyRawValue
    public var excludedTitles: Set<String>
    public var isEnabled: Bool
    public var sidecarHost: String
    /// The shared secret itself is never stored here — see `SyncSecretStore`. This only records
    /// whether one has been entered, so the settings screen can show its own state without ever
    /// reading the secret back out of the keychain just to check.
    public var hasSidecarSecret: Bool

    /// `FieldPolicy` itself is not `Codable` (`.replace(String)` needs no more than this, and the
    /// package deliberately carries no persistence-format opinion) — this is the app-target-only
    /// encoding, with a fixed replacement text rather than an arbitrary one, matching the one
    /// combination that matters in practice: "Busy only" as title `.replace("Busy")`.
    public enum FieldPolicyRawValue: String, Codable, Sendable, CaseIterable {
        case copy, drop, busyOnly

        public func policy(replacingWith text: String = "Busy") -> FieldPolicy {
            switch self {
            case .copy: .copy
            case .drop: .drop
            case .busyOnly: .replace(text)
            }
        }
    }

    public init(
        sourceCalendarIdentifier: String? = nil,
        destinationCalendarIdentifier: String? = nil,
        windowMonthsBack: Int = 6,
        windowMonthsForward: Int = 12,
        titlePolicyRawValue: FieldPolicyRawValue = .copy,
        descriptionPolicyRawValue: FieldPolicyRawValue = .drop,
        locationPolicyRawValue: FieldPolicyRawValue = .drop,
        excludedTitles: Set<String> = [],
        isEnabled: Bool = false,
        sidecarHost: String = "",
        hasSidecarSecret: Bool = false
    ) {
        self.sourceCalendarIdentifier = sourceCalendarIdentifier
        self.destinationCalendarIdentifier = destinationCalendarIdentifier
        self.windowMonthsBack = windowMonthsBack
        self.windowMonthsForward = windowMonthsForward
        self.titlePolicyRawValue = titlePolicyRawValue
        self.descriptionPolicyRawValue = descriptionPolicyRawValue
        self.locationPolicyRawValue = locationPolicyRawValue
        self.excludedTitles = excludedTitles
        self.isEnabled = isEnabled
        self.sidecarHost = sidecarHost
        self.hasSidecarSecret = hasSidecarSecret
    }

    public var isConfigured: Bool {
        sourceCalendarIdentifier != nil && destinationCalendarIdentifier != nil
    }

    public func configuration(supportedDestinationAvailabilities: Set<EventAvailability>) -> SyncConfiguration {
        SyncConfiguration(
            titlePolicy: titlePolicyRawValue.policy(),
            descriptionPolicy: descriptionPolicyRawValue.policy(),
            locationPolicy: locationPolicyRawValue.policy(),
            excludedTitles: excludedTitles,
            supportedDestinationAvailabilities: supportedDestinationAvailabilities,
            installationIdentifier: InstallationIdentity.current()
        )
    }

    public func window(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .month, value: -windowMonthsBack, to: now) ?? now
        let end = calendar.date(byAdding: .month, value: windowMonthsForward, to: now) ?? now
        return DateInterval(start: start, end: end)
    }
}

/// `UserDefaults`-backed persistence for `SyncSettings`. A missing or corrupt value degrades to
/// `SyncSettings()` — the same "a cache is allowed to be thrown away" reasoning `SyncCache`
/// already uses, since nothing here is authoritative the way the destination calendar itself is.
public final class SyncSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "mirrorcal.sync-settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SyncSettings {
        guard let data = defaults.data(forKey: key),
            let settings = try? JSONDecoder().decode(SyncSettings.self, from: data)
        else { return SyncSettings() }
        return settings
    }

    public func save(_ settings: SyncSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
