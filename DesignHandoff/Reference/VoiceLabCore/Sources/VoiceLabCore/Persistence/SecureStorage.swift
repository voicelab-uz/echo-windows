import CryptoKit
import Foundation
import Security

public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> Data?
    func write(_ data: Data, key: String) throws
    func remove(_ key: String) throws
}

public struct KeychainStore: SecretStore {
    // Nonempty by design: empty Data bridges to a null CFData byte pointer,
    // which legacy macOS Keychain updates interpret as "leave data unchanged".
    // This exact versioned value is not a credential or a SavedSession JSON.
    private static let clearedSession = Data("Echo.session.cleared.v1".utf8)
    private let service: String
    private let accessGroup: String
    private let client: any KeychainClient

    public init(service: String = "uz.voicelab.native", accessGroup: String = "FWCSVFT76D.uz.voicelab.desktop") {
        self.init(service: service, accessGroup: accessGroup, client: SystemKeychainClient())
    }

    init(service: String = "uz.voicelab.native", accessGroup: String = "FWCSVFT76D.uz.voicelab.desktop", client: any KeychainClient) {
        self.service = service
        self.accessGroup = accessGroup
        self.client = client
    }
    private func query(_ key: String, includeAccessGroup: Bool = true) -> [String: Any] {
        var dict: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if includeAccessGroup {
            dict[kSecAttrAccessGroup as String] = accessGroup
        }
        return dict
    }
    public func read(_ key: String) throws -> Data? {
        // Try reading with access group first (new behavior)
        var q = query(key, includeAccessGroup: true)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var (status, result) = client.copyMatching(q)

        // If not found with access group, try legacy query without access group for migration
        if status == errSecItemNotFound {
            var legacyQ = query(key, includeAccessGroup: false)
            legacyQ[kSecReturnData as String] = true
            legacyQ[kSecMatchLimit as String] = kSecMatchLimitOne
            (status, result) = client.copyMatching(legacyQ)

            // If found in legacy location, migrate it to the new access group
            if status == errSecSuccess, let data = result as? Data {
                do {
                    try write(data, key: key)
                    // Delete the legacy item after successful migration
                    _ = client.delete(query(key, includeAccessGroup: false))
                } catch {
                    // Migration failed, but we can still return the data
                }
                if key == "session", data.isEmpty || data == Self.clearedSession { return nil }
                return data
            }
        }

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data else { throw failure(errSecDecode) }
        // Accept the previous empty marker too, for stores that persisted it.
        if key == "session", data.isEmpty || data == Self.clearedSession { return nil }
        return data
    }
    public func write(_ data: Data, key: String) throws {
        let q = query(key, includeAccessGroup: true)
        let status = client.update(q, attributes: [kSecValueData as String: data])
        if status == errSecItemNotFound {
            var insert = q
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = client.add(insert)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }
    public func remove(_ key: String) throws {
        let status = client.delete(query(key, includeAccessGroup: true))
        if status == errSecInvalidOwnerEdit, key == "session" {
            // Legacy macOS Keychain items can allow data updates while denying
            // deletion by a rebuilt app. Erase the credentials through the normal
            // authorized update API; do not alter ownership or broaden the ACL.
            let cleared = client.update(
                query(key, includeAccessGroup: true), attributes: [kSecValueData as String: Self.clearedSession])
            guard cleared == errSecSuccess || cleared == errSecItemNotFound else {
                throw failure(cleared)
            }
            // Do not consume the reset request or complete logout until a fresh
            // read confirms that no credentials remain. New logins update this
            // same item, so no stale credential namespace can become active later.
            guard try read(key) == nil else {
                throw VoiceLabError.storage("Keychain sessiyasini tozalash tasdiqlanmadi.")
            }
            return
        }
        // Also try removing from legacy location without access group
        if status == errSecItemNotFound {
            let legacyStatus = client.delete(query(key, includeAccessGroup: false))
            guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
                throw failure(legacyStatus)
            }
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> VoiceLabError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Security framework error"
        return .storage("Keychain xatosi (\(status)): \(detail)")
    }
}

/// Injectable Security boundary: regression tests never touch the user's Keychain.
protocol KeychainClient: Sendable {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemKeychainClient: KeychainClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Serializes atomic writes, and authenticates every file against its owning account.
public actor LibraryStore {
    private let directory: URL
    private let secrets: any SecretStore
    public init(directory: URL, secrets: any SecretStore = KeychainStore()) {
        self.directory = directory
        self.secrets = secrets
    }
    private func identity(_ accountID: String) -> String {
        SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func key(accountID: String, create: Bool) throws -> SymmetricKey {
        let name = "library-key.\(identity(accountID))"
        if let data = try secrets.read(name) { return SymmetricKey(data: data) }
        guard create else {
            throw VoiceLabError.storage(
                "Lokal ma’lumot uchun shifrlash kaliti topilmadi. Fayl saqlab qolindi.")
        }
        let key = SymmetricKey(size: .bits256)
        try secrets.write(key.withUnsafeBytes { Data($0) }, key: name)
        return key
    }
    public func load(accountID: String) throws -> LibrarySnapshot {
        let url = directory.appendingPathComponent(identity(accountID) + ".sealed")
        guard FileManager.default.fileExists(atPath: url.path) else { return LibrarySnapshot() }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let data = try AES.GCM.open(
            sealed, using: key(accountID: accountID, create: false), authenticating: Data(accountID.utf8))
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else {
            throw VoiceLabError.storage("Lokal ma’lumot versiyasi qo‘llab-quvvatlanmaydi.")
        }
        return snapshot
    }
    public func save(_ snapshot: LibrarySnapshot, accountID: String) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot)
        let sealed = try AES.GCM.seal(
            data, using: key(accountID: accountID, create: true), authenticating: Data(accountID.utf8))
        guard let bytes = sealed.combined else {
            throw VoiceLabError.storage("Ma’lumotni shifrlab bo‘lmadi.")
        }
        let url = directory.appendingPathComponent(identity(accountID) + ".sealed")
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
