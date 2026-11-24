import Foundation
import Observation

@MainActor @Observable
final class NeteaseAccount {
    let music: NeteaseMusicStore?
    let home: NeteaseHomeStore?
    let artists: NeteaseArtistStore?
    let downloads: NeteaseDownloadStore?
    let search: NeteaseSearchStore?

    enum ValidationState: Equatable {
        case signedOut, validating, valid, unverified, requiresLogin
    }

    enum RestoredPlaybackIdentity: Equatable {
        case pending, signedOut, signedIn(String)
    }

    var restoredPlaybackIdentity: RestoredPlaybackIdentity {
        guard hasRestored, !isAuthenticating, !isLoggingOut else { return .pending }
        guard let session else { return .signedOut }
        let owner = session.profile.userID
        guard music == nil || music?.userID == owner else { return .pending }
        return .signedIn(String(owner))
    }

    private(set) var profile: NeteaseProfile?
    var sessionOwnerID: Int64? { session?.profile.userID }
    private(set) var avatarData: Data?
    var startupAvatarData: Data? { startupAvatar?.data }
    private(set) var validationState = ValidationState.signedOut
    private(set) var error: String? {
        didSet { errorTechnicalDetails = nil }
    }
    private(set) var errorTechnicalDetails: String?
    private(set) var isAuthenticating = false
    private(set) var isLoggingOut = false

    @ObservationIgnored private let readSession: @MainActor () async throws -> NeteaseSavedSession?
    @ObservationIgnored private let saveSession: @MainActor (NeteaseSavedSession) async throws -> Void
    @ObservationIgnored private let deleteSession: @MainActor () async throws -> Void
    @ObservationIgnored private let validateCredential: @MainActor (NeteaseCredential) async throws -> NeteaseProfile
    @ObservationIgnored private let cachedAvatar: @MainActor (URL) async -> Data?
    @ObservationIgnored private let loadAvatar: @MainActor (URL) async throws -> Data
    @ObservationIgnored private let clearAvatarCache: @MainActor () -> Void
    @ObservationIgnored private let saveAvatarSnapshot: @MainActor (Data, NeteaseProfile) async -> Void
    @ObservationIgnored private var accountTransport: NeteaseAccountClient?
    @ObservationIgnored private var startupAvatar: NeteaseAvatarSnapshot?
    @ObservationIgnored private var session: NeteaseSavedSession?
    private(set) var hasRestored = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var validationID: UUID?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var loginID: UUID?
    @ObservationIgnored private var loginTask: Task<Void, Error>?
    @ObservationIgnored private var loginRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var postLoginRefresh: Task<Void, Never>?
    @ObservationIgnored private var logoutID: UUID?
    @ObservationIgnored private var logoutTask: Task<Void, Error>?
    @ObservationIgnored private var avatarID: UUID?
    @ObservationIgnored private var avatarTask: Task<Void, Never>?
    @ObservationIgnored private var avatarOwner: NeteaseProfile?
    @ObservationIgnored private var avatarDataURL: URL?

    init(readSession: @escaping @MainActor () async throws -> NeteaseSavedSession?,
         saveSession: @escaping @MainActor (NeteaseSavedSession) async throws -> Void,
         deleteSession: @escaping @MainActor () async throws -> Void,
         validateCredential: @escaping @MainActor (NeteaseCredential) async throws -> NeteaseProfile,
         cachedAvatar: @escaping @MainActor (URL) async -> Data?,
         loadAvatar: @escaping @MainActor (URL) async throws -> Data,
         clearAvatarCache: @escaping @MainActor () -> Void,
         startupAvatar: NeteaseAvatarSnapshot? = nil,
         music: NeteaseMusicStore? = nil,
         home: NeteaseHomeStore? = nil,
         artists: NeteaseArtistStore? = nil,
         downloads: NeteaseDownloadStore? = nil,
         search: NeteaseSearchStore? = nil,
         saveAvatarSnapshot: @escaping @MainActor (Data, NeteaseProfile) async -> Void = { _, _ in }) {
        self.music = music
        self.home = home
        self.artists = artists
        self.downloads = downloads
        self.search = search
        self.readSession = readSession
        self.saveSession = saveSession
        self.deleteSession = deleteSession
        self.validateCredential = validateCredential
        self.cachedAvatar = cachedAvatar
        self.loadAvatar = loadAvatar
        self.clearAvatarCache = clearAvatarCache
        self.startupAvatar = startupAvatar
        self.avatarData = startupAvatar?.data
        self.avatarDataURL = startupAvatar?.avatarURL
        self.saveAvatarSnapshot = saveAvatarSnapshot
        for scope in [music?.sessionScope, home?.sessionScope, artists?.sessionScope,
                      downloads?.sessionScope, search?.sessionScope].compactMap({ $0 }) {
            scope.onAuthenticationRequired = { [weak self] in
                guard let self else { return }
                let revision = generation
                let currentValidation = validationTask
                Task { [weak self] in
                    await currentValidation?.value
                    guard let self, generation == revision else { return }
                    await recheckAuthentication()
                }
            }
        }
    }

