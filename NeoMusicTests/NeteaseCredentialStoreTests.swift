import Foundation
import Security
import Synchronization
import XCTest
@testable import NeoMusic

final class NeteaseCredentialStoreTests: XCTestCase, @unchecked Sendable {
    func testMissingRecordReadAndDeleteAreIdempotent() async throws {
        let keychain = AccountKeychainStub()
        let store = NeteaseCredentialStore(operations: keychain.operations)
        let initial = try await store.read()
        XCTAssertNil(initial)
        try await store.delete()
        let deleted = try await store.read()
        XCTAssertNil(deleted)
        XCTAssertEqual(keychain.state.withLock { $0.deleteCount }, 1)
    }

    func testAddReadUpdateAndDeleteUseDedicatedDeviceLocalRecord() async throws {
        let keychain = AccountKeychainStub()
        let store = NeteaseCredentialStore(operations: keychain.operations)
        let first = try saved(userID: 7)
        try await store.save(first)
        let initial = try await store.read()
        XCTAssertEqual(initial, first)
        let second = try saved(userID: 8)
        try await store.save(second)
        let updated = try await store.read()
        XCTAssertEqual(updated, second)
        let state = keychain.state.withLock { $0 }
        XCTAssertEqual(state.addCount, 1)
        XCTAssertEqual(state.updateCount, 2)
        XCTAssertEqual(state.services, ["com.elsterlee.NeoMusic.netease.account"])
        XCTAssertEqual(state.accounts, ["session.v1"])
        XCTAssertTrue(state.deviceOnly)
        XCTAssertFalse(state.synchronizable)
        try await store.delete()
        let deleted = try await store.read()
        XCTAssertNil(deleted)
    }

    func testReadFailureIsNotTreatedAsMissingRecord() async {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement] {
            let keychain = AccountKeychainStub()
            keychain.state.withLock { $0.copyStatus = status }
            let store = NeteaseCredentialStore(operations: keychain.operations)
            await expectError(.keychain(status)) { _ = try await store.read() }
        }
    }

    func testUnreadableSavedRecordReportsErrorWithoutDeletingIt() async {
        for data in [Data("corrupt".utf8), Data(#"{"profile":{"userID":7,"nickname":"n"},"credential":{"musicU":""}}"#.utf8)] {
            let keychain = AccountKeychainStub()
            keychain.state.withLock { $0.data = data }
            let store = NeteaseCredentialStore(operations: keychain.operations)
            await expectError(.invalidSavedSession) { _ = try await store.read() }
            XCTAssertEqual(keychain.state.withLock { $0.data }, data)
            XCTAssertEqual(keychain.state.withLock { $0.deleteCount }, 0)
        }
    }

    func testSuccessfulCopyWithoutDataIsInvalidRecord() async {
        let keychain = AccountKeychainStub()
        keychain.state.withLock { $0.copyStatus = errSecSuccess }
        let store = NeteaseCredentialStore(operations: keychain.operations)
        await expectError(.invalidSavedSession) { _ = try await store.read() }
    }

    func testFailedUpdatePreservesPreviousCredentialAndDoesNotAdd() async throws {
        let keychain = AccountKeychainStub()
        let store = NeteaseCredentialStore(operations: keychain.operations)
        let first = try saved(userID: 7)
        try await store.save(first)
        keychain.state.withLock { $0.updateStatus = errSecInteractionNotAllowed }
        await expectError(.keychain(errSecInteractionNotAllowed)) { try await store.save(self.saved(userID: 8)) }
        let preserved = try await store.read()
        XCTAssertEqual(preserved, first)
        XCTAssertEqual(keychain.state.withLock { $0.addCount }, 1)
    }

    func testFailedAddAndDeletePropagateSecurityStatus() async throws {
        let keychain = AccountKeychainStub()
        let store = NeteaseCredentialStore(operations: keychain.operations)
        keychain.state.withLock { $0.addStatus = errSecMissingEntitlement }
        await expectError(.keychain(errSecMissingEntitlement)) { try await store.save(self.saved(userID: 7)) }
        let failedAdd = try await store.read()
        XCTAssertNil(failedAdd)
        keychain.state.withLock { $0.addStatus = nil }
        let first = try saved(userID: 7)
        try await store.save(first)
        keychain.state.withLock { $0.deleteStatus = errSecInteractionNotAllowed }
        await expectError(.keychain(errSecInteractionNotAllowed)) { try await store.delete() }
        let preserved = try await store.read()
        XCTAssertEqual(preserved, first)
    }

    private func expectError(_ expected: NeteaseAccountError, operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)") }
        catch { XCTAssertEqual(error as? NeteaseAccountError, expected) }
    }

    private func saved(userID: Int64) throws -> NeteaseSavedSession {
        .init(profile: .init(userID: userID, nickname: "账户\(userID)", avatarURL: nil),
              credential: try .init(musicU: "fixture-\(userID)", csrf: "fixture-csrf"))
    }
}

private final class AccountKeychainStub: Sendable {
    struct State: Sendable {
        var data: Data?
        var copyStatus: OSStatus?
        var addStatus: OSStatus?
        var updateStatus: OSStatus?
        var deleteStatus: OSStatus?
        var addCount = 0
        var updateCount = 0
        var deleteCount = 0
        var services: Set<String> = []
        var accounts: Set<String> = []
        var deviceOnly = false
        var synchronizable = true

        mutating func record(_ query: CFDictionary) {
            let values = query as NSDictionary
            if let service = values[kSecAttrService] as? String { services.insert(service) }
            if let account = values[kSecAttrAccount] as? String { accounts.insert(account) }
            synchronizable = values[kSecAttrSynchronizable] as? Bool ?? true
        }
    }
    let state = Mutex(State())

    var operations: NeteaseCredentialStore.Operations {
        .init(copy: { [self] query in
            state.withLock {
                $0.record(query)
                return ($0.copyStatus ?? ($0.data == nil ? errSecItemNotFound : errSecSuccess), $0.data)
            }
        }, add: { [self] query in
            state.withLock {
                $0.record(query)
                $0.addCount += 1
                if let status = $0.addStatus { return status }
                $0.data = (query as NSDictionary)[kSecValueData] as? Data
                $0.deviceOnly = (query as NSDictionary)[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
                return errSecSuccess
            }
        }, update: { [self] query, attributes in
            state.withLock {
                $0.record(query)
                $0.updateCount += 1
                if let status = $0.updateStatus { return status }
                guard $0.data != nil else { return errSecItemNotFound }
                $0.data = (attributes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            }
        }, delete: { [self] query in
            state.withLock {
                $0.record(query)
                $0.deleteCount += 1
                if let status = $0.deleteStatus { return status }
                guard $0.data != nil else { return errSecItemNotFound }
                $0.data = nil
                return errSecSuccess
            }
        })
    }
}
