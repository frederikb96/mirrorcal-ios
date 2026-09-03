import XCTest

@testable import MirrorCalKit

final class DestinationGuardTests: XCTestCase {

    private func unstamped(_ identifier: String) -> DestinationEvent {
        DestinationEvent(
            identifier: identifier,
            stamp: nil,
            title: "Anniversary dinner",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600)
        )
    }

    private func stamped(_ identifier: String) -> DestinationEvent {
        DestinationEvent(
            identifier: identifier,
            stamp: MirrorStamp(
                sourceExternalIdentifier: "ext-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000)),
            title: "Team Sync",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600)
        )
    }

    // MARK: - Configuration-time guard

    /// The bigger destructive risk in the app: one misconfigured destination calendar picker
    /// could otherwise turn a routine sync into a mass deletion of real personal events. This is
    /// the check that has to be watched failing before it is trusted — see the report for the
    /// mutation this was run against.
    func testConfiguringACalendarThatAlreadyHasUnstampedEventsIsRefused() async {
        let result = DestinationGuard.validateForConfiguration(existingEvents: [
            unstamped("a"), unstamped("b"), stamped("c"),
        ])
        switch result {
        case .success:
            XCTFail("a calendar with pre-existing unstamped events must be refused, not silently accepted")
        case .failure(let error):
            XCTAssertEqual(
                error, .containsUnstampedEvents(count: 2), "the count must reflect only the unstamped events")
        }
    }

    func testConfiguringAnEmptyOrFullyStampedCalendarIsAccepted() async {
        for events in [[], [stamped("a"), stamped("b")]] {
            guard case .success = DestinationGuard.validateForConfiguration(existingEvents: events) else {
                return XCTFail("expected \(events.count) fully-stamped events to be accepted")
            }
        }
    }

    /// The belt-and-braces half of the reinstall fix: a calendar already holding another
    /// installation's mirror is still *accepted* — a shared destination is a legitimate
    /// configuration (row 28/42) — but the count of foreign events is surfaced rather than
    /// silently absorbed, so picking a calendar that turns out to already be someone else's
    /// mirror at least says so with a number.
    func testAcceptedCalendarReportsHowManyStampedEventsBelongToAForeignInstallation() async {
        let foreign = DestinationEvent(
            identifier: "foreign-1",
            stamp: MirrorStamp(
                sourceExternalIdentifier: "ext-1", occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
                installationIdentifier: "another-install"),
            title: "Team Sync",
            occurrenceStart: Date(timeIntervalSince1970: 1_780_000_000),
            occurrenceEnd: Date(timeIntervalSince1970: 1_780_003_600)
        )
        // `stamped("a")`'s own installation identifier is `SyncConfiguration`'s default
        // ("default"), so validating against the default configuration is what keeps it counted
        // as "ours" and leaves only `foreign` counted as foreign.
        let result = DestinationGuard.validateForConfiguration(
            existingEvents: [stamped("a"), foreign], configuration: SyncConfiguration())

        guard case .success(let foreignCount) = result else {
            return XCTFail("a foreign-only mirror must still be accepted")
        }
        XCTAssertEqual(foreignCount, 1, "must count only events stamped by a different installation")
    }

    // MARK: - Per-sync guard (the same property, enforced where it actually matters: every run)

    /// The configuration-time check above is a courtesy; this is the guarantee that actually
    /// protects the calendar on every single sync, forever, regardless of whether the
    /// configuration check was ever run — a plan can only reference events it found in
    /// `stampedDestinationEvents`, and an unstamped event never enters that map.
    func testDeletePassLeavesAnUnstampedEventUntouchedEvenWhenNoSourceEventsRemain() async {
        let engine = SyncEngine()
        let plan = engine.plan(
            source: [], destination: [unstamped("a"), stamped("b")], configuration: SyncConfiguration())

        XCTAssertEqual(plan.deletions.count, 1, "only the stamped event may be deleted")
        XCTAssertEqual(plan.deletions.first?.destinationIdentifier, "b")
    }
}
