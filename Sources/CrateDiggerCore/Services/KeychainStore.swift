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
