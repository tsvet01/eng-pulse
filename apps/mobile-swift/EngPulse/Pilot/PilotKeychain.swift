import Foundation
import Security

struct PilotKeychain: PilotCredentialStorage {
    private let service: String
    init(service: String = "org.tsvetkov.eng-pulse.supabase-session") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "current-account",
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw PilotError.secureStorage }
        return data
    }

    func write(_ data: Data?) throws {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw PilotError.secureStorage }
            return
        }
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let record = query.merging(values) { _, new in new }
            guard SecItemAdd(record as CFDictionary, nil) == errSecSuccess else { throw PilotError.secureStorage }
        } else if status != errSecSuccess {
            throw PilotError.secureStorage
        }
    }
}
