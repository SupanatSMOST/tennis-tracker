import Foundation
import Security

/// Keychain-backed token store — the ONLY place in TennisCore that calls SecItem APIs.
/// Uses a fixed service + account pair to locate the item.
///
/// Accessibility: `kSecAttrAccessibleAfterFirstUnlock` (OQ-3).
/// This allows background access after the device has been unlocked once after boot,
/// and participates in iCloud Keychain sync.
/// Do NOT change to any `...ThisDeviceOnly` variant.
public final class KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(
        service: String = "com.tennisshottracker.auth",
        account: String = "bearer_token"
    ) {
        self.service = service
        self.account = account
    }

    // MARK: - TokenStore

    public func get() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    public func set(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        // Attempt add first; if the item already exists, update it.
        let addAttributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: data
        ]
        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)

        if addStatus == errSecDuplicateItem {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let updateAttributes: [CFString: Any] = [
                kSecValueData: data
            ]
            _ = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        }
        // If addStatus is errSecSuccess or any other non-duplicate error, nothing more to do.
    }

    public func clear() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
