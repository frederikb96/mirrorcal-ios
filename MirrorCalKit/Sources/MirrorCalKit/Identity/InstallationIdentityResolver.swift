import Foundation

/// Where an installation identifier is persisted. Two conformances exist in the app target: a
/// durable one (the keychain — survives app deletion) and a legacy one (`UserDefaults` — wiped by
/// app deletion, kept only so a value an earlier install already minted can be adopted rather
/// than orphaned). Living here, rather than only in the app target, is what makes the property
/// this exists for testable with a fake — see `InstallationIdentityResolver`.
public protocol InstallationIdentityStore: Sendable {
    func read() -> String?
    func write(_ value: String)
}

/// Reads-or-mints an installation identifier, independent of which store backs it. This is the
/// fix for the reinstall duplication bug: the identifier's lifetime has to match the *destination
/// calendar's* lifetime, not the app container's, and whether that holds is entirely a property
/// of which store `durable` is — this function itself never assumes anything about survival, it
/// only ever reads and writes through the protocol.
public enum InstallationIdentityResolver {
    /// `legacy`, if given, is consulted only when `durable` has nothing yet: a value already
    /// minted under the old (pre-fix) storage is adopted into `durable` rather than discarded,
    /// which is what keeps an install that predates this fix from being treated as a fresh one —
    /// that would orphan every event it already wrote just as surely as a real reinstall would.
    public static func resolve(
        durable: any InstallationIdentityStore, legacy: (any InstallationIdentityStore)? = nil
    ) -> String {
        if let existing = durable.read() {
            return existing
        }
        if let adopted = legacy?.read() {
            durable.write(adopted)
            return adopted
        }
        let minted = UUID().uuidString
        durable.write(minted)
        return minted
    }
}
