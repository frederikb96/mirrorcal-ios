import Foundation

/// What the engine has decided *should* be written to the destination for one source occurrence
/// — the source's fields, already run through the field policy and the availability degradation.
/// This is the only thing `ContentHasher` and `DestinationCalendarStore` ever operate on; neither
/// one needs to know a `SourceEventInstance` exists.
public struct MirrorContent: Sendable, Equatable {
    public let stamp: MirrorStamp
    public let title: String
    public let location: String?
    public let notes: String?
    public let occurrenceStart: Date
    public let occurrenceEnd: Date
    public let isAllDay: Bool
    public let availability: EventAvailability
    public let timeZoneIdentifier: String?

    public init(
        stamp: MirrorStamp,
        title: String,
        location: String?,
        notes: String?,
        occurrenceStart: Date,
        occurrenceEnd: Date,
        isAllDay: Bool,
        availability: EventAvailability,
        timeZoneIdentifier: String?
    ) {
        self.stamp = stamp
        self.title = title
        self.location = location
        self.notes = notes
        self.occurrenceStart = occurrenceStart
        self.occurrenceEnd = occurrenceEnd
        self.isAllDay = isAllDay
        self.availability = availability
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// Applies `configuration`'s field policy and availability degradation to one source
    /// occurrence. The only place a `FieldPolicy` is ever interpreted against real event data.
    public init(mirroring instance: SourceEventInstance, configuration: SyncConfiguration) {
        self.init(
            stamp: MirrorStamp(
                sourceExternalIdentifier: instance.externalIdentifier, occurrenceStart: instance.occurrenceStart),
            title: configuration.titlePolicy.apply(to: instance.title) ?? "",
            location: configuration.locationPolicy.apply(to: instance.location),
            notes: configuration.descriptionPolicy.apply(to: instance.notes),
            occurrenceStart: instance.occurrenceStart,
            occurrenceEnd: instance.occurrenceEnd,
            isAllDay: instance.isAllDay,
            availability: instance.availability.degraded(
                supportedByDestination: configuration.supportedDestinationAvailabilities),
            timeZoneIdentifier: instance.isAllDay ? nil : instance.timeZoneIdentifier
        )
    }
}
