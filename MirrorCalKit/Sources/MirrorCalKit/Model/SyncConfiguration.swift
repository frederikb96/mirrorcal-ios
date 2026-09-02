/// Everything a plan needs besides the two observed event lists. Defaults match what Freddy
/// settled on: title copied verbatim, description and location dropped — a real reduction from
/// the Android app's always-copy-everything behaviour, chosen because the source calendar holds
/// employer data and the destination is shared private infrastructure.
public struct SyncConfiguration: Sendable, Equatable {
    public var titlePolicy: FieldPolicy
    public var descriptionPolicy: FieldPolicy
    public var locationPolicy: FieldPolicy
    /// Exact-title match, same semantics as the Android app's exclusion list — a title in this
    /// set is skipped entirely, never mirrored as a busy block under any other title.
    public var excludedTitles: Set<String>
    /// What `EKCalendar.supportedEventAvailabilities` reports for the destination calendar, read
    /// once and passed in rather than assumed — see `EventAvailability.degraded`.
    public var supportedDestinationAvailabilities: Set<EventAvailability>
    /// Identifies this MirrorCal installation/configuration. `SyncEngine` never treats an event
    /// stamped with a *different* value as one of its own — never matching it, updating it, or
    /// deleting it — which is what makes it safe for two independent installs (say, two people
    /// each mirroring their own work calendar) to write into one shared destination calendar
    /// without either one able to touch the other's events. The shared default lets a
    /// single-install setup work exactly as before: nothing distinguishes it from itself. The app
    /// target is expected to generate and persist a real per-install identifier (a UUID minted
    /// once, e.g.) the moment more than one installation sharing a destination becomes possible.
    public var installationIdentifier: String

    public init(
        titlePolicy: FieldPolicy = .copy,
        descriptionPolicy: FieldPolicy = .drop,
        locationPolicy: FieldPolicy = .drop,
        excludedTitles: Set<String> = [],
        supportedDestinationAvailabilities: Set<EventAvailability> = Set(EventAvailability.allCases),
        installationIdentifier: String = "default"
    ) {
        self.titlePolicy = titlePolicy
        self.descriptionPolicy = descriptionPolicy
        self.locationPolicy = locationPolicy
        self.excludedTitles = excludedTitles
        self.supportedDestinationAvailabilities = supportedDestinationAvailabilities
        self.installationIdentifier = installationIdentifier
    }
}
