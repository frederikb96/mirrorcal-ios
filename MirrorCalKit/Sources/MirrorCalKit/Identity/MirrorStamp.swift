import Foundation

/// The durable marker written into a destination event so its origin can be recovered by
/// scanning the destination calendar alone, with zero local state. This is the single highest-
/// value fix over the Android app: there, the *only* record of "this destination event is a
/// mirror of source event X" lived in a local database, so losing it — a reinstall, a device
/// migration, a schema bump — produced a second complete copy of every event with no way to find
/// the first. A stamp inside the event itself removes the failure class rather than mitigating it.
public struct MirrorStamp: Sendable, Equatable, Hashable {
    /// `calendarItemExternalIdentifier` on the source event. Apple documents this as identical
    /// for every occurrence of a recurring event and suggests exactly this: "if you wish to
    /// differentiate between occurrences, you may want to use the start date."
    public let sourceExternalIdentifier: String
    public let occurrenceStart: Date

    public init(sourceExternalIdentifier: String, occurrenceStart: Date) {
        self.sourceExternalIdentifier = sourceExternalIdentifier
        self.occurrenceStart = occurrenceStart
    }

    private var epochSeconds: Int { Int(occurrenceStart.timeIntervalSince1970) }

    /// The diff key every match in `SyncEngine.plan` is made on — one entry per occurrence,
    /// mirroring Android's `"${eventId}_${begin}"`, but anchored to a source identifier that
    /// survives a lost local database instead of one that does not.
    public var key: String { "\(sourceExternalIdentifier)_\(epochSeconds)" }

    /// Written into the destination event's own `url` (with `notes` as a documented fallback if
    /// `url` turns out not to survive the CalDAV round trip — a decision for the app target,
    /// verified on a real device).
    public var encoded: String { "\(Self.scheme):\(sourceExternalIdentifier):\(epochSeconds)" }

    private static let scheme = "mirrorcal"

    /// `nil` for anything that is not a MirrorCal stamp — the common case, since most of what a
    /// destination calendar's `url` or `notes` holds was written by someone else or by nothing at
    /// all. This has to be conservative: the guard against ever deleting an event MirrorCal did
    /// not create depends on this never producing a false positive.
    public static func decode(_ raw: String) -> MirrorStamp? {
        let prefix = "\(scheme):"
        guard raw.hasPrefix(prefix) else { return nil }
        let remainder = raw.dropFirst(prefix.count)
        // The external identifier is opaque and could in principle contain a colon; the epoch
        // suffix cannot, so splitting on the *last* colon is the only direction that is safe.
        guard let separator = remainder.lastIndex(of: ":") else { return nil }
        let identifier = String(remainder[remainder.startIndex..<separator])
        let epochText = String(remainder[remainder.index(after: separator)...])
        guard !identifier.isEmpty, let epoch = Int(epochText) else { return nil }
        return MirrorStamp(
            sourceExternalIdentifier: identifier, occurrenceStart: Date(timeIntervalSince1970: Double(epoch)))
    }
}
