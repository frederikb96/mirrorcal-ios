import XCTest

@testable import MirrorCalKit

/// The property the reinstall-duplication bug violated: an installation identifier has to
/// survive whatever wipes the app's own ephemeral storage, because the destination calendar
/// outlives the app container. These tests exercise that property at the identity layer, with
/// fakes standing in for the keychain (durable) and `UserDefaults` (wiped on app deletion) —
/// see the terminal review's probe for the same property proven end to end through `SyncEngine`.
final class InstallationIdentityResolverTests: XCTestCase {

    final class FakeStore: InstallationIdentityStore, @unchecked Sendable {
        private var value: String?
        func read() -> String? { value }
        func write(_ value: String) { self.value = value }
        /// Models an app deletion: whatever backed this store is gone.
        func wipe() { value = nil }
    }

    func testResolveMintsOnceAndIsStableAcrossRepeatedCalls() {
        let durable = FakeStore()
        let first = InstallationIdentityResolver.resolve(durable: durable)
        let second = InstallationIdentityResolver.resolve(durable: durable)
        XCTAssertEqual(first, second, "a store that already has a value must never be minted over")
    }

    /// Reproduces the bug at the identity layer: "reinstalling the app" wipes whichever store is
    /// ephemeral, and that must not change the identifier so long as a durable store backs it —
    /// which is exactly what `InstallationIdentity.current()` was not doing before this fix, when
    /// its only store was `UserDefaults` itself.
    func testIdentifierSurvivesWipingAnUnrelatedEphemeralStore() {
        let durable = FakeStore()
        let ephemeral = FakeStore()
        let before = InstallationIdentityResolver.resolve(durable: durable, legacy: ephemeral)

        ephemeral.wipe()
        let after = InstallationIdentityResolver.resolve(durable: durable, legacy: ephemeral)

        XCTAssertEqual(before, after, "wiping a store other than the durable one must not mint a new identifier")
    }

    /// A value already present under the old (pre-fix) key is adopted into the durable store
    /// rather than discarded — an install that predates this fix must not be treated as fresh,
    /// which would orphan every event it already wrote.
    func testExistingLegacyValueIsAdoptedIntoTheDurableStore() {
        let durable = FakeStore()
        let legacy = FakeStore()
        legacy.write("pre-existing-identifier")

        let resolved = InstallationIdentityResolver.resolve(durable: durable, legacy: legacy)

        XCTAssertEqual(resolved, "pre-existing-identifier")
        XCTAssertEqual(
            durable.read(), "pre-existing-identifier",
            "the adopted value must be persisted into the durable store, not merely returned once")
    }

    /// Once adopted, the legacy store is irrelevant — a later wipe of it (a second, ordinary
    /// reinstall after this fix has already shipped) must not affect the now-durable identifier.
    func testAdoptedIdentifierSurvivesALaterLegacyWipe() {
        let durable = FakeStore()
        let legacy = FakeStore()
        legacy.write("pre-existing-identifier")
        _ = InstallationIdentityResolver.resolve(durable: durable, legacy: legacy)

        legacy.wipe()
        let after = InstallationIdentityResolver.resolve(durable: durable, legacy: legacy)

        XCTAssertEqual(after, "pre-existing-identifier")
    }

    /// With no legacy store at all (the ordinary case going forward), a fresh durable store still
    /// mints exactly one identifier rather than failing or requiring one.
    func testMintsWithNoLegacyStoreAtAll() {
        let durable = FakeStore()
        let resolved = InstallationIdentityResolver.resolve(durable: durable)
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertEqual(resolved, durable.read())
    }
}
