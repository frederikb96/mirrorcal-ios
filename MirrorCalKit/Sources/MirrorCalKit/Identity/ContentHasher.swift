import Foundation

/// A stable, non-cryptographic hash over exactly the fields this app ever writes to the
/// destination calendar. Two values are equal under this hash exactly when they would produce
/// the same destination event — that equivalence is what `SyncEngine.plan` uses to decide whether
/// a write is needed at all.
///
/// Deliberately not SHA-256 or any `CryptoKit` type: this is a change detector, not a security
/// boundary, and Swift's own `Hasher` is randomized per process launch — unusable for a value that
/// has to compare equal across separate runs and separate devices. FNV-1a needs no crypto
/// dependency and no Apple framework, so it stays available on Linux with nothing added to the
/// package manifest.
public enum ContentHasher: Sendable {
    /// The hash of what the engine intends to write.
    public static func hash(_ content: MirrorContent) -> String {
        fnv1a(
            fields(
                title: content.title,
                location: content.location,
                notes: content.notes,
                occurrenceStart: content.occurrenceStart,
                occurrenceEnd: content.occurrenceEnd,
                isAllDay: content.isAllDay,
                availability: content.availability,
                timeZoneIdentifier: content.timeZoneIdentifier
            )
        )
    }

    /// The same hash, computed from what is actually observed in the destination calendar right
    /// now — never from anything cached. Comparing this against `hash(_:MirrorContent)` for the
    /// same stamp key is the entire "has this changed" decision; nothing else feeds into it.
    public static func hash(observed event: DestinationEvent) -> String {
        fnv1a(
            fields(
                title: event.title,
                location: event.location,
                notes: event.notes,
                occurrenceStart: event.occurrenceStart,
                occurrenceEnd: event.occurrenceEnd,
                isAllDay: event.isAllDay,
                availability: event.availability,
                timeZoneIdentifier: event.timeZoneIdentifier
            )
        )
    }

    /// Both overloads above must feed this the same field order for the comparison to mean
    /// anything — this is the one place that order is defined.
    private static func fields(
        title: String,
        location: String?,
        notes: String?,
        occurrenceStart: Date,
        occurrenceEnd: Date,
        isAllDay: Bool,
        availability: EventAvailability,
        timeZoneIdentifier: String?
    ) -> [String] {
        [
            title,
            location ?? "",
            notes ?? "",
            String(Int(occurrenceStart.timeIntervalSince1970)),
            String(Int(occurrenceEnd.timeIntervalSince1970)),
            isAllDay ? "1" : "0",
            availability.rawValue,
            timeZoneIdentifier ?? "",
        ]
    }

    private static func fnv1a(_ fields: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        // Pipe-joined so a boundary between two empty fields cannot collide with a boundary
        // between one field holding "a|b" and the next holding nothing — matches Android's own
        // pipe-joined hash input for the same reason.
        for byte in fields.joined(separator: "|").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
