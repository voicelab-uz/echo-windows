import Foundation
import Security
import Testing

@testable import VoiceLabCore

/// Models a legacy item whose ACL permits changing data, but rejects deletion.
private final class ResetKeychain: KeychainClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]
    private var mutations: [String] = []
    let deleteStatus: OSStatus
    let updateStatus: OSStatus
    let readStatus: OSStatus
    let ignoresUpdates: Bool

    init(
        items: [String: Data] = ["session": Data("old-secret".utf8)],
        deleteStatus: OSStatus = errSecInvalidOwnerEdit,
        updateStatus: OSStatus = errSecSuccess,
        readStatus: OSStatus = errSecSuccess,
        ignoresUpdates: Bool = false
    ) {
        self.items = items
        self.deleteStatus = deleteStatus
        self.updateStatus = updateStatus
        self.readStatus = readStatus
        self.ignoresUpdates = ignoresUpdates
    }

    private func account(_ query: [String: Any]) -> String {
        #expect(query[kSecAttrService as String] as? String == "uz.voicelab.native")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        return query[kSecAttrAccount as String] as? String ?? "unscoped"
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        lock.withLock {
            guard readStatus == errSecSuccess else { return (readStatus, nil) }
            guard let data = items[account(query)] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = account(query)
            mutations.append(key)
            // Recovery must not modify ownership, access controls, or accessibility.
            #expect(Set(attributes.keys) == [kSecValueData as String])
            guard updateStatus == errSecSuccess else { return updateStatus }
            guard items[key] != nil else { return errSecItemNotFound }
            // Legacy Keychain treats a null data pointer as "keep existing data".
            // An empty Swift Data can bridge to exactly that, with success status.
            if !ignoresUpdates, let data = attributes[kSecValueData as String] as? Data,
                !data.isEmpty
            {
                items[key] = data
            }
            return errSecSuccess
        }
    }
    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = account(attributes)
            guard items[key] == nil else { return errSecDuplicateItem }
            items[key] = attributes[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            let key = account(query)
            if deleteStatus == errSecSuccess { items[key] = nil }
            return deleteStatus
        }
    }
    func value(_ key: String) -> Data? { lock.withLock { items[key] } }
    var updatedKeys: [String] { lock.withLock { mutations } }
}

private struct NoResetNetwork: HTTPTransport {
    func send(_ request: URLRequest, uploadFile: URL?) async throws -> (Data, HTTPURLResponse) {
        Issue.record("Session reset/restoration must not make a network request")
        throw URLError(.notConnectedToInternet)
    }
}

struct KeychainSessionResetTests {
    @Test func ownerDeniedDeletionErasesBothTokensAndDoesNotRestoreOnRestart() async throws {
        let client = ResetKeychain(items: [
            "session": Data(#"{"accessToken":"old-access","refreshToken":"old-refresh"}"#.utf8),
            "installation": Data("stable-installation".utf8),
            "library-key.account": Data(repeating: 7, count: 32),
        ])
        try KeychainStore(client: client).remove("session")
        #expect(client.value("session") == Data("Echo.session.cleared.v1".utf8))
        #expect(client.value("installation") == Data("stable-installation".utf8))
        #expect(client.value("library-key.account") == Data(repeating: 7, count: 32))
        #expect(client.updatedKeys == ["session"])
        let restarted = Authentication(
            http: HTTPClient(transport: NoResetNetwork()), secrets: KeychainStore(client: client))
        #expect(try await restarted.restore() == nil)
    }

    @Test func newLoginReusesClearedItemAndSurvivesAnotherStoreInstance() throws {
        let client = ResetKeychain()
        let store = KeychainStore(client: client)
        try store.remove("session")
        try store.remove("session")  // Replaying an interrupted reset is safe.
        let replacement = Data("new-session-json".utf8)
        try store.write(replacement, key: "session")
        #expect(try KeychainStore(client: client).read("session") == replacement)
        try store.remove("session")
        #expect(try store.read("session") == nil)
    }

    @Test(arguments: [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled])
    func otherDeleteErrorsAreNotSuppressed(_ status: OSStatus) {
        let client = ResetKeychain(deleteStatus: status)
        #expect(throws: VoiceLabError.self) { try KeychainStore(client: client).remove("session") }
        #expect(client.updatedKeys.isEmpty)
        #expect(client.value("session") == Data("old-secret".utf8))
    }

    @Test func deniedOverwriteKeepsResetRetryable() {
        let client = ResetKeychain(updateStatus: errSecAuthFailed)
        #expect(throws: VoiceLabError.self) { try KeychainStore(client: client).remove("session") }
        #expect(client.value("session") == Data("old-secret".utf8))
    }

    @Test func successfulUpdateIsVerifiedBeforeCompletingReset() {
        let client = ResetKeychain(ignoresUpdates: true)
        #expect(throws: VoiceLabError.self) { try KeychainStore(client: client).remove("session") }
    }

    @Test func verificationReadFailureDoesNotClaimSuccess() {
        let client = ResetKeychain(readStatus: errSecInteractionNotAllowed)
        #expect(throws: VoiceLabError.self) { try KeychainStore(client: client).remove("session") }
    }

    @Test func recoveryNeverOverwritesLibraryKeys() {
        let client = ResetKeychain(items: ["library-key.account": Data(repeating: 7, count: 32)])
        #expect(throws: VoiceLabError.self) {
            try KeychainStore(client: client).remove("library-key.account")
        }
        #expect(client.updatedKeys.isEmpty)
    }

    @Test func ordinaryEmptySecretsRemainReadable() throws {
        let client = ResetKeychain(items: [
            "unrelated": Data(), "installation": Data("Echo.session.cleared.v1".utf8),
            "session": Data(),
        ])
        #expect(try KeychainStore(client: client).read("unrelated") == Data())
        #expect(
            try KeychainStore(client: client).read("installation") == Data("Echo.session.cleared.v1".utf8))
        #expect(try KeychainStore(client: client).read("session") == nil)
    }

    @Test func malformedOrUnknownSessionMarkersAreNotSilentlyIgnored() throws {
        let unexpected = Data("Echo.session.cleared.v2".utf8)
        let client = ResetKeychain(items: ["session": unexpected])
        #expect(try KeychainStore(client: client).read("session") == unexpected)
    }

    @Test func ordinaryDeletionAndMissingItemNeedNoOverwrite() throws {
        let client = ResetKeychain(deleteStatus: errSecSuccess)
        try KeychainStore(client: client).remove("session")
        #expect(client.value("session") == nil)
        #expect(client.updatedKeys.isEmpty)
        let missing = ResetKeychain(items: [:], deleteStatus: errSecItemNotFound)
        try KeychainStore(client: missing).remove("session")
        #expect(missing.updatedKeys.isEmpty)
    }
}
