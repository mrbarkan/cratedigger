import Foundation
import Security

/// Minimal secret storage abstraction so tests can substitute an in-memory
/// fake instead of touching the real keychain (SecItem calls can prompt or
/// fail in headless test runners).
public protocol SecretStoring {
    func get(_ key: String) -> String?
    /// Stores `value` under `key`; passing nil deletes the entry.
    func set(_ key: String, _ value: String?)
}

/// Generic-password keychain storage (kSecClassGenericPassword), one item per
/// key: service = "com.cratedigger.app", account = key.
public final class KeychainStore: SecretStoring {

    private let service: String

    public init(service: String = "com.cratedigger.app") {
        self.service = service
    }

    public func get(_ key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            AppLog.prefs.warning("Keychain read failed for \(key, privacy: .public): OSStatus \(status)")
            return nil
        }
    }

    public func set(_ key: String, _ value: String?) {
        guard let value else {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                AppLog.prefs.warning("Keychain delete failed for \(key, privacy: .public): OSStatus \(status)")
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var add = baseQuery(for: key)
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            AppLog.prefs.warning("Keychain write failed for \(key, privacy: .public): OSStatus \(status)")
        }
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

#if DEBUG
/// Debug-only secret storage: an ordinary `UserDefaults` entry instead of the
/// keychain.
///
/// A `swift build` binary is ad-hoc signed and its signature changes on every
/// rebuild, so the keychain sees a different application every time and the
/// "Always Allow" you granted no longer matches. The result is a login-password
/// prompt on every single launch during development, which makes running the
/// app to check a change unworkable.
///
/// What is stored is a Last.fm session key. It is revocable, it is useless
/// without the API secret, and it never leaves the machine that built the
/// binary. A release build is signed with a stable identity and always uses
/// `KeychainStore` — this type does not exist there.
///
/// Keys are prefixed so they cannot collide with the plaintext values
/// `PreferencesStore.migrateLegacySecretIfNeeded` looks for and deletes.
public final class DevSecretStore: SecretStoring {
    private static let prefix = "cratedigger.debugSecret."
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func get(_ key: String) -> String? {
        defaults.string(forKey: Self.prefix + key)
    }

    public func set(_ key: String, _ value: String?) {
        if let value {
            defaults.set(value, forKey: Self.prefix + key)
        } else {
            defaults.removeObject(forKey: Self.prefix + key)
        }
    }
}
#endif
