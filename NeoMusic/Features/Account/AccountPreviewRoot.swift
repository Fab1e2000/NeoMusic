#if DEBUG
import SwiftUI

/// Isolated native review surface. Its account uses memory-only dependencies.
struct AccountPreviewRoot: View {
    let state: String
    @State private var account: NeteaseAccount
    @State private var isPresented = false

    init(state: String) {
        self.state = state
        let storage = AccountPreviewStorage(signedIn: state != "signed-out")
        _account = State(initialValue: NeteaseAccount(
            readSession: { storage.session },
            saveSession: { storage.session = $0 },
            deleteSession: { storage.session = nil },
            validateCredential: { _ in storage.profile },
            cachedAvatar: { _ in nil },
            loadAvatar: { _ in throw URLError(.resourceUnavailable) },
            clearAvatarCache: { }
        ))
    }

    var body: some View {
        Color(.systemBackground)
            .ignoresSafeArea()
            .sheet(isPresented: $isPresented) {
                AccountPage(account: account, initialRoute: state == "settings" ? .settings : nil,
                            authenticationEnabled: false,
                            tabOrderDefaults: UserDefaults(suiteName: "account-preview-tabs")!)
            }
            .task {
                await account.restore()
                isPresented = true
            }
    }
}

@MainActor
private final class AccountPreviewStorage {
    let profile = NeteaseProfile(userID: 123456789, nickname: "NeoMusic", avatarURL: nil)
    var session: NeteaseSavedSession?

    init(signedIn: Bool) {
        if signedIn, let credential = try? NeteaseCredential(musicU: "native-preview-session") {
            session = NeteaseSavedSession(profile: profile, credential: credential)
        }
    }
}

#Preview("未登录") { AccountPreviewRoot(state: "signed-out") }
#Preview("已登录") { AccountPreviewRoot(state: "signed-in") }
#Preview("账户设置") { AccountPreviewRoot(state: "settings") }
#endif
