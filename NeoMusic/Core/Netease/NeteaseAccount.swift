import Foundation
import Observation

/// Owns the account credential, validation, and avatar work for the current session.
@MainActor @Observable
final class NeteaseAccount {
    enum ValidationState: Equatable {
        case signedOut, validating, valid, unverified, requiresLogin
    }

    private(set) var profile: NeteaseProfile?
    private(set) var avatarData: Data?
    private(set) var validationState = ValidationState.signedOut
    private(set) var error: String?
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
    @ObservationIgnored private var startupAvatar: NeteaseAvatarSnapshot?
    @ObservationIgnored private var session: NeteaseSavedSession?
    @ObservationIgnored private var hasRestored = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var validationID: UUID?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var loginID: UUID?
    @ObservationIgnored private var loginTask: Task<Void, Error>?
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
         saveAvatarSnapshot: @escaping @MainActor (Data, NeteaseProfile) async -> Void = { _, _ in }) {
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
    }

    convenience init(client: NeteaseAccountClient, credentialStore: NeteaseCredentialStore,
                     avatarClient: NeteaseAvatarClient,
                     avatarSnapshotStore: NeteaseAvatarSnapshotStore = NeteaseAvatarSnapshotStore()) {
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
                  saveAvatarSnapshot: { await avatarSnapshotStore.save($0, for: $1) })
    }

    func restore() async {
        if let logoutTask { _ = await logoutTask.result; return }
        if let validationTask { await validationTask.value; return }
        guard !hasRestored, !isAuthenticating, !Task.isCancelled else { return }
        await validate(restoring: true)
    }

    func revalidate() async {
        if let logoutTask { _ = await logoutTask.result; return }
        guard !isAuthenticating, !Task.isCancelled else { return }
        if !hasRestored { await restore(); return }
        guard session != nil else { return }
        await validate(restoring: false)
    }

    private func validate(restoring: Bool) async {
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
                    let restored = try await readSession()
                    try Task.checkCancellation()
                    guard validationID == id, generation == revision else { return }
                    session = restored
                    profile = session?.profile
                    if let startupAvatar,
                       profile.map({ startupAvatar.belongs(to: $0) && $0.avatarURL != nil }) != true {
                        self.startupAvatar = nil
                        avatarData = nil
                        avatarDataURL = nil
                        clearAvatarCache()
                    }
                    hasRestored = true
                    previousState = session == nil ? .signedOut : .unverified
                    // Restore the saved identity and its image independently of
                    // the account endpoint; validation still owns session validity.
                    refreshAvatar()
                }
                guard let saved = session else { validationState = .signedOut; error = nil; return }
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
            } catch is CancellationError {
                if validationID == id, generation == revision { validationState = previousState }
            } catch {
                guard validationID == id, generation == revision else { return }
                if let failure = error as? CredentialRollbackFailure {
                    validationState = .unverified
                    self.error = failure.localizedDescription
                    return
                }
                guard !Task.isCancelled else { return }
                if error as? NeteaseAccountError == .authenticationRequired {
                    session = nil
                    validationState = .requiresLogin
                    self.error = error.localizedDescription
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
                            self.error = "登录已失效，清除保存的凭据失败：\(error.localizedDescription)"
                        }
                    }
                } else {
                    validationState = .unverified
                    self.error = error.localizedDescription
                }
            }
        }
        validationTask = task
        await task.value
    }

    func completeLogin(credential: NeteaseCredential) async throws {
        if let logoutTask { try await logoutTask.value }
        try Task.checkCancellation()
        let id = UUID()
        let previousLogin = loginTask
        previousLogin?.cancel()
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
                let candidate = try await validateCredential(credential)
                try checkLogin(id)

                generation += 1
                let oldValidation = validationTask, oldAvatar = avatarTask
                validationID = nil
                avatarID = nil
                oldValidation?.cancel()
                oldAvatar?.cancel()
                await oldValidation?.value
                await oldAvatar?.value
                try checkLogin(id)
                validationTask = nil
                avatarTask = nil
                let saved = NeteaseSavedSession(profile: candidate, credential: credential)
                try await persist(saved, replacing: session) { self.loginID == id && self.logoutID == nil }
                if session?.profile.userID != candidate.userID { clearAvatarCache() }
                session = saved
                profile = candidate
                hasRestored = true
                validationState = .valid
                error = nil
                refreshAvatar()
            } catch {
                if loginID == id {
                    if validationID == nil { validationTask = nil }
                    if avatarID == nil { avatarTask = nil }
                    if validationState == .validating { validationState = .unverified }
                    if error is CredentialRollbackFailure || (!(error is CancellationError) && !Task.isCancelled) {
                        self.error = error.localizedDescription
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
        let task = loginTask
        loginID = nil
        task?.cancel()
        let result = await task?.result
        if loginID == nil {
            loginTask = nil
            isAuthenticating = false
            if validationID == nil { validationTask = nil }
            if avatarID == nil { avatarTask = nil }
            if validationState == .validating, validationID == nil { validationState = .unverified }
            if case .failure(let failure as CredentialRollbackFailure) = result { error = failure.localizedDescription }
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
        let oldLogin = loginTask, oldValidation = validationTask, oldAvatar = avatarTask
        oldLogin?.cancel()
        oldValidation?.cancel()
        oldAvatar?.cancel()
        let task = Task { [self] in
            defer {
                if logoutID == id { logoutTask = nil; logoutID = nil; isLoggingOut = false }
            }
            _ = await oldLogin?.result
            await oldValidation?.value
            await oldAvatar?.value
            loginTask = nil
            validationTask = nil
            avatarTask = nil
            do {
                try await deleteSession()
                clearAvatarCache()
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
                if validationState == .validating { validationState = .unverified }
                self.error = "退出未完成，请重试：\(error.localizedDescription)"
                throw error
            }
        }
        logoutTask = task
        // Once requested, leaving the page does not interrupt credential removal.
        try await task.value
    }

    private struct CredentialRollbackFailure: LocalizedError {
        let cause: Error
        var errorDescription: String? { "恢复原账户凭据失败，请重试退出登录：\(cause.localizedDescription)" }
    }

    /// A cancelled write restores its prior value before another login or logout proceeds.
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
        // NetEase can rotate CDN hosts for the same image. Keep this user's
        // displayed avatar until its replacement arrives; the URL scopes requests.
        let sameUser = avatarOwner?.userID == profile.userID || startupAvatar?.belongs(to: profile) == true
        if !sameUser || profile.avatarURL == nil {
            avatarData = nil
            avatarDataURL = nil
        }
        startupAvatar = nil
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
                avatarData = cached
                avatarDataURL = url
                await saveAvatarSnapshot(cached, profile)
            }
            guard !Task.isCancelled, avatarID == id, generation == revision else { return }
            do {
                let data = try await loadAvatar(url)
                guard !Task.isCancelled, avatarID == id, generation == revision,
                      self.profile?.userID == profile.userID, self.profile?.avatarURL == url else { return }
                avatarData = data
                avatarDataURL = url
                await saveAvatarSnapshot(data, profile)
            } catch { /* The account remains usable when its avatar cannot be loaded. */ }
        }
    }
}
