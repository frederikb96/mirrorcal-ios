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
    ///
    /// Permissive on purpose — it stamps whatever `instance.externalIdentifier` holds, empty
    /// string included, so tests can construct any shape directly. `mirroring(_:configuration:)`
    /// below is the validating entry point real sync flow uses instead.
    public init(mirroring instance: SourceEventInstance, configuration: SyncConfiguration) {
        self.init(
            stamp: MirrorStamp(
                sourceExternalIdentifier: instance.externalIdentifier, occurrenceStart: instance.occurrenceStart,
                installationIdentifier: configuration.installationIdentifier),
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

    /// `nil` when `instance.externalIdentifier` is empty — Apple documents
    /// `calendarItemExternalIdentifier` as optional, and an empty identifier encodes into a stamp
    /// that `MirrorStamp.decode` correctly refuses to read back (by design — see its doc comment).
    /// Minting one anyway would produce a destination event that is written once, decodes as
    /// permanently unstamped on every following sync, and is therefore never recognised as
    /// already mirrored — recreated forever rather than converging. `SyncEngine` calls this,
    /// never the plain initializer above, when turning a live source occurrence into content to
    /// mirror.
    public static func mirroring(_ instance: SourceEventInstance, configuration: SyncConfiguration) -> MirrorContent? {
        guard !instance.externalIdentifier.isEmpty else { return nil }
        return MirrorContent(mirroring: instance, configuration: configuration)
    }
}
