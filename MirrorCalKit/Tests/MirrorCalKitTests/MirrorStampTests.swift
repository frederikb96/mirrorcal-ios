import XCTest

@testable import MirrorCalKit

final class MirrorStampTests: XCTestCase {

    /// The stamp has to survive being written into a text field and read back — this is the
    /// entire mechanism identity is recovered through with zero local state.
    func testEncodedStampRoundTripsThroughDecode() async {
        let stamp = MirrorStamp(
            sourceExternalIdentifier: "exchange-abc123", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000))
        let decoded = MirrorStamp.decode(stamp.encoded)
        XCTAssertEqual(decoded, stamp)
    }

    /// A false positive here is what the "never delete an event MirrorCal did not create" guard
    /// depends on — text that merely resembles a stamp, or belongs to some other scheme entirely,
    /// must never decode into one.
    func testUnrelatedTextDoesNotDecodeAsAStamp() async {
        XCTAssertNil(MirrorStamp.decode(""))
        XCTAssertNil(MirrorStamp.decode("https://example.com/event/123"))
        XCTAssertNil(MirrorStamp.decode("mirrorcal-but-not-quite:abc:123"))
        XCTAssertNil(MirrorStamp.decode("mirrorcal:no-epoch-suffix"))
        XCTAssertNil(MirrorStamp.decode("mirrorcal::123"), "an empty external identifier must not decode")
        XCTAssertNil(MirrorStamp.decode("mirrorcal:abc:not-a-number"))
    }

    /// An external identifier is opaque and not guaranteed colon-free; decoding must split on the
    /// *last* colon so an identifier containing one still round-trips.
    func testExternalIdentifierMayContainAColon() async {
        let stamp = MirrorStamp(
            sourceExternalIdentifier: "urn:exchange:abc123", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000)
        )
        XCTAssertEqual(MirrorStamp.decode(stamp.encoded), stamp)
    }

    /// This is the property that makes a recurring series safe: two occurrences of the very same
    /// series must never collapse into one key just because Apple documents their identifiers as
    /// identical — only the differing occurrence start keeps them apart.
    func testSameSeriesDifferentOccurrencesHaveDifferentKeys() async {
        let first = MirrorStamp(
            sourceExternalIdentifier: "series-x", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000))
        let second = MirrorStamp(
            sourceExternalIdentifier: "series-x", occurrenceStart: Date(timeIntervalSince1970: 1_780_600_000))
        XCTAssertNotEqual(first.key, second.key)
    }
}
