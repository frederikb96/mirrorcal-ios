import XCTest

@testable import MirrorCalKit

final class ContentHasherTests: XCTestCase {

    private func content(
        title: String = "Team Sync",
        location: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false,
        availability: EventAvailability = .busy,
        timeZoneIdentifier: String? = "Europe/Berlin"
    ) -> MirrorContent {
        MirrorContent(
            stamp: MirrorStamp(
                sourceExternalIdentifier: "x", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000)),
            title: title,
            location: location,
            notes: notes,
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600),
            isAllDay: isAllDay,
            availability: availability,
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    private func observed(from content: MirrorContent, identifier: String = "dest-1") -> DestinationEvent {
        DestinationEvent(
            identifier: identifier,
            stamp: content.stamp,
            title: content.title,
            location: content.location,
            notes: content.notes,
            occurrenceStart: content.occurrenceStart,
            occurrenceEnd: content.occurrenceEnd,
            isAllDay: content.isAllDay,
            availability: content.availability,
            timeZoneIdentifier: content.timeZoneIdentifier
        )
    }

    func testIdenticalContentHashesEqual() async {
        XCTAssertEqual(ContentHasher.hash(content()), ContentHasher.hash(content()))
    }

    /// The whole engine's "unchanged" decision rests on this: a `MirrorContent` and the
    /// `DestinationEvent` it was written as must hash identically, or every write would be
    /// re-issued forever even when nothing changed.
    func testDesiredHashMatchesTheEquivalentObservedHash() async {
        let desired = content(title: "Quarterly Review", location: "Room 4", notes: "Bring slides")
        let asObserved = observed(from: desired)
        XCTAssertEqual(ContentHasher.hash(desired), ContentHasher.hash(observed: asObserved))
    }

    /// Enumerated rather than looped, so a failure names exactly which field stopped being
    /// hash-sensitive — the shape of bug this guards against is someone adding a field to
    /// `MirrorContent` without adding it to the hash, which a loop over "any field" would not
    /// localize as clearly.
    func testEachHashedFieldChangesTheHash() async {
        let base = ContentHasher.hash(content())
        XCTAssertNotEqual(base, ContentHasher.hash(content(title: "Different Title")), "title")
        XCTAssertNotEqual(base, ContentHasher.hash(content(location: "New Room")), "location")
        XCTAssertNotEqual(base, ContentHasher.hash(content(notes: "New notes")), "notes")
        XCTAssertNotEqual(base, ContentHasher.hash(content(isAllDay: true)), "isAllDay")
        XCTAssertNotEqual(base, ContentHasher.hash(content(availability: .tentative)), "availability")
        XCTAssertNotEqual(base, ContentHasher.hash(content(timeZoneIdentifier: "Asia/Tokyo")), "timeZoneIdentifier")
    }

    /// `nil` and `""` are different real-world states (no location field at all vs. an empty one)
    /// and Android's own pipe-joined hash treated them as the same string for the same reason —
    /// worth pinning explicitly rather than leaving it to be true by accident of `?? ""`.
    func testNilAndEmptyStringLocationHashTheSame() async {
        XCTAssertEqual(ContentHasher.hash(content(location: nil)), ContentHasher.hash(content(location: "")))
    }

    func testHashIsStableAcrossRepeatedCalls() async {
        let value = content(notes: "stability check")
        XCTAssertEqual(
            ContentHasher.hash(value), ContentHasher.hash(value),
            "the hash must not depend on process-local randomization")
    }

    /// A pipe-joined hash without escaping is only unambiguous when no field itself contains the
    /// delimiter — a real meeting title like "Standup | Backend team" breaks that assumption, and
    /// two different (title, location) pairs can flatten into the identical joined string.
    func testAFieldContainingTheDelimiterCannotCollideWithAnAdjacentField() async {
        let contentA = content(title: "a|b", location: "c")
        let contentB = content(title: "a", location: "b|c")
        XCTAssertNotEqual(
            ContentHasher.hash(contentA), ContentHasher.hash(contentB),
            "two different field combinations must never hash equal just because a field contains the delimiter")
    }
}
