import Foundation
import Security

actor NeteaseCredentialStore {
    struct Operations: Sendable {
        let copy: @Sendable (CFDictionary) -> (OSStatus, Data?)
        let add: @Sendable (CFDictionary) -> OSStatus
        let update: @Sendable (CFDictionary, CFDictionary) -> OSStatus
        let delete: @Sendable (CFDictionary) -> OSStatus

        static let live = Operations(
            copy: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query, &result)
                return (status, result as? Data)
            },
            add: { SecItemAdd($0, nil) },
            update: { SecItemUpdate($0, $1) },
            delete: { SecItemDelete($0) }
        )
    }

    private let operations: Operations

    init(operations: Operations = .live) {
        self.operations = operations
    }

    func read() throws -> NeteaseSavedSession? {
        var query = identity
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, data) = operations.copy(query as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NeteaseAccountError.keychain(status) }
        guard let data else { throw NeteaseAccountError.invalidSavedSession }
        do {
            let saved = try JSONDecoder().decode(NeteaseSavedSession.self, from: data)
            guard saved.profile.userID > 0 else { throw NeteaseAccountError.invalidSavedSession }
            return saved
        } catch { throw NeteaseAccountError.invalidSavedSession }
    }

    func save(_ session: NeteaseSavedSession) throws {
        let data = try JSONEncoder().encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = operations.update(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = operations.add(item as CFDictionary)
            guard added == errSecSuccess else { throw NeteaseAccountError.keychain(added) }
        } else if status != errSecSuccess {
            throw NeteaseAccountError.keychain(status)
        }
    }

    func delete() throws {
        let status = operations.delete(identity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NeteaseAccountError.keychain(status)
        }
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.elsterlee.NeoMusic.netease.account",
         kSecAttrAccount as String: "session.v1",
         kSecAttrSynchronizable as String: false]
    }
}
