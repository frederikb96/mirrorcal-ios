import Foundation
import MirrorCalKit
import Security

/// Persists the installation identifier in the keychain — survives app deletion, which is exactly
/// the lifetime this value needs: it has to outlive the app container for as long as the
/// destination calendar it wrote into does. Shape copied from `SyncSecretStore`, the existing
/// generic-password wrapper for the sidecar's shared secret.
struct KeychainInstallationIdentityStore: InstallationIdentityStore {
    private let service = "com.frederikberg.mirrorcal.installation-identity"
    private let account = "installation-identifier"

    func read() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String) {
        let data = Data(value.utf8)
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Where the identifier lived before this fix — `UserDefaults`, wiped by app deletion, which is
/// the reinstall-duplication bug this replaces. Kept only so a value an earlier install already
/// minted can be adopted into the keychain instead of orphaned; nothing writes here anymore.
///
/// Reads `.standard` directly rather than storing a `UserDefaults` instance: `UserDefaults` is
/// not `Sendable`, and this type has no reason to hold one — it is a one-time migration read, not
/// something a caller ever needs to point at a different suite.
struct LegacyUserDefaultsInstallationIdentityStore: InstallationIdentityStore {
    private let key = "mirrorcal.installation-identifier"

    func read() -> String? { UserDefaults.standard.string(forKey: key) }
    func write(_ value: String) { UserDefaults.standard.set(value, forKey: key) }
}

/// A UUID minted once per install and threaded into every stamp this install writes, so two
/// independent MirrorCal installs pointed at the same destination calendar can each tell their
/// own mirrored events apart from the other's — without it, `SyncEngine`'s ordinary "stamped but
/// no longer in my source" deletion rule reads the other install's events as its own orphans and
/// deletes them.
///
/// Not part of `SyncSettings`: it is never user-facing and never round-trips through the
/// Configuration screen, so it gets its own keychain item rather than living in a struct whose
/// whole reason to exist is what that screen edits.
public enum InstallationIdentity {
    /// Stable for the lifetime of the destination calendar's relationship with this install.
    /// Backed by the keychain (`KeychainInstallationIdentityStore`), which survives a
    /// delete-and-reinstall — `UserDefaults` would not, which is exactly the bug this replaces.
    public static func current() -> String {
        InstallationIdentityResolver.resolve(
            durable: KeychainInstallationIdentityStore(),
            legacy: LegacyUserDefaultsInstallationIdentityStore())
    }
}
