import XCTest
@testable import NeoMusic

@MainActor
final class NeteaseAccountErrorPresentationTests: XCTestCase {
    func testCredentialPermissionFailureHasReadableMessageAndSeparateTechnicalCode() {
        let error = NeteaseAccountError.keychain(-34018)

        XCTAssertTrue(error.localizedDescription.contains("权限"))
        XCTAssertFalse(error.localizedDescription.contains("-34018"))
        XCTAssertEqual(error.technicalDetails, "Keychain OSStatus -34018")
    }

    func testServiceAndNetworkCodesRemainAvailableOutsidePrimaryMessage() {
        let cases: [(NeteaseAccountError, String)] = [
            (.http(503), "HTTP 503"),
            (.server(405), "网易云音乐错误码 405"),
            (.network(.notConnectedToInternet), "NSURLErrorDomain (-1009)")
        ]
        for (error, details) in cases {
            XCTAssertEqual(error.technicalDetails, details)
            XCTAssertNotEqual(error.localizedDescription, details)
        }
        XCTAssertNil(NeteaseAccountError.authenticationRequired.technicalDetails)
    }

    func testTechnicalDetailsFollowLatestFailureAndClearAfterRecoveryAndLogout() async throws {
        var readFailure: NeteaseAccountError? = .keychain(-34018)
        var deleteFailure: NeteaseAccountError?
        var reads = 0
        let profile = NeteaseProfile(userID: 1, nickname: "Preview", avatarURL: nil)
        let account = NeteaseAccount(readSession: {
            reads += 1
            if let readFailure { throw readFailure }
            return nil
        }, saveSession: { _ in }, deleteSession: {
            if let deleteFailure { throw deleteFailure }
        }, validateCredential: { _ in profile }, cachedAvatar: { _ in nil },
           loadAvatar: { _ in Data() }, clearAvatarCache: {})

        await account.restoreCachedContent()
        XCTAssertEqual(account.errorTechnicalDetails, "Keychain OSStatus -34018")

        readFailure = .network(.notConnectedToInternet)
        await account.restoreCachedContent()
        XCTAssertEqual(account.errorTechnicalDetails, "NSURLErrorDomain (-1009)")

        readFailure = nil
        await account.revalidate()
        XCTAssertEqual(reads, 3)
        XCTAssertTrue(account.hasRestored)
        XCTAssertEqual(account.validationState, .signedOut)
        XCTAssertNil(account.error)
        XCTAssertNil(account.errorTechnicalDetails)

        try await account.completeLogin(credential: NeteaseCredential(musicU: "fixture"))
        deleteFailure = .keychain(-25308)
        do {
            try await account.logout()
            XCTFail("Logout should retain the credential failure")
        } catch {
            XCTAssertEqual(error as? NeteaseAccountError, .keychain(-25308))
        }
        XCTAssertEqual(account.errorTechnicalDetails, "Keychain OSStatus -25308")

        deleteFailure = nil
        try await account.logout()
        XCTAssertNil(account.error)
        XCTAssertNil(account.errorTechnicalDetails)
    }

    func testSuccessfulCachedReadClearsPreviousErrorBeforeNetworkValidation() async throws {
        var readFailure: NeteaseAccountError? = .keychain(-34018)
        var validations = 0
        let profile = NeteaseProfile(userID: 1, nickname: "Preview", avatarURL: nil)
        let saved = NeteaseSavedSession(profile: profile, credential: try NeteaseCredential(musicU: "fixture"))
        let account = NeteaseAccount(readSession: {
            if let readFailure { throw readFailure }
            return saved
        }, saveSession: { _ in }, deleteSession: {}, validateCredential: { _ in
            validations += 1
            return profile
        }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {})

        await account.restoreCachedContent()
        XCTAssertNotNil(account.error)
        XCTAssertEqual(account.errorTechnicalDetails, "Keychain OSStatus -34018")

        readFailure = nil
        await account.restoreCachedContent()
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.validationState, .unverified)
        XCTAssertEqual(validations, 0)
        XCTAssertNil(account.error)
        XCTAssertNil(account.errorTechnicalDetails)
    }
}
