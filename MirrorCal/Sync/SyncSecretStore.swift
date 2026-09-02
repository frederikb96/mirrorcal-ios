import Foundation
import Security

/// The push sidecar's shared secret, kept out of `UserDefaults` deliberately — everything else in
/// `SyncSettings` is a preference; this is a credential, and the keychain is what iOS gives an app
/// for exactly that distinction. A generic password item, scoped to this app's own keychain
/// access group by default (no group configured), so nothing else on the device can read it.
public enum SyncSecretStore {
    private static let service = "com.frederikberg.mirrorcal.sidecar-secret"
    private static let account = "shared-secret"

    public static func save(_ secret: String) {
        let data = Data(secret.utf8)
        var query = baseQuery()
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
