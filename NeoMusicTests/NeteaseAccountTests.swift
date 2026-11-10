import Foundation
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import NeoMusic

@MainActor
final class NeteaseAccountTests: XCTestCase {
    private let first = NeteaseProfile(userID: 1, nickname: "First", avatarURL: nil)
    private let second = NeteaseProfile(userID: 2, nickname: "Second", avatarURL: nil)

    private func credential(_ value: String) throws -> NeteaseCredential {
        try NeteaseCredential(musicU: value)
    }

    func testCachedContentRestorationFinishesBeforeNetworkValidation() async throws {
        let storage = AccountTestStorage()
        storage.saved = NeteaseSavedSession(profile: first, credential: try credential("saved"))
        let network = AccountTestRequest<NeteaseProfile>()
        var validations = 0
        let account = makeAccount(storage, validate: { _ in
            validations += 1
            return try await network.value()
        })
        await account.restoreCachedContent()
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(account.validationState, .unverified)
        XCTAssertEqual(validations, 0)
        XCTAssertEqual(storage.reads, 1)

        let validation = Task { await account.revalidate() }
        await network.started.wait()
        // A foreground validation must not turn the completed cache phase into a network wait.
        await account.restoreCachedContent()
        XCTAssertEqual(storage.reads, 1)
        XCTAssertEqual(validations, 1)
        network.finish(.success(first))
        await validation.value
        XCTAssertEqual(account.validationState, .valid)
    }

    func testEmptyOrUnreadableCredentialFinishesCachePhaseWithoutNetwork() async {
        for fails in [false, true] {
            let storage = AccountTestStorage()
            if fails { storage.readError = NeteaseAccountError.keychain(-1) }
            let account = makeAccount(storage, validate: { _ in
                XCTFail("The cache phase must not validate credentials")
                return self.first
            })
            await account.restoreCachedContent()
            XCTAssertNil(account.profile)
            XCTAssertEqual(storage.reads, 1)
            XCTAssertEqual(account.validationState, fails ? .unverified : .signedOut)
            XCTAssertEqual(account.error != nil, fails)
            XCTAssertEqual(storage.deletions, 0)
            XCTAssertEqual(account.restoredPlaybackIdentity, fails ? .pending : .signedOut)
        }
    }

