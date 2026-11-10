import XCTest
@testable import NeoMusic

@MainActor
final class AppRuntimeTests: XCTestCase {
    func testApplicationOwnerRestoresAccountWithoutMountingAPage() async {
        var reads = 0
        let account = NeteaseAccount(
            readSession: { reads += 1; return nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in throw URLError(.badURL) },
            clearAvatarCache: {})
        let runtime = AppRuntime(account: account)
        XCTAssertEqual(reads, 0)
        XCTAssertNil(runtime.startupTask)
        runtime.sceneDidChange(from: .background, to: .active)
        XCTAssertEqual(reads, 0)

        runtime.start()
        runtime.start()
        await runtime.startupTask?.value
        await runtime.restorationTask?.value

        XCTAssertEqual(reads, 1)
        XCTAssertTrue(account.hasRestored)
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedOut)
    }
}