    convenience init(client: NeteaseAccountClient, credentialStore: NeteaseCredentialStore,
                     avatarClient: NeteaseAvatarClient,
                     avatarSnapshotStore: NeteaseAvatarSnapshotStore = NeteaseAvatarSnapshotStore()) {
        let musicClient = NeteaseMusicClient(transport: client)
        self.init(readSession: { try await credentialStore.read() },
                  saveSession: { try await credentialStore.save($0) },
                  deleteSession: { try await credentialStore.delete() },
                  validateCredential: { try await client.profile(credential: $0) },
                  cachedAvatar: { await avatarClient.cachedData(for: $0) },
                  loadAvatar: { try await avatarClient.data(for: $0) },
                  clearAvatarCache: {
                      avatarSnapshotStore.clear()
                      avatarClient.clearCache()
                  },
                  startupAvatar: avatarSnapshotStore.load(),
                  music: NeteaseMusicStore(client: musicClient),
                  home: NeteaseHomeStore(client: musicClient),
                  artists: NeteaseArtistStore(client: musicClient),
                  downloads: NeteaseDownloadStore(client: musicClient),
                  search: NeteaseSearchStore(client: NeteaseSearchClient(transport: client)),
                  saveAvatarSnapshot: { await avatarSnapshotStore.save($0, for: $1) })
        accountTransport = client
    }

    func restore() async {
        if let logoutTask { _ = await logoutTask.result; return }
        if let validationTask { await validationTask.value; return }
        guard !hasRestored, !isAuthenticating, !Task.isCancelled else { return }
        await validate(restoring: true)
    }

    func restoreCachedContent() async {
        guard !hasRestored, !isAuthenticating, !Task.isCancelled else { return }
        if let logoutTask { _ = await logoutTask.result; return }
        if let validationTask { await validationTask.value; return }
        await validate(restoring: true, refreshContent: false, validateSession: false)
    }

    func restoreHomeCachedContent() async {
        guard hasRestored, !isAuthenticating, !Task.isCancelled else { return }
        if let logoutTask { _ = await logoutTask.result; return }
        await validate(restoring: false, validateSession: false)
    }

    func revalidate() async {
        if let logoutTask { _ = await logoutTask.result; return }
        guard !isAuthenticating, !Task.isCancelled else { return }
        if !hasRestored {
            await restoreCachedContent()
            guard hasRestored, !Task.isCancelled else { return }
        }
        guard session != nil else { await downloads?.activate(nil); await home?.activate(nil); await artists?.activate(nil); await search?.activate(nil); return }
        await validate(restoring: false)
    }

    func recheckAuthentication() async {
        guard session != nil, logoutTask == nil, !isAuthenticating, !Task.isCancelled else { return }
        await validate(restoring: false, refreshContent: false)
    }

