import XCTest

@testable import MirrorCalKit

final class FieldPolicyTests: XCTestCase {

    func testCopyPassesTheSourceValueThrough() async {
        XCTAssertEqual(FieldPolicy.copy.apply(to: "Quarterly Review"), "Quarterly Review")
        XCTAssertNil(FieldPolicy.copy.apply(to: nil), "copying a field the source never had must not invent one")
    }

    func testDropDiscardsTheSourceValueEvenIfPresent() async {
        XCTAssertNil(FieldPolicy.drop.apply(to: "Sensitive project codename"))
    }

    func testReplaceIgnoresTheSourceValueEntirely() async {
        XCTAssertEqual(FieldPolicy.replace("Busy").apply(to: "Sensitive project codename"), "Busy")
        XCTAssertEqual(
            FieldPolicy.replace("Busy").apply(to: nil), "Busy",
            "replace must not depend on the source having a value at all")
    }

    /// "Busy only" is not a distinct mode in this design — it is exactly this configuration, and
    /// this test is what pins that equivalence rather than leaving it as a claim in a comment.
    func testBusyOnlyModeIsExpressibleAsFieldPolicyCombination() async {
        let configuration = SyncConfiguration(
            titlePolicy: .replace("Busy"),
            descriptionPolicy: .drop,
            locationPolicy: .drop
        )
        let instance = SourceEventInstance(
            externalIdentifier: "x",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600),
            title: "Customer X — contract renewal",
            location: "Room 4",
            notes: "Confidential agenda"
        )
        let mirrored = MirrorContent(mirroring: instance, configuration: configuration)
        XCTAssertEqual(mirrored.title, "Busy")
        XCTAssertNil(mirrored.location)
        XCTAssertNil(mirrored.notes)
    }

    /// A dropped title cannot leave `MirrorContent.title` nil — EventKit's own title is a
    /// non-optional `String` — so "drop" for title has to mean "empty," and that mapping happens
    /// exactly once, here.
    func testDroppedTitleBecomesAnEmptyStringNeverNil() async {
        let configuration = SyncConfiguration(titlePolicy: .drop)
        let instance = SourceEventInstance(
            externalIdentifier: "x",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600),
            title: "Some title"
        )
        XCTAssertEqual(MirrorContent(mirroring: instance, configuration: configuration).title, "")
    }

    func testAllDayEventNeverCarriesATimeZone() async {
        let instance = SourceEventInstance(
            externalIdentifier: "x",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_086_400),
            isAllDay: true,
            title: "Offsite",
            timeZoneIdentifier: "Europe/Berlin"
        )
        XCTAssertNil(
            MirrorContent(mirroring: instance, configuration: SyncConfiguration()).timeZoneIdentifier,
            "an all-day event is floating; carrying a time zone through would contradict isAllDay"
        )
    }
}
