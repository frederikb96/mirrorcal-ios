import Foundation

/// A UUID minted once per install and threaded into every stamp this install writes, so two
/// independent MirrorCal installs pointed at the same destination calendar can each tell their
/// own mirrored events apart from the other's — without it, `SyncEngine`'s ordinary "stamped but
/// no longer in my source" deletion rule reads the other install's events as its own orphans and
/// deletes them.
///
/// Not part of `SyncSettings`: it is never user-facing and never round-trips through the
/// Configuration screen, so it gets its own `UserDefaults` key rather than living in a struct
/// whose whole reason to exist is what that screen edits.
public enum InstallationIdentity {
    private static let key = "mirrorcal.installation-identifier"

    /// Reads the persisted identifier, minting and persisting a new one on first launch. Stable
    /// for the lifetime of the install — reinstalling the app mints a new one, which is correct:
    /// a fresh install has written nothing yet for an old identifier to protect.
    public static func current(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: key) {
            return existing
        }
        let minted = UUID().uuidString
        defaults.set(minted, forKey: key)
        return minted
    }
}
