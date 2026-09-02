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
    /// Which MirrorCal configuration wrote this — the guard against two independent installs
    /// sharing one destination calendar mutually deleting each other's events. Not part of
    /// `key`: matching within one sync is already scoped to one configuration by
    /// `SyncEngine.plan` filtering `SyncConfiguration.installationIdentifier` before a
    /// destination event is even considered, so this field only ever needs to answer "is this
    /// stamp mine," never "which key does this stamp match." Defaults to the same constant
    /// `SyncConfiguration` does, so a single-install setup is unaffected.
    public let installationIdentifier: String

    public init(sourceExternalIdentifier: String, occurrenceStart: Date, installationIdentifier: String = "default") {
        self.sourceExternalIdentifier = sourceExternalIdentifier
        self.occurrenceStart = occurrenceStart
        self.installationIdentifier = installationIdentifier
    }

    private var epochSeconds: Int { Int(occurrenceStart.timeIntervalSince1970) }

    /// The diff key every match in `SyncEngine.plan` is made on — one entry per occurrence,
    /// mirroring Android's `"${eventId}_${begin}"`, but anchored to a source identifier that
    /// survives a lost local database instead of one that does not.
    public var key: String { "\(sourceExternalIdentifier)_\(epochSeconds)" }

    /// Written into the destination event's own `url` (with `notes` as a documented fallback if
    /// `url` turns out not to survive the CalDAV round trip — a decision for the app target,
    /// verified on a real device).
    public var encoded: String {
        "\(Self.scheme):\(installationIdentifier):\(sourceExternalIdentifier):\(epochSeconds)"
    }

    private static let scheme = "mirrorcal"

    /// `nil` for anything that is not a MirrorCal stamp — the common case, since most of what a
    /// destination calendar's `url` or `notes` holds was written by someone else or by nothing at
    /// all. This has to be conservative: the guard against ever deleting an event MirrorCal did
    /// not create depends on this never producing a false positive. An empty
    /// `sourceExternalIdentifier` is rejected for the same reason a stamp is validated before it
    /// is ever minted (`MirrorContent.mirroring(_:configuration:)`) — decode must never accept
    /// what that validation was built to refuse, or a stamp that slips past it becomes a
    /// permanently unstamped orphan the moment it round-trips through here.
    public static func decode(_ raw: String) -> MirrorStamp? {
        let prefix = "\(scheme):"
        guard raw.hasPrefix(prefix) else { return nil }
        let remainder = raw.dropFirst(prefix.count)
        // The epoch suffix can never contain a colon, so it is always safe to split it off the
        // *last* one first.
        guard let epochSeparator = remainder.lastIndex(of: ":") else { return nil }
        let head = remainder[remainder.startIndex..<epochSeparator]
        let epochText = remainder[remainder.index(after: epochSeparator)...]
        // Unlike the source's own external identifier, `installationIdentifier` is app-generated
        // (a UUID, or the shared "default") and assumed colon-free — so it is safe to split *it*
        // off the *first* colon in what remains, leaving the external identifier, which is opaque
        // and could itself contain one, as everything after.
        guard let installationSeparator = head.firstIndex(of: ":") else { return nil }
        let installationIdentifier = String(head[head.startIndex..<installationSeparator])
        let identifier = String(head[head.index(after: installationSeparator)...])
        guard !installationIdentifier.isEmpty, !identifier.isEmpty, let epoch = Int(epochText) else { return nil }
        return MirrorStamp(
            sourceExternalIdentifier: identifier, occurrenceStart: Date(timeIntervalSince1970: Double(epoch)),
            installationIdentifier: installationIdentifier)
    }
}