    func testTransientCredentialReadRetainsQueueSnapshotUntilIdentityRecovery() async throws {
        let storage = AccountTestStorage()
        storage.saved = NeteaseSavedSession(profile: first, credential: try credential("saved"))
        storage.readError = NeteaseAccountError.keychain(-25308)
        let account = makeAccount(storage, validate: { _ in self.first })
        let url = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let song = LibrarySongItem(id: "netease:1:9", title: "Saved song", artist: "Saved artist",
                                  album: "", albumArtist: "", trackNumber: 0, artwork: .file(URL(fileURLWithPath: "/tmp/saved-cover.jpg")))
        let saved = NowPlayingModel.SavedQueue(ids: [song.id], index: 0, elapsed: 32,
            repeatMode: .off, shuffled: false, songs: [PlaybackSongSnapshot(song)])
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        defer { player.shutdownPlayback(); try? FileManager.default.removeItem(at: url) }
        player.configurePlayback(resolveURL: { _ in nil }, persistenceURL: url)
        XCTAssertTrue(player.restoreQueue(songs: [], restoredState: .success(saved)))

        await account.restoreCachedContent()
        XCTAssertEqual(account.restoredPlaybackIdentity, .pending)
        player.saveQueueForBackground()
        await player.flushQueuePersistence()
        let retained = try JSONDecoder().decode(NowPlayingModel.SavedQueue.self, from: Data(contentsOf: url))
        XCTAssertEqual(retained.songs?.first?.title, song.title)
        XCTAssertEqual(retained.elapsed, 32)
        XCTAssertFalse(player.hasAudioEngine)

        storage.readError = nil
        await account.restoreCachedContent()
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedIn("1"))
        guard case let .signedIn(owner) = account.restoredPlaybackIdentity else {
            return XCTFail("Recovered credentials must publish the saved owner")
        }
        player.restoreOnlineIdentity(ownerID: owner)
        XCTAssertEqual(player.current.title, song.title)
        XCTAssertEqual(player.current.artist, song.artist)
        XCTAssertEqual(player.current.artwork, song.artwork)
        XCTAssertEqual(player.elapsed, 32)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.hasAudioEngine)
        XCTAssertEqual(storage.reads, 2)
        XCTAssertEqual(storage.deletions, 0)
        await player.flushQueuePersistence()
    }

    func testLibraryCacheRestorationLeavesHomeForItsIndependentPhase() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = NeteaseHomeStore(directory: directory)
        let saved = NeteaseSavedSession(profile: first, credential: try credential("saved"))
        var validations = 0
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in validations += 1; return self.first }, cachedAvatar: { _ in nil },
            loadAvatar: { _ in Data() }, clearAvatarCache: {}, home: home)

        await account.restoreCachedContent()
        XCTAssertEqual(account.profile, first)
        XCTAssertNil(home.userID)
        XCTAssertEqual(validations, 0)

        await account.restoreHomeCachedContent()
        XCTAssertEqual(home.userID, first.userID)
        XCTAssertEqual(validations, 0)
        XCTAssertEqual(account.validationState, .unverified)
    }

    func testLogoutWaitsForCacheReadAndRejectsItsLateSession() async throws {
        let storage = AccountTestStorage()
        storage.saved = NeteaseSavedSession(profile: first, credential: try credential("saved"))
        let read = AccountTestRequest<Void>()
        storage.beforeRead = { try await read.value() }
        let account = makeAccount(storage, validate: { _ in
            XCTFail("Cancelled cache restoration must not validate credentials")
            return self.first
        })
        let restoration = Task { await account.restoreCachedContent() }
        await read.started.wait()
        let loggingOut = expectation(description: "Logout cancels cached session restoration")
        _ = withObservationTracking { account.isLoggingOut } onChange: { loggingOut.fulfill() }
        let logout = Task { try await account.logout() }
        await fulfillment(of: [loggingOut], timeout: 2)
        read.finish(.success(()))
        await restoration.value
        try await logout.value
        XCTAssertNil(account.profile)
        XCTAssertNil(storage.saved)
        XCTAssertEqual(account.validationState, .signedOut)
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedOut)
    }

    private func makeAccount(_ storage: AccountTestStorage,
                             validate: @escaping @MainActor (NeteaseCredential) async throws -> NeteaseProfile,
                             cached: @escaping @MainActor (URL) async -> Data? = { _ in nil },
                             avatar: @escaping @MainActor (URL) async throws -> Data = { _ in Data() },
                             startupAvatar: NeteaseAvatarSnapshot? = nil) -> NeteaseAccount {
        NeteaseAccount(readSession: { try await storage.read() },
                       saveSession: { try await storage.save($0) },
                       deleteSession: { try await storage.delete() },
                       validateCredential: validate, cachedAvatar: cached, loadAvatar: avatar,
                       clearAvatarCache: { storage.clearAvatars() },
                       startupAvatar: startupAvatar,
                       saveAvatarSnapshot: { await storage.saveAvatar($0, profile: $1) })
    }

    func testServiceAuthenticationErrorPreservesValidCredential() async throws {
        let storage = AccountTestStorage()
        var requests = 0
        let account = makeAccount(storage) { _ in requests += 1; return self.first }
        try await account.completeLogin(credential: credential("valid"))
        await account.recheckAuthentication()
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(account.profile?.userID, first.userID)
        XCTAssertEqual(storage.saved?.profile.userID, first.userID)
        XCTAssertEqual(account.validationState, .valid)
        XCTAssertNil(account.error)
    }

    func testServiceAuthenticationRecheckClearsExpiredCredential() async throws {
        let storage = AccountTestStorage()
        var expired = false
        let account = makeAccount(storage) { _ in
            if expired { throw NeteaseAccountError.authenticationRequired }
            return self.first
        }
        try await account.completeLogin(credential: credential("expired"))
        expired = true
        await account.recheckAuthentication()
        XCTAssertNil(storage.saved)
        XCTAssertEqual(account.validationState, .requiresLogin)
        XCTAssertNotNil(account.error)
    }

    func testInitializationHasNoSideEffectsAndEmptyRestoreDoesNotRequestAccount() async {
        let storage = AccountTestStorage()
        var requests = 0
        let account = makeAccount(storage) { _ in requests += 1; return self.first }
        XCTAssertEqual(storage.reads, 0)
        XCTAssertEqual(requests, 0)
        await account.restore()
        await account.restore()
        await account.revalidate()
        XCTAssertEqual(storage.reads, 1)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(account.profile)
        XCTAssertEqual(account.validationState, .signedOut)
    }

    func testStartupSnapshotRendersBeforeRestoreAndSurvivesPendingKeychainRead() async throws {
        let storage = AccountTestStorage()
        let url = try XCTUnwrap(URL(string: "https://example.com/startup.png"))
        let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: url)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 38, height: 38), format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 38, height: 38))
        }
        let snapshot = NeteaseAvatarSnapshot(userID: profile.userID, avatarURL: url, data: bytes)
        storage.avatarSnapshot = snapshot
        storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
        let read = AccountTestRequest<Void>()
        storage.beforeRead = { try await read.value() }
        var validations = 0
        let account = makeAccount(storage, validate: { _ in
            validations += 1
            return profile
        }, avatar: { _ in bytes }, startupAvatar: snapshot)

        XCTAssertNil(account.profile)
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertEqual(storage.reads, 0)
        XCTAssertEqual(validations, 0)
        let renderer = ImageRenderer(content: AccountAvatar(account: account, size: 38))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        assertRedCenter(of: image)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Account avatar before Keychain restoration"
        attachment.lifetime = .keepAlways
        add(attachment)

        let restore = Task { await account.restore() }
        await read.started.wait()
        XCTAssertNil(account.profile)
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertEqual(validations, 0)
        XCTAssertEqual(storage.cacheClears, 0)
        read.finish(.success(()))
        await restore.value
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertEqual(account.validationState, .valid)
    }

    func testMatchingStartupSnapshotRemainsVisibleWhileValidationAndAvatarRefreshArePending() async throws {
        let storage = AccountTestStorage()
        let url = try XCTUnwrap(URL(string: "https://example.com/startup.png"))
        let profile = NeteaseProfile(userID: 1, nickname: "Updated name", avatarURL: url)
        let original = Data([11, 12, 13]), refreshed = Data([21, 22, 23])
        let snapshot = NeteaseAvatarSnapshot(userID: profile.userID, avatarURL: url, data: original)
        storage.avatarSnapshot = snapshot
        storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
        let validation = AccountTestRequest<NeteaseProfile>()
        let image = AccountTestRequest<Data>()
        let saved = AccountTestSignal()
        storage.afterSnapshotSave = { _ in saved.open() }
        let account = makeAccount(storage, validate: { _ in try await validation.value() },
                                  avatar: { _ in try await image.value() }, startupAvatar: snapshot)
        let restore = Task { await account.restore() }
        await validation.started.wait()
        await image.started.wait()
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.avatarData, original)
        XCTAssertEqual(account.validationState, .validating)
        XCTAssertEqual(storage.cacheClears, 0)
        image.finish(.success(refreshed))
        await saved.wait()
        XCTAssertEqual(account.avatarData, refreshed)
        XCTAssertEqual(storage.avatarSnapshot?.data, refreshed)
        XCTAssertEqual(account.validationState, .validating)
        validation.finish(.success(profile))
        await restore.value
        XCTAssertEqual(account.avatarData, refreshed)
        XCTAssertEqual(storage.cacheClears, 0)
    }

    func testMissingCredentialClearsStartupSnapshotAndItsCache() async throws {
        let storage = AccountTestStorage()
        let url = try XCTUnwrap(URL(string: "https://example.com/startup.png"))
        let snapshot = NeteaseAvatarSnapshot(userID: first.userID, avatarURL: url, data: Data([11, 12, 13]))
        storage.avatarSnapshot = snapshot
        let account = makeAccount(storage, validate: { _ in
            XCTFail("No credential must not start account validation")
            return self.first
        }, avatar: { _ in
            XCTFail("No credential must not refresh an avatar")
            return Data()
        }, startupAvatar: snapshot)
        XCTAssertNotNil(account.avatarData)
        await account.restore()
        XCTAssertNil(account.profile)
        XCTAssertNil(account.avatarData)
        XCTAssertNil(storage.avatarSnapshot)
        XCTAssertEqual(account.validationState, .signedOut)
        XCTAssertEqual(storage.cacheClears, 1)
        XCTAssertTrue(storage.snapshotWrites.isEmpty)
    }

    func testStartupSnapshotIsClearedForDifferentOwnerOrMissingAvatarURL() async throws {
        let originalURL = try XCTUnwrap(URL(string: "https://example.com/startup.png"))
        let snapshot = NeteaseAvatarSnapshot(userID: 1, avatarURL: originalURL, data: Data([11, 12, 13]))
        let profiles = [
            NeteaseProfile(userID: 2, nickname: "Other account", avatarURL: originalURL),
            NeteaseProfile(userID: 1, nickname: "No avatar", avatarURL: nil)
        ]
        for profile in profiles {
            let storage = AccountTestStorage()
            storage.avatarSnapshot = snapshot
            storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
            let validation = AccountTestRequest<NeteaseProfile>()
            let image = AccountTestRequest<Data>()
            let imageReturned = AccountTestSignal()
            let account = makeAccount(storage, validate: { _ in try await validation.value() }, avatar: { _ in
                defer { imageReturned.open() }
                return try await image.value()
            }, startupAvatar: snapshot)
            let restore = Task { await account.restore() }
            await validation.started.wait()
            XCTAssertEqual(account.profile, profile)
            XCTAssertNil(account.avatarData)
            XCTAssertNil(storage.avatarSnapshot)
            XCTAssertEqual(storage.cacheClears, 1)
            if profile.avatarURL != nil {
                await image.started.wait()
                image.finish(.failure(URLError(.notConnectedToInternet)))
                await imageReturned.wait()
            }
            validation.finish(.failure(URLError(.notConnectedToInternet)))
            await restore.value
            XCTAssertNil(account.avatarData)
            XCTAssertEqual(account.validationState, .unverified)
            XCTAssertTrue(storage.snapshotWrites.isEmpty)
        }
    }

    func testSameOwnerStartupSnapshotSurvivesChangedURLUntilRefreshSucceeds() async throws {
        let originalURL = try XCTUnwrap(URL(string: "https://p4.music.126.net/avatar.png"))
        let refreshedURL = try XCTUnwrap(URL(string: "https://p3.music.126.net/avatar.png"))
        let original = Data([11, 12, 13]), refreshed = Data([21, 22, 23])
        let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: refreshedURL)
        let snapshot = NeteaseAvatarSnapshot(userID: profile.userID, avatarURL: originalURL, data: original)
        for succeeds in [false, true] {
            let storage = AccountTestStorage()
            storage.avatarSnapshot = snapshot
            storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
            let validation = AccountTestRequest<NeteaseProfile>()
            let image = AccountTestRequest<Data>()
            let retryImage = AccountTestRequest<Data>()
            let imageReturned = AccountTestSignal()
            let snapshotSaved = AccountTestSignal()
            var requestedURLs: [URL] = []
            var validationCount = 0
            storage.afterSnapshotSave = { _ in snapshotSaved.open() }
            let account = makeAccount(storage, validate: { _ in
                validationCount += 1
                if validationCount == 1 { return try await validation.value() }
                return profile
            }, avatar: { url in
                requestedURLs.append(url)
                defer { imageReturned.open() }
                if requestedURLs.count == 1 { return try await image.value() }
                return try await retryImage.value()
            }, startupAvatar: snapshot)
            let restore = Task { await account.restore() }
            await validation.started.wait()
            await image.started.wait()
            XCTAssertEqual(account.profile, profile)
            XCTAssertEqual(account.avatarData, original)
            XCTAssertEqual(storage.avatarSnapshot?.avatarURL, originalURL)
            XCTAssertEqual(storage.avatarSnapshot?.data, original)
            XCTAssertEqual(storage.cacheClears, 0)
            XCTAssertTrue(storage.snapshotWrites.isEmpty)
            XCTAssertEqual(requestedURLs, [refreshedURL])
            validation.finish(.success(profile))
            await restore.value

            if succeeds {
                image.finish(.success(refreshed))
                await snapshotSaved.wait()
            } else {
                image.finish(.failure(URLError(.notConnectedToInternet)))
                await imageReturned.wait()
            }
            XCTAssertEqual(account.avatarData, succeeds ? refreshed : original)
            XCTAssertEqual(storage.avatarSnapshot?.data, succeeds ? refreshed : original)
            XCTAssertEqual(storage.avatarSnapshot?.avatarURL, succeeds ? refreshedURL : originalURL)
            XCTAssertEqual(storage.snapshotWrites.count, succeeds ? 1 : 0)
            XCTAssertEqual(storage.cacheClears, 0)
            XCTAssertEqual(account.validationState, .valid)

            if !succeeds {
                let retry = Task { await account.revalidate() }
                await retryImage.started.wait()
                XCTAssertEqual(requestedURLs, [refreshedURL, refreshedURL])
                XCTAssertEqual(account.avatarData, original)
                XCTAssertEqual(storage.avatarSnapshot?.avatarURL, originalURL)
                XCTAssertTrue(storage.snapshotWrites.isEmpty)
                XCTAssertEqual(storage.cacheClears, 0)
                retryImage.finish(.success(refreshed))
                await snapshotSaved.wait()
                await retry.value
                XCTAssertEqual(account.avatarData, refreshed)
                XCTAssertEqual(storage.avatarSnapshot?.data, refreshed)
                XCTAssertEqual(storage.avatarSnapshot?.avatarURL, refreshedURL)
                XCTAssertEqual(storage.snapshotWrites.map(\.data), [refreshed])
                XCTAssertEqual(storage.cacheClears, 0)
                XCTAssertEqual(validationCount, 2)
            }
        }
    }

    func testValidationChangingAvatarURLKeepsImageAndRejectsLatePreviousURLResponse() async throws {
        let storage = AccountTestStorage()
        let originalURL = try XCTUnwrap(URL(string: "https://p4.music.126.net/avatar.png"))
        let refreshedURL = try XCTUnwrap(URL(string: "https://p3.music.126.net/avatar.png"))
        let originalProfile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: originalURL)
        let refreshedProfile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: refreshedURL)
        let original = Data([11, 12, 13]), stale = Data([31, 32, 33]), refreshed = Data([21, 22, 23])
        let snapshot = NeteaseAvatarSnapshot(userID: originalProfile.userID, avatarURL: originalURL, data: original)
        storage.avatarSnapshot = snapshot
        storage.saved = NeteaseSavedSession(profile: originalProfile, credential: try credential("saved"))
        let validation = AccountTestRequest<NeteaseProfile>()
        let oldImage = AccountTestRequest<Data>()
        let newImage = AccountTestRequest<Data>()
        let snapshotSaved = AccountTestSignal()
        var requestedURLs: [URL] = []
        storage.afterSnapshotSave = { _ in snapshotSaved.open() }
        let account = makeAccount(storage, validate: { _ in try await validation.value() }, avatar: { url in
            requestedURLs.append(url)
            if url == originalURL { return try await oldImage.value() }
            XCTAssertEqual(url, refreshedURL)
            return try await newImage.value()
        }, startupAvatar: snapshot)
        let restore = Task { await account.restore() }
        await validation.started.wait()
        await oldImage.started.wait()
        XCTAssertEqual(account.avatarData, original)
        validation.finish(.success(refreshedProfile))
        await oldImage.cancelled.wait()
        XCTAssertEqual(account.profile, refreshedProfile)
        XCTAssertEqual(account.avatarData, original)
        XCTAssertEqual(storage.avatarSnapshot?.avatarURL, originalURL)
        XCTAssertEqual(storage.cacheClears, 0)
        XCTAssertEqual(requestedURLs, [originalURL])

        oldImage.finish(.success(stale))
        await newImage.started.wait()
        await restore.value
        XCTAssertEqual(requestedURLs, [originalURL, refreshedURL])
        XCTAssertEqual(account.avatarData, original)
        XCTAssertEqual(storage.avatarSnapshot?.data, original)
        XCTAssertTrue(storage.snapshotWrites.isEmpty)
        XCTAssertEqual(storage.cacheClears, 0)

        newImage.finish(.success(refreshed))
        await snapshotSaved.wait()
        XCTAssertEqual(account.avatarData, refreshed)
        XCTAssertEqual(storage.avatarSnapshot?.avatarURL, refreshedURL)
        XCTAssertEqual(storage.avatarSnapshot?.data, refreshed)
        XCTAssertEqual(storage.snapshotWrites.map(\.data), [refreshed])
        XCTAssertEqual(storage.cacheClears, 0)
        XCTAssertEqual(account.validationState, .valid)
    }

    func testKeychainReadFailureKeepsStartupSnapshotUntilCredentialCanBeRead() async throws {
        let storage = AccountTestStorage()
        let url = try XCTUnwrap(URL(string: "https://example.com/startup.png"))
        let bytes = Data([11, 12, 13])
        let snapshot = NeteaseAvatarSnapshot(userID: first.userID, avatarURL: url, data: bytes)
        storage.avatarSnapshot = snapshot
        storage.readError = NeteaseAccountError.keychain(-1)
        let account = makeAccount(storage, validate: { _ in
            XCTFail("Failed credential read must not start validation")
            return self.first
        }, startupAvatar: snapshot)
        await account.restore()
        XCTAssertNil(account.profile)
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertEqual(storage.avatarSnapshot?.data, bytes)
        XCTAssertEqual(account.validationState, .unverified)
        XCTAssertNotNil(account.error)
        XCTAssertEqual(storage.cacheClears, 0)
        XCTAssertEqual(storage.deletions, 0)
    }

    func testLogoutWaitsForPendingSnapshotWriteThenClearsItsLateCommit() async throws {
        let storage = AccountTestStorage()
        let url = try XCTUnwrap(URL(string: "https://example.com/first.png"))
        let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: url)
        let bytes = Data([11, 12, 13])
        storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
        let write = AccountTestRequest<Void>()
        storage.beforeSnapshotSave = { _ in _ = try? await write.value() }
        let account = makeAccount(storage, validate: { _ in profile }, avatar: { _ in bytes })
        await account.restore()
        await write.started.wait()
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertTrue(storage.snapshotWrites.isEmpty)
        let logout = Task { try await account.logout() }
        await write.cancelled.wait()
        XCTAssertTrue(account.isLoggingOut)
        XCTAssertEqual(storage.deletions, 0)
        XCTAssertEqual(storage.cacheClears, 0)
        write.finish(.success(()))
        try await logout.value
        XCTAssertEqual(storage.snapshotWrites.map(\.userID), [profile.userID])
        XCTAssertEqual(storage.avatarEvents, ["saved:1", "cleared"])
        XCTAssertNil(storage.avatarSnapshot)
        XCTAssertNil(account.avatarData)
        XCTAssertNil(account.profile)
        XCTAssertNil(storage.saved)
        XCTAssertEqual(account.validationState, .signedOut)
    }

    func testAccountSwitchWaitsForPendingSnapshotWriteBeforePublishingNewAvatar() async throws {
        let storage = AccountTestStorage()
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/first.png"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/second.png"))
        let firstProfile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: firstURL)
        let secondProfile = NeteaseProfile(userID: 2, nickname: "Second", avatarURL: secondURL)
        let firstBytes = Data([11, 12, 13]), secondBytes = Data([21, 22, 23])
        let firstCredential = try credential("first")
        storage.saved = NeteaseSavedSession(profile: firstProfile, credential: firstCredential)
        let write = AccountTestRequest<Void>()
        let secondSaved = AccountTestSignal()
        storage.beforeSnapshotSave = { snapshot in
            if snapshot.userID == firstProfile.userID { _ = try? await write.value() }
        }
        storage.afterSnapshotSave = { snapshot in
            if snapshot.userID == secondProfile.userID { secondSaved.open() }
        }
        let account = makeAccount(storage,
                                  validate: { $0 == firstCredential ? firstProfile : secondProfile },
                                  avatar: { $0 == firstURL ? firstBytes : secondBytes })
        await account.restore()
        await write.started.wait()
        let replacement = Task { try await account.completeLogin(credential: credential("second")) }
        await write.cancelled.wait()
        XCTAssertEqual(account.profile, firstProfile)
        XCTAssertEqual(storage.saved?.profile, firstProfile)
        XCTAssertEqual(storage.cacheClears, 0)
        write.finish(.success(()))
        try await replacement.value
        await secondSaved.wait()
        XCTAssertEqual(account.profile, secondProfile)
        XCTAssertEqual(account.avatarData, secondBytes)
        XCTAssertEqual(storage.avatarSnapshot?.userID, secondProfile.userID)
        XCTAssertEqual(storage.avatarSnapshot?.avatarURL, secondURL)
        XCTAssertEqual(storage.avatarSnapshot?.data, secondBytes)
        XCTAssertEqual(storage.avatarEvents, ["saved:1", "cleared", "saved:2"])
        XCTAssertEqual(storage.snapshotWrites.map(\.userID), [firstProfile.userID, secondProfile.userID])
    }

    private func assertRedCenter(of image: UIImage, file: StaticString = #filePath, line: UInt = #line) {
        guard let image = image.cgImage else {
            XCTFail("The native avatar render must contain image pixels", file: file, line: line)
            return
        }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        XCTAssertTrue(rendered, file: file, line: line)
        let center = (image.height / 2 * image.width + image.width / 2) * 4
        XCTAssertGreaterThan(pixels[center], 240, file: file, line: line)
        XCTAssertLessThan(pixels[center + 1], 15, file: file, line: line)
        XCTAssertLessThan(pixels[center + 2], 15, file: file, line: line)
        XCTAssertGreaterThan(pixels[center + 3], 240, file: file, line: line)
    }

    func testRestoreAndForegroundValidationJoinTheSameRequest() async throws {
        let storage = AccountTestStorage()
        storage.saved = NeteaseSavedSession(profile: first, credential: try credential("saved"))
        let request = AccountTestRequest<NeteaseProfile>()
        var requests = 0
        let account = makeAccount(storage) { _ in requests += 1; return try await request.value() }
        let original = Task { await account.restore() }
        await request.started.wait()
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(account.validationState, .validating)
        let restoring = AccountTestSignal(), foregrounding = AccountTestSignal()
        let duplicate = Task { restoring.open(); await account.restore() }
        let foreground = Task { foregrounding.open(); await account.revalidate() }
        await restoring.wait()
        await foregrounding.wait()
        request.finish(.success(first))
        await original.value
        await duplicate.value
        await foreground.value
        XCTAssertEqual(storage.reads, 1)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(account.validationState, .valid)
        XCTAssertNil(account.error)
        XCTAssertEqual(storage.cacheClears, 0)
    }

    func testRestorePublishesSavedAvatarWhileAccountValidationIsPending() async throws {
        let storage = AccountTestStorage()
        let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: URL(string: "https://example.com/restored.png"))
        storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
        let validation = AccountTestRequest<NeteaseProfile>()
        let image = AccountTestRequest<Data>()
        let imageReturned = AccountTestSignal()
        let bytes = Data([1, 2, 3])
        let account = makeAccount(storage, validate: { _ in try await validation.value() }, avatar: { _ in
            defer { imageReturned.open() }
            return try await image.value()
        })
        let restore = Task { await account.restore() }
        await validation.started.wait()
        await image.started.wait()
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.validationState, .validating)
        XCTAssertNil(account.avatarData)
        image.finish(.success(bytes))
        await imageReturned.wait()
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertEqual(account.validationState, .validating)
        XCTAssertTrue(storage.writes.isEmpty)
        validation.finish(.success(profile))
        await restore.value
        XCTAssertEqual(account.validationState, .valid)
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertNil(account.error)
    }

    func testRestorePublishesCachedAvatarBeforeNetworkAndKeepsItUntilAuthenticationFails() async throws {
        let storage = AccountTestStorage()
        let url = try XCTUnwrap(URL(string: "https://example.com/cached.png"))
        let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: url)
        storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
        let validation = AccountTestRequest<NeteaseProfile>()
        let image = AccountTestRequest<Data>()
        let imageReturned = AccountTestSignal()
        let bytes = Data([4, 5, 6])
        let account = makeAccount(storage, validate: { _ in try await validation.value() }, cached: {
            XCTAssertEqual($0, url)
            return bytes
        }, avatar: { _ in
            defer { imageReturned.open() }
            return try await image.value()
        })
        let restore = Task { await account.restore() }
        await validation.started.wait()
        await image.started.wait()
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.validationState, .validating)
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertTrue(storage.writes.isEmpty)
        image.finish(.failure(URLError(.notConnectedToInternet)))
        await imageReturned.wait()
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertEqual(account.validationState, .validating)
        XCTAssertEqual(storage.cacheClears, 0)
        validation.finish(.failure(NeteaseAccountError.authenticationRequired))
        await restore.value
        XCTAssertEqual(account.validationState, .requiresLogin)
        XCTAssertNil(account.avatarData)
        XCTAssertNil(storage.saved)
        XCTAssertEqual(storage.cacheClears, 1)
    }

    func testAuthenticationFailureClearsRestoredAvatarAndRejectsItsLateResponse() async throws {
        for imageFinishesFirst in [true, false] {
            let storage = AccountTestStorage()
            let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: URL(string: "https://example.com/restored.png"))
            storage.saved = NeteaseSavedSession(profile: profile, credential: try credential("expired"))
            let validation = AccountTestRequest<NeteaseProfile>()
            let image = AccountTestRequest<Data>()
            let imageReturned = AccountTestSignal()
            let bytes = Data([1, 2, 3])
            let account = makeAccount(storage, validate: { _ in try await validation.value() }, avatar: { _ in
                defer { imageReturned.open() }
                return try await image.value()
            })
            let restore = Task { await account.restore() }
            await validation.started.wait()
            await image.started.wait()
            if imageFinishesFirst {
                image.finish(.success(bytes))
                await imageReturned.wait()
                XCTAssertEqual(account.avatarData, bytes)
            }
            validation.finish(.failure(NeteaseAccountError.authenticationRequired))
            if !imageFinishesFirst {
                await image.cancelled.wait()
                XCTAssertEqual(account.validationState, .requiresLogin)
                XCTAssertEqual(storage.cacheClears, 0)
                image.finish(.success(bytes))
            }
            await restore.value
            XCTAssertEqual(account.validationState, .requiresLogin)
            XCTAssertNil(account.avatarData)
            XCTAssertNil(storage.saved)
            XCTAssertEqual(storage.deletions, 1)
            XCTAssertTrue(storage.writes.isEmpty)
            XCTAssertEqual(storage.cacheClears, 1)
        }
    }

    func testOfflineValidationKeepsAvatarLoadedFromRestoredProfile() async throws {
        let storage = AccountTestStorage()
        let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: URL(string: "https://example.com/restored.png"))
        let saved = NeteaseSavedSession(profile: profile, credential: try credential("saved"))
        storage.saved = saved
        let validation = AccountTestRequest<NeteaseProfile>()
        let image = AccountTestRequest<Data>()
        let imageReturned = AccountTestSignal()
        let bytes = Data([1, 2, 3])
        let account = makeAccount(storage, validate: { _ in try await validation.value() }, avatar: { _ in
            defer { imageReturned.open() }
            return try await image.value()
        })
        let restore = Task { await account.restore() }
        await validation.started.wait()
        await image.started.wait()
        image.finish(.success(bytes))
        await imageReturned.wait()
        XCTAssertEqual(account.avatarData, bytes)
        validation.finish(.failure(URLError(.notConnectedToInternet)))
        await restore.value
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.validationState, .unverified)
        XCTAssertEqual(account.avatarData, bytes)
        XCTAssertNotNil(account.error)
        XCTAssertEqual(storage.saved, saved)
        XCTAssertEqual(storage.deletions, 0)
        XCTAssertTrue(storage.writes.isEmpty)
        XCTAssertEqual(storage.cacheClears, 0)
    }

    func testReadFailureIsReportedAndCanBeRetriedWithoutErasingCredential() async throws {
        let storage = AccountTestStorage()
        let saved = NeteaseSavedSession(profile: first, credential: try credential("saved"))
        storage.saved = saved
        storage.readError = NeteaseAccountError.keychain(-1)
        let account = makeAccount(storage) { _ in self.first }
        await account.restore()
        XCTAssertEqual(account.validationState, .unverified)
        XCTAssertNotNil(account.error)
        XCTAssertEqual(storage.saved, saved)
        XCTAssertEqual(storage.deletions, 0)
        storage.readError = nil
        await account.restore()
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(account.validationState, .valid)
    }

    func testTemporaryFailuresPreserveSavedAccountAndSuccessfulRetryRefreshesIt() async throws {
        let failures: [Error] = [URLError(.notConnectedToInternet), URLError(.timedOut),
                                 NeteaseAccountError.http(503), NeteaseAccountError.invalidResponse]
        for failure in failures {
            let storage = AccountTestStorage()
            let saved = NeteaseSavedSession(profile: first, credential: try credential("saved"))
            storage.saved = saved
            storage.validationError = failure
            let refreshed = NeteaseProfile(userID: first.userID, nickname: "Updated", avatarURL: nil)
            let account = makeAccount(storage) { _ in
                if let failure = storage.validationError { throw failure }
                return refreshed
            }
            await account.restore()
            XCTAssertEqual(account.profile, first)
            XCTAssertEqual(account.validationState, .unverified)
            XCTAssertNotNil(account.error)
            XCTAssertEqual(storage.saved, saved)
            XCTAssertEqual(storage.deletions, 0)
            storage.validationError = nil
            await account.revalidate()
            XCTAssertEqual(account.profile, refreshed)
            XCTAssertEqual(account.validationState, .valid)
            XCTAssertNil(account.error)
        }
    }

    func testExplicitAuthenticationFailureRequiresLoginAndRemovesCredential() async throws {
        let storage = AccountTestStorage()
        storage.saved = NeteaseSavedSession(profile: first, credential: try credential("expired"))
        var requests = 0
        let account = makeAccount(storage) { _ in requests += 1; throw NeteaseAccountError.authenticationRequired }
        await account.restore()
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(account.validationState, .requiresLogin)
        XCTAssertNotNil(account.error)
        XCTAssertNil(storage.saved)
        XCTAssertEqual(storage.deletions, 1)
        await account.revalidate()
        XCTAssertEqual(requests, 1)
    }

    func testSuccessfulLoginPersistsAndNewAccountInstanceRestoresIt() async throws {
        let storage = AccountTestStorage()
        let account = makeAccount(storage) { _ in self.first }
        try await account.completeLogin(credential: credential("first"))
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(account.validationState, .valid)
        XCTAssertFalse(account.isAuthenticating)
        let restored = makeAccount(storage) { _ in self.first }
        XCTAssertNil(restored.profile)
        await restored.restore()
        XCTAssertEqual(restored.profile, first)
        XCTAssertEqual(restored.validationState, .valid)
    }

    func testCandidateValidationAndPersistenceFailuresKeepThePreviousAccount() async throws {
        let storage = AccountTestStorage()
        let oldCredential = try credential("first")
        let account = makeAccount(storage) { credential in
            if credential == oldCredential { return self.first }
            if let failure = storage.validationError { throw failure }
            return self.second
        }
        try await account.completeLogin(credential: oldCredential)
        let oldSaved = storage.saved
        let oldCacheClears = storage.cacheClears
        storage.validationError = NeteaseAccountError.authenticationRequired
        do { try await account.completeLogin(credential: credential("second")); XCTFail("Expected rejection") }
        catch { XCTAssertEqual(error as? NeteaseAccountError, .authenticationRequired) }
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(account.validationState, .valid)
        XCTAssertEqual(storage.saved, oldSaved)
        XCTAssertEqual(storage.cacheClears, oldCacheClears)
        storage.validationError = nil
        storage.saveError = NeteaseAccountError.keychain(-1)
        do { try await account.completeLogin(credential: credential("second")); XCTFail("Expected save failure") }
        catch { XCTAssertEqual(error as? NeteaseAccountError, .keychain(-1)) }
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(storage.saved, oldSaved)
        XCTAssertNotNil(account.error)
        XCTAssertEqual(storage.cacheClears, oldCacheClears)
        storage.saveError = nil
        try await account.completeLogin(credential: credential("second"))
        XCTAssertEqual(account.profile, second)
        XCTAssertEqual(storage.saved?.profile, second)
        XCTAssertEqual(storage.cacheClears, oldCacheClears + 1)
    }

    func testLogoutWaitsForCancelledValidationAndRejectsItsLateSuccess() async throws {
        let storage = AccountTestStorage()
        let request = AccountTestRequest<NeteaseProfile>()
        let account = makeAccount(storage) { _ in try await request.value() }
        let login = Task { try await account.completeLogin(credential: credential("first")) }
        await request.started.wait()
        let logout = Task { try await account.logout() }
        await request.cancelled.wait()
        XCTAssertTrue(account.isLoggingOut)
        XCTAssertEqual(storage.deletions, 0)
        request.finish(.success(first))
        if case .success = await login.result { XCTFail("Cancelled login must fail") }
        try await logout.value
        XCTAssertNil(account.profile)
        XCTAssertNil(storage.saved)
        XCTAssertTrue(storage.writes.isEmpty)
        XCTAssertEqual(account.validationState, .signedOut)
    }

    func testNewLoginWaitsForOlderLoginAndOnlyNewCredentialIsPublished() async throws {
        let storage = AccountTestStorage()
        let request = AccountTestRequest<NeteaseProfile>()
        let oldCredential = try credential("first")
        var requests = 0
        let account = makeAccount(storage) { credential in
            requests += 1
            if credential == oldCredential { return try await request.value() }
            return self.second
        }
        let older = Task { try await account.completeLogin(credential: oldCredential) }
        await request.started.wait()
        let newer = Task { try await account.completeLogin(credential: credential("second")) }
        await request.cancelled.wait()
        XCTAssertEqual(requests, 1)
        request.finish(.success(first))
        if case .success = await older.result { XCTFail("Older login must be cancelled") }
        try await newer.value
        XCTAssertEqual(account.profile, second)
        XCTAssertEqual(storage.writes.map(\.profile), [second])
    }

    func testCancelDuringCredentialSaveRestoresPreviousCredentialBeforeReturning() async throws {
        let storage = AccountTestStorage()
        let oldCredential = try credential("first")
        let account = makeAccount(storage) { $0 == oldCredential ? self.first : self.second }
        try await account.completeLogin(credential: oldCredential)
        let oldSaved = storage.saved
        let oldCacheClears = storage.cacheClears
        let write = AccountTestRequest<Void>()
        storage.beforeSave = { value in if value.profile.userID == self.second.userID { try await write.value() } }
        let login = Task { try await account.completeLogin(credential: credential("second")) }
        await write.started.wait()
        login.cancel()
        await write.cancelled.wait()
        XCTAssertEqual(account.profile, first)
        write.finish(.success(()))
        if case .success = await login.result { XCTFail("Cancelled save must roll back") }
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(storage.saved, oldSaved)
        XCTAssertEqual(storage.writes.suffix(2).map(\.profile), [second, first])
        XCTAssertNil(account.error)
        XCTAssertEqual(storage.cacheClears, oldCacheClears)
    }

    func testLogoutDuringSaveWaitsForRollbackThenDeletesCredential() async throws {
        let storage = AccountTestStorage()
        let write = AccountTestRequest<Void>()
        storage.beforeSave = { _ in try await write.value() }
        let account = makeAccount(storage) { _ in self.first }
        let login = Task { try await account.completeLogin(credential: credential("first")) }
        await write.started.wait()
        let logout = Task { try await account.logout() }
        await write.cancelled.wait()
        XCTAssertEqual(storage.deletions, 0)
        XCTAssertTrue(account.isLoggingOut)
        write.finish(.success(()))
        if case .success = await login.result { XCTFail("Cancelled login must fail") }
        try await logout.value
        XCTAssertNil(storage.saved)
        XCTAssertNil(account.profile)
        XCTAssertEqual(account.validationState, .signedOut)
    }

    func testLogoutDeletionFailureKeepsProfileAndRetryRemovesSavedSession() async throws {
        let storage = AccountTestStorage()
        let account = makeAccount(storage) { _ in self.first }
        try await account.completeLogin(credential: credential("first"))
        let oldCacheClears = storage.cacheClears
        storage.deleteError = NeteaseAccountError.keychain(-1)
        do { try await account.logout(); XCTFail("Expected failed logout") }
        catch { XCTAssertEqual(error as? NeteaseAccountError, .keychain(-1)) }
        XCTAssertEqual(account.profile, first)
        XCTAssertNotNil(storage.saved)
        XCTAssertNotNil(account.error)
        XCTAssertFalse(account.isLoggingOut)
        XCTAssertEqual(storage.cacheClears, oldCacheClears)
        storage.deleteError = nil
        try await account.logout()
        XCTAssertNil(account.profile)
        XCTAssertEqual(storage.cacheClears, oldCacheClears + 1)
        let restored = makeAccount(storage) { _ in XCTFail("Logged-out account must not validate"); return self.first }
        await restored.restore()
        XCTAssertNil(restored.profile)
        XCTAssertEqual(restored.validationState, .signedOut)
        XCTAssertEqual(storage.cacheClears, oldCacheClears + 1)
    }

    func testFailedLogoutRestoresAccountOwnedServices() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "failed-logout-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = AccountTestStorage()
        storage.saved = NeteaseSavedSession(profile: first, credential: try credential("first"))
        let music = NeteaseMusicStore(directory: directory, defaults: defaults)
        let search = NeteaseSearchStore(defaults: defaults)
        let account = NeteaseAccount(readSession: { try await storage.read() },
            saveSession: { try await storage.save($0) }, deleteSession: { try await storage.delete() },
            validateCredential: { _ in self.first }, cachedAvatar: { _ in nil },
            loadAvatar: { _ in Data() }, clearAvatarCache: {}, music: music, search: search)
        await account.restoreCachedContent()
        search.record("Account query", scope: "online")
        storage.deleteError = NeteaseAccountError.keychain(-1)

        do { try await account.logout(); XCTFail("Expected failed logout") }
        catch { XCTAssertEqual(error as? NeteaseAccountError, .keychain(-1)) }

        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(music.userID, first.userID)
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedIn(String(first.userID)))
        XCTAssertEqual(search.history, ["Account query"])
        XCTAssertNotNil(account.error)

        storage.deleteError = nil
        try await account.logout()
        XCTAssertNil(music.userID)
        XCTAssertTrue(search.history.isEmpty)
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedOut)
    }

    func testNewLoginWaitsForCancelledSaveRollbackBeforePublishingNextAccount() async throws {
        let storage = AccountTestStorage()
        let firstCredential = try credential("first"), secondCredential = try credential("second")
        let third = NeteaseProfile(userID: 3, nickname: "Third", avatarURL: nil)
        var requests = 0
        let account = makeAccount(storage) {
            requests += 1
            if $0 == firstCredential { return self.first }
            return $0 == secondCredential ? self.second : third
        }
        try await account.completeLogin(credential: firstCredential)
        let write = AccountTestRequest<Void>()
        storage.beforeSave = { value in if value.profile.userID == self.second.userID { try await write.value() } }
        let older = Task { try await account.completeLogin(credential: secondCredential) }
        await write.started.wait()
        let newer = Task { try await account.completeLogin(credential: credential("third")) }
        await write.cancelled.wait()
        XCTAssertEqual(requests, 2)
        write.finish(.success(()))
        if case .success = await older.result { XCTFail("Cancelled write must roll back") }
        try await newer.value
        XCTAssertEqual(account.profile, third)
        XCTAssertEqual(storage.saved?.profile, third)
        XCTAssertEqual(storage.writes.map(\.profile), [first, second, first, third])
    }

    func testSwitchWaitsForOldRevalidationAndRejectsItsLateProfile() async throws {
        let storage = AccountTestStorage()
        let request = AccountTestRequest<NeteaseProfile>()
        let firstCredential = try credential("first")
        let account = makeAccount(storage) { credential in
            if credential != firstCredential { return self.second }
            if storage.requiresValidationGate { return try await request.value() }
            return self.first
        }
        try await account.completeLogin(credential: firstCredential)
        storage.requiresValidationGate = true
        let validation = Task { await account.revalidate() }
        await request.started.wait()
        let replacement = Task { try await account.completeLogin(credential: credential("second")) }
        await request.cancelled.wait()
        XCTAssertEqual(account.profile, first)
        XCTAssertEqual(storage.writes.count, 1)
        request.finish(.success(NeteaseProfile(userID: 1, nickname: "Late", avatarURL: nil)))
        await validation.value
        try await replacement.value
        XCTAssertEqual(account.profile, second)
        XCTAssertEqual(storage.writes.map(\.profile), [first, second])
    }

    func testLogoutDuringCredentialReadWaitsAndNeverRestoresOldProfile() async throws {
        let storage = AccountTestStorage()
        storage.saved = NeteaseSavedSession(profile: first, credential: try credential("first"))
        let read = AccountTestRequest<Void>()
        storage.beforeRead = { try await read.value() }
        var requests = 0
        let account = makeAccount(storage) { _ in requests += 1; return self.first }
        let restore = Task { await account.restore() }
        await read.started.wait()
        let logout = Task { try await account.logout() }
        await read.cancelled.wait()
        XCTAssertEqual(storage.deletions, 0)
        read.finish(.success(()))
        await restore.value
        try await logout.value
        XCTAssertEqual(requests, 0)
        XCTAssertNil(account.profile)
        XCTAssertNil(storage.saved)
    }

    func testAvatarFailureKeepsValidatedAccountUsable() async throws {
        let storage = AccountTestStorage()
        let finished = AccountTestSignal()
        let profile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: URL(string: "https://example.com/a.png"))
        let account = makeAccount(storage, validate: { _ in profile }, avatar: { _ in
            defer { finished.open() }
            throw URLError(.notConnectedToInternet)
        })
        try await account.completeLogin(credential: credential("first"))
        await finished.wait()
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.validationState, .valid)
        XCTAssertNil(account.error)
        XCTAssertNil(account.avatarData)
    }

    func testSwitchWaitsForOldAvatarAndDoesNotPublishLateImage() async throws {
        let storage = AccountTestStorage()
        let image = AccountTestRequest<Data>()
        let avatarProfile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: URL(string: "https://example.com/a.png"))
        let oldCredential = try credential("first")
        let account = makeAccount(storage, validate: { $0 == oldCredential ? avatarProfile : self.second },
                                  avatar: { _ in try await image.value() })
        try await account.completeLogin(credential: oldCredential)
        let oldCacheClears = storage.cacheClears
        await image.started.wait()
        let replacement = Task { try await account.completeLogin(credential: credential("second")) }
        await image.cancelled.wait()
        XCTAssertEqual(account.profile, avatarProfile)
        XCTAssertEqual(storage.writes.count, 1)
        XCTAssertEqual(storage.cacheClears, oldCacheClears)
        image.finish(.success(Data([1, 2, 3])))
        try await replacement.value
        XCTAssertEqual(account.profile, second)
        XCTAssertNil(account.avatarData)
        XCTAssertEqual(storage.cacheClears, oldCacheClears + 1)
    }

    func testLogoutWaitsForAvatarAndAvatarFailureDoesNotInvalidateAccount() async throws {
        let storage = AccountTestStorage()
        let image = AccountTestRequest<Data>()
        let avatarProfile = NeteaseProfile(userID: 1, nickname: "First", avatarURL: URL(string: "https://example.com/a.png"))
        let account = makeAccount(storage, validate: { _ in avatarProfile }, avatar: { _ in try await image.value() })
        try await account.completeLogin(credential: credential("first"))
        await image.started.wait()
        XCTAssertEqual(account.validationState, .valid)
        XCTAssertFalse(account.isAuthenticating)
        let logout = Task { try await account.logout() }
        await image.cancelled.wait()
        XCTAssertEqual(storage.deletions, 0)
        image.finish(.failure(URLError(.notConnectedToInternet)))
        try await logout.value
        XCTAssertNil(account.avatarData)
        XCTAssertNil(account.error)
        XCTAssertNil(account.profile)
    }

    func testRollbackFailureIsReportedAndLogoutCanClearTheRemainingCredential() async throws {
        let storage = AccountTestStorage()
        let write = AccountTestRequest<Void>()
        storage.beforeSave = { _ in try await write.value() }
        storage.deleteError = NeteaseAccountError.keychain(-1)
        let account = makeAccount(storage) { _ in self.first }
        let login = Task { try await account.completeLogin(credential: credential("first")) }
        await write.started.wait()
        login.cancel()
        await write.cancelled.wait()
        write.finish(.success(()))
        if case .success = await login.result { XCTFail("Rollback failure must be reported") }
        XCTAssertNil(account.profile)
        XCTAssertNotNil(account.error)
        XCTAssertNotNil(storage.saved)
        storage.deleteError = nil
        try await account.logout()
        XCTAssertNil(storage.saved)
        XCTAssertNil(account.error)
    }
}

