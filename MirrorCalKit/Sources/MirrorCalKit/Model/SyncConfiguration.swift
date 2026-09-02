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

    public init(
        titlePolicy: FieldPolicy = .copy,
        descriptionPolicy: FieldPolicy = .drop,
        locationPolicy: FieldPolicy = .drop,
        excludedTitles: Set<String> = [],
        supportedDestinationAvailabilities: Set<EventAvailability> = Set(EventAvailability.allCases)
    ) {
        self.titlePolicy = titlePolicy
        self.descriptionPolicy = descriptionPolicy
        self.locationPolicy = locationPolicy
        self.excludedTitles = excludedTitles
        self.supportedDestinationAvailabilities = supportedDestinationAvailabilities
    }
}
