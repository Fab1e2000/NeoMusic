import Observation
import XCTest
@testable import NeoMusic

@MainActor
final class AppRuntimeTests: XCTestCase {
    func testApplicationOwnerRestoresDownloadsBeforeAccountWithoutMountingAPage() async {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = NeteaseDownloadTransport(spool: root.appending(path: "Transfers"), configuration: .ephemeral)
        let downloads = NeteaseDownloadStore(directory: root, musicDirectory: root.appending(path: "Music"),
                                             transport: transport)
        var reads = 0
        let account = NeteaseAccount(
            readSession: {
                XCTAssertTrue(downloads.isRestored)
                reads += 1
                return nil
            }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in throw URLError(.badURL) },
            clearAvatarCache: {}, downloads: downloads)
        let runtime = AppRuntime(account: account, container: AppContainer())
        XCTAssertEqual(reads, 0)
        XCTAssertNil(runtime.startupTask)
        runtime.sceneDidChange(from: .background, to: .active)
        XCTAssertEqual(reads, 0)

        runtime.start()
        runtime.start()
        await runtime.startupTask?.value

        XCTAssertEqual(reads, 1)
        XCTAssertTrue(runtime.container.runtime.isInitialPresentationReady)
        XCTAssertTrue(account.hasRestored)
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedOut)
    }

    func testCancellingStartupDuringCredentialReadPreventsAccountPublication() async throws {
        let entered = expectation(description: "Startup reads saved credentials")
        let saved = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Fixture", avatarURL: nil),
                                        credential: try .init(musicU: "fixture"))
        var finishRead: CheckedContinuation<Void, Never>?
        var readWasCancelled = false
        let account = NeteaseAccount(
            readSession: {
                await withCheckedContinuation {
                    finishRead = $0
                    entered.fulfill()
                }
                readWasCancelled = Task.isCancelled
                return saved
            }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in XCTFail("Cancelled startup must not revalidate"); return saved.profile },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {})
        let runtime = AppRuntime(account: account, container: AppContainer())
        let localReady = expectation(description: "Local restore finishes while credentials are pending")
        withObservationTracking {
            _ = runtime.container.runtime.isInitialLibraryReady
        } onChange: {
            localReady.fulfill()
        }
        runtime.start()
        let startup = try XCTUnwrap(runtime.startupTask)
        await fulfillment(of: [entered, localReady], timeout: 5)
        XCTAssertTrue(runtime.container.runtime.isInitialLibraryReady)
        XCTAssertFalse(runtime.container.runtime.isInitialPresentationReady)
        startup.cancel()
        finishRead?.resume()
        await startup.value

        XCTAssertFalse(runtime.container.runtime.isInitialPresentationReady)
        XCTAssertTrue(readWasCancelled)
        XCTAssertFalse(account.hasRestored)
        XCTAssertNil(account.profile)
        XCTAssertEqual(account.restoredPlaybackIdentity, .pending)
    }
}