@MainActor
private final class AccountTestStorage {
    var saved: NeteaseSavedSession?
    var reads = 0
    var writes: [NeteaseSavedSession] = []
    var deletions = 0
    var cacheClears = 0
    var avatarSnapshot: NeteaseAvatarSnapshot?
    var snapshotWrites: [NeteaseAvatarSnapshot] = []
    var avatarEvents: [String] = []
    var readError: Error?
    var saveError: Error?
    var deleteError: Error?
    var validationError: Error?
    var requiresValidationGate = false
    var beforeRead: (@MainActor () async throws -> Void)?
    var beforeSave: (@MainActor (NeteaseSavedSession) async throws -> Void)?
    var beforeSnapshotSave: (@MainActor (NeteaseAvatarSnapshot) async -> Void)?
    var afterSnapshotSave: (@MainActor (NeteaseAvatarSnapshot) -> Void)?

    func read() async throws -> NeteaseSavedSession? {
        reads += 1
        if let readError { throw readError }
        try await beforeRead?()
        return saved
    }
    func save(_ value: NeteaseSavedSession) async throws {
        if let saveError { throw saveError }
        try await beforeSave?(value)
        saved = value
        writes.append(value)
    }
    func delete() async throws {
        if let deleteError { throw deleteError }
        deletions += 1
        saved = nil
    }

    func saveAvatar(_ data: Data, profile: NeteaseProfile) async {
        guard let url = profile.avatarURL else { return }
        let snapshot = NeteaseAvatarSnapshot(userID: profile.userID, avatarURL: url, data: data)
        await beforeSnapshotSave?(snapshot)
        avatarSnapshot = snapshot
        snapshotWrites.append(snapshot)
        avatarEvents.append("saved:\(profile.userID)")
        afterSnapshotSave?(snapshot)
    }

    func clearAvatars() {
        cacheClears += 1
        avatarSnapshot = nil
        avatarEvents.append("cleared")
    }
}

@MainActor
private final class AccountTestSignal {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private final class AccountTestRequest<Value: Sendable> {
    let started = AccountTestSignal()
    let cancelled = AccountTestSignal()
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started.open()
            }
        } onCancel: {
            Task { @MainActor in self.cancelled.open() }
        }
    }
    func finish(_ result: Result<Value, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