    private func validate(restoring: Bool, refreshContent: Bool = true, validateSession: Bool = true) async {
        if let validationTask { await validationTask.value; return }
        let id = UUID(), revision = generation
        validationID = id
        let task = Task { [self] in
            defer {
                if validationID == id { validationTask = nil; validationID = nil }
            }
            var previousState = validationState
            do {
                if restoring {
                    AppLogger.account.notice("account.read.begin")
                    let restored = try await readSession()
                    try Task.checkCancellation()
                    guard validationID == id, generation == revision else { return }
                    session = restored
                    profile = session?.profile
                    if validateSession { await activateContent(session, refresh: false) }
                    else { await activateLibraryContent(session, refresh: false) }
                    guard validationID == id, generation == revision, !Task.isCancelled else { return }
                    if let startupAvatar,
                       profile.map({ startupAvatar.belongs(to: $0) && $0.avatarURL != nil }) != true {
                        self.startupAvatar = nil
                        avatarData = nil
                        avatarDataURL = nil
                        clearAvatarCache()
                    }
                    hasRestored = true
                    error = nil
                    AppLogger.account.notice("account.read.success signedIn=\(self.session != nil)")
                    previousState = session == nil ? .signedOut : .unverified
                    if validateSession { refreshAvatar() }
                }
                if !restoring, refreshContent {
                    await home?.activate(session, refresh: false)
                    guard validationID == id, generation == revision, !Task.isCancelled else { return }
                }
                guard validateSession else { validationState = previousState; return }
                guard let saved = session else { validationState = .signedOut; error = nil; await home?.activate(nil); await artists?.activate(nil); await search?.activate(nil); return }
                validationState = .validating
                error = nil
                let refreshed = try await validateCredential(saved.credential)
                try Task.checkCancellation()
                guard validationID == id, generation == revision else { return }
                let updated = NeteaseSavedSession(profile: refreshed, credential: saved.credential)
                try await persist(updated, replacing: saved) {
                    self.validationID == id && self.generation == revision
                }
                session = updated
                profile = refreshed
                validationState = .valid
                refreshAvatar()
                guard refreshContent else { return }
                await activateContent(updated)
            } catch is CancellationError {
                AppLogger.account.notice("account.readOrValidate.cancelled")
                if validationID == id, generation == revision { validationState = previousState }
            } catch {
                guard validationID == id, generation == revision else { return }
                if let failure = error as? CredentialRollbackFailure {
                    validationState = .unverified
                    self.setError(failure)
                    return
                }
                guard !Task.isCancelled else { return }
                if restoring, !hasRestored {
                    let status: String
                    if case let .keychain(code)? = error as? NeteaseAccountError { status = "keychain:\(code)" }
                    else { status = "read" }
                    AppLogger.account.notice("account.read.failed category=\(status, privacy: .public)")
                }
                if error as? NeteaseAccountError == .authenticationRequired {
                    let oldRefresh = postLoginRefresh
                    oldRefresh?.cancel()
                    let cleared = await transitionStores(to: nil) {
                        validationID == id && generation == revision && !Task.isCancelled
                    }
                    guard cleared else { return }
                    await oldRefresh?.value
                    guard validationID == id, generation == revision, !Task.isCancelled else { return }
                    endCookieSession()
                    session = nil
                    validationState = .requiresLogin
                    self.setError(error)
                    let oldAvatar = avatarTask
                    avatarID = nil
                    oldAvatar?.cancel()
                    await oldAvatar?.value
                    guard validationID == id, generation == revision, !Task.isCancelled else { return }
                    avatarTask = nil
                    avatarData = nil
                    avatarDataURL = nil
                    avatarOwner = nil
                    startupAvatar = nil
                    clearAvatarCache()
                    do { try await deleteSession() }
                    catch {
                        if validationID == id, generation == revision {
                            self.setError(error, message: "登录已失效，清除保存的凭据失败。\(error.localizedDescription)")
                        }
                    }
                } else {
                    validationState = .unverified
                    self.setError(error)
                    guard refreshContent, !restoring || hasRestored else { return }
                    await activateContent(session)
                }
            }
        }
        validationTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func activateContent(_ session: NeteaseSavedSession?, refresh: Bool = true) async {
        guard !Task.isCancelled else { return }
        async let homeContent: Void? = home?.activate(session, refresh: refresh)
        await activateLibraryContent(session, refresh: refresh)
        _ = await homeContent
    }

    private func activateLibraryContent(_ session: NeteaseSavedSession?, refresh: Bool) async {
        guard !Task.isCancelled else { return }
        await downloads?.activate(session)
        guard !Task.isCancelled else { return }
        await search?.activate(session)
        guard !Task.isCancelled else { return }
        async let artistContent: Void? = artists?.activate(session, refresh: refresh)
        if let session { await music?.activate(session, refresh: refresh) }
        _ = await artistContent
    }

    private func transitionStores(to session: NeteaseSavedSession?, clearSignedOutMusic: Bool = true,
        whileCurrent: () -> Bool) async -> Bool {
        guard whileCurrent() else { return false }
        await home?.activate(session, refresh: false)
        guard whileCurrent() else { return false }
        await artists?.activate(session, refresh: false)
        guard whileCurrent() else { return false }
        if let session {
            await music?.activate(session, refresh: false)
            guard whileCurrent() else { return false }
        }
        await downloads?.activate(session)
        guard whileCurrent() else { return false }
        await search?.activate(session)
        guard whileCurrent() else { return false }
        if session == nil, clearSignedOutMusic { await music?.activate(nil, refresh: false) }
        return whileCurrent()
    }

    private func refreshAfterLogin() {
        let revision = generation
        postLoginRefresh = Task { [self] in
            defer { if generation == revision { postLoginRefresh = nil } }
            guard generation == revision, !Task.isCancelled else { return }
            async let homeRefresh: Void? = home?.refresh(force: false)
            async let libraryRefresh: Void? = music?.refresh()
            async let artistRefresh: Void? = artists?.refresh()
            _ = await (homeRefresh, libraryRefresh, artistRefresh)
        }
    }

    func completeLogin(credential: NeteaseCredential) async throws {
        if let logoutTask { try await logoutTask.value }
        try Task.checkCancellation()
        let id = UUID()
        let previousLogin = loginTask
        previousLogin?.cancel()
        loginRecoveryTask?.cancel()
        loginID = id
        isAuthenticating = true
        error = nil
        let task = Task { [self] in
            defer {
                if loginID == id { loginTask = nil; loginID = nil; isAuthenticating = false }
            }
            do {
                if case .failure(let failure as CredentialRollbackFailure) = await previousLogin?.result {
                    throw failure
                }
                try checkLogin(id)
                loginRecoveryTask = nil
                let candidate = try await validateCredential(credential)
                try checkLogin(id)

                generation += 1
                let oldRefresh = postLoginRefresh
                oldRefresh?.cancel()
                let oldValidation = validationTask, oldAvatar = avatarTask
                validationID = nil
                avatarID = nil
                oldValidation?.cancel()
                oldAvatar?.cancel()
                let cleared = await transitionStores(to: nil) {
                    loginID == id && logoutID == nil && !Task.isCancelled
                }
                guard cleared else { throw CancellationError() }
                await oldValidation?.value
                await oldAvatar?.value
                await oldRefresh?.value
                try checkLogin(id)
                postLoginRefresh = nil
                validationTask = nil
                avatarTask = nil
                let saved = NeteaseSavedSession(profile: candidate, credential: credential)
                try await persist(saved, replacing: session) { self.loginID == id && self.logoutID == nil }
                if session?.profile.userID != candidate.userID { clearAvatarCache() }
                if session?.credential.musicU != credential.musicU { endCookieSession() }
                session = saved
                profile = candidate
                hasRestored = true
                validationState = .valid
                error = nil
                refreshAvatar()
                await activateContent(saved, refresh: false)
                try checkLogin(id)
                refreshAfterLogin()
            } catch {
                if loginID == id {
                    let recovery = Task { [self] in
                        guard loginID == id, logoutID == nil, !Task.isCancelled else { return }
                        await activateContent(session, refresh: false)
                    }
                    loginRecoveryTask = recovery
                    await recovery.value
                    guard loginID == id, logoutID == nil else { throw CancellationError() }
                    loginRecoveryTask = nil
                    if validationID == nil { validationTask = nil }
                    if avatarID == nil { avatarTask = nil }
                    if validationState == .validating { validationState = .unverified }
                    if error is CredentialRollbackFailure || (!(error is CancellationError) && !Task.isCancelled) {
                        self.setError(error)
                    }
                }
                throw error
            }
        }
        loginTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func checkLogin(_ id: UUID) throws {
        try Task.checkCancellation()
        guard loginID == id, logoutID == nil else { throw CancellationError() }
    }

    func cancelLogin() async {
        let revision = generation
        let task = loginTask
        loginID = nil
        task?.cancel()
        let recovery = loginRecoveryTask
        recovery?.cancel()
        let result = await task?.result
        await recovery?.value
        if loginID == nil {
            loginTask = nil
            loginRecoveryTask = nil
            isAuthenticating = false
            let restored = await transitionStores(to: session, clearSignedOutMusic: false) {
                generation == revision && loginID == nil && logoutID == nil && !Task.isCancelled
            }
            guard restored else { return }
            if validationID == nil { validationTask = nil }
            if avatarID == nil { avatarTask = nil }
            if validationState == .validating, validationID == nil { validationState = .unverified }
            if case .failure(let failure as CredentialRollbackFailure) = result { setError(failure) }
        }
    }

    func logout() async throws {
        if let logoutTask { try await logoutTask.value; return }
        let id = UUID()
        logoutID = id
        generation += 1
        loginID = nil
        validationID = nil
        avatarID = nil
        isLoggingOut = true
        isAuthenticating = false
        error = nil
        let oldRefresh = postLoginRefresh
        oldRefresh?.cancel()
        let oldLogin = loginTask, oldValidation = validationTask, oldAvatar = avatarTask
        oldLogin?.cancel()
        loginRecoveryTask?.cancel()
        oldValidation?.cancel()
        oldAvatar?.cancel()
        let task = Task { [self] in
            defer {
                if logoutID == id { logoutTask = nil; logoutID = nil; isLoggingOut = false }
            }
            guard await transitionStores(to: nil, whileCurrent: { logoutID == id }) else { return }
            _ = await oldLogin?.result
            await oldValidation?.value
            await oldAvatar?.value
            await oldRefresh?.value
            postLoginRefresh = nil
            loginTask = nil
            loginRecoveryTask = nil
            validationTask = nil
            avatarTask = nil
            do {
                try await deleteSession()
                clearAvatarCache()
                endCookieSession()
                session = nil
                profile = nil
                avatarData = nil
                avatarDataURL = nil
                avatarOwner = nil
                startupAvatar = nil
                hasRestored = true
                validationState = .signedOut
                error = nil
            } catch {
                await activateContent(session, refresh: false)
                if validationState == .validating { validationState = .unverified }
                self.setError(error, message: "退出未完成，请重试。\(error.localizedDescription)")
                throw error
            }
        }
        logoutTask = task
        try await task.value
    }

    private func endCookieSession() {
        if let credential = session?.credential { accountTransport?.clearSessionCookies(for: credential) }
    }

    private func setError(_ failure: Error, message: String? = nil) {
        error = message ?? failure.localizedDescription
        let cause = (failure as? CredentialRollbackFailure)?.cause ?? failure
        errorTechnicalDetails = (cause as? NeteaseAccountError)?.technicalDetails
    }

    private struct CredentialRollbackFailure: LocalizedError {
        let cause: Error
        var errorDescription: String? { "恢复原账户凭据失败，请重试退出登录：\(cause.localizedDescription)" }
    }

    private func persist(_ proposed: NeteaseSavedSession, replacing previous: NeteaseSavedSession?,
                         isCurrent: @MainActor () -> Bool) async throws {
        try await saveSession(proposed)
        guard !Task.isCancelled, isCurrent() else {
            do {
                if let previous { try await saveSession(previous) }
                else { try await deleteSession() }
            } catch { throw CredentialRollbackFailure(cause: error) }
            throw CancellationError()
        }
    }

    private func refreshAvatar() {
        guard let profile else { return }
        if avatarOwner?.userID == profile.userID, avatarOwner?.avatarURL == profile.avatarURL,
           (avatarData != nil && avatarDataURL == profile.avatarURL) || avatarTask != nil { return }
        let oldTask = avatarTask
        oldTask?.cancel()
        let removedAvatar = avatarOwner?.userID == profile.userID && avatarOwner?.avatarURL != nil && profile.avatarURL == nil
        let sameUser = avatarOwner?.userID == profile.userID || startupAvatar?.belongs(to: profile) == true
        if !sameUser || profile.avatarURL == nil {
            startupAvatar = nil
            avatarData = nil
            avatarDataURL = nil
        }
        avatarOwner = profile
        let id = UUID(), revision = generation
        avatarID = id
        avatarTask = Task { [self] in
            defer { if avatarID == id { avatarTask = nil; avatarID = nil } }
            await oldTask?.value
            guard !Task.isCancelled, avatarID == id, generation == revision else { return }
            if removedAvatar { clearAvatarCache() }
            guard let url = profile.avatarURL else { return }
            if let cached = await cachedAvatar(url) {
                guard !Task.isCancelled, avatarID == id, generation == revision,
                      self.profile?.userID == profile.userID, self.profile?.avatarURL == url else { return }
                startupAvatar = nil
                avatarData = cached
                avatarDataURL = url
                await saveAvatarSnapshot(cached, profile)
            }
            guard !Task.isCancelled, avatarID == id, generation == revision else { return }
            do {
                let data = try await loadAvatar(url)
                guard !Task.isCancelled, avatarID == id, generation == revision,
                      self.profile?.userID == profile.userID, self.profile?.avatarURL == url else { return }
                startupAvatar = nil
                avatarData = data
                avatarDataURL = url
                await saveAvatarSnapshot(data, profile)
            } catch {}
        }
    }
}
