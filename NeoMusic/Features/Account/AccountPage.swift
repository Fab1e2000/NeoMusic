import SwiftUI

enum AccountRoute: Hashable {
    case settings, login, quality
}

struct AccountPage: View {
    let account: NeteaseAccount
    private let authenticationEnabled: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AccountRoute]

    init(account: NeteaseAccount, initialRoute: AccountRoute? = nil, authenticationEnabled: Bool = true) {
        self.account = account
        self.authenticationEnabled = authenticationEnabled
        let route = initialRoute == .login && !authenticationEnabled ? nil : initialRoute
        _path = State(initialValue: route.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: navigationPath) {
            List {
                Section {
                    NavigationLink(value: account.profile == nil ? AccountRoute.login : .settings) {
                        HStack(spacing: 8) {
                            AccountAvatar(account: account, size: 55)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.profile?.nickname ?? "登录网易云音乐")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(identitySubtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 85)
                    }
                    .allowsHitTesting(authenticationEnabled || account.profile != nil)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .accessibilityIdentifier("account.identity")
                } footer: {
                    AccountValidationStatus(account: account) {
                        if authenticationEnabled { path.append(.login) }
                    }
                }
                if account.music != nil {
                    Section {
                        NavigationLink("音质", value: AccountRoute.quality)
                            .accessibilityIdentifier("account.quality")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Image("AccountBrandIcon").resizable().scaledToFit().frame(width: 28, height: 28)
                        Text("网易云账户").font(.body.weight(.semibold))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 8)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
                        .accessibilityIdentifier("account.close")
                }
            }
            .navigationDestination(for: AccountRoute.self) { route in
                switch route {
                case .quality:
                    if let music = account.music { MusicQualitySettingsPage(music: music, downloads: account.downloads) }
                case .settings:
                    AccountSettingsPage(account: account, authenticationEnabled: authenticationEnabled)
                case .login:
                    if authenticationEnabled {
                        NeteaseLoginPage(account: account) { path.removeAll() }
                    }
                }
            }
            .accessibilityIdentifier("account.page")
        }
        .onChange(of: account.profile?.userID) { previous, current in
            if previous != nil, current == nil { path.removeAll() }
        }
    }

    private var navigationPath: Binding<[AccountRoute]> {
        Binding(get: { path }, set: { proposed in
            if authenticationEnabled || !proposed.contains(.login) { path = proposed }
        })
    }

    private var identitySubtitle: String {
        if account.validationState == .requiresLogin { return "登录已失效，请重新登录" }
        return account.profile == nil ? "使用你的网易云音乐账户" : "账户信息与登录设置"
    }
}

private struct AccountSettingsPage: View {
    let account: NeteaseAccount
    let authenticationEnabled: Bool
    @State private var confirmsLogout = false
    @State private var logoutError: String?

    var body: some View {
        List {
            Section {
                detailRow("昵称", value: account.profile?.nickname ?? "")
                    .listRowInsets(rowInsets)
                detailRow("网易云 ID", value: account.profile.map { String($0.userID) } ?? "")
                    .listRowInsets(rowInsets)
            }

            Section {
                NavigationLink(value: AccountRoute.login) {
                    Text(account.validationState == .requiresLogin ? "重新登录" : "切换账号")
                        .foregroundStyle(.blue)
                        .frame(minHeight: 62, alignment: .leading)
                }
                .listRowInsets(rowInsets)
                .disabled(account.isLoggingOut)
                .allowsHitTesting(authenticationEnabled)
                .accessibilityIdentifier("account.switch")
            } footer: {
                AccountValidationStatus(account: account)
            }

            Section {
                Button(role: .destructive) { confirmsLogout = true } label: {
                    HStack {
                        Text(account.isLoggingOut ? "正在退出登录…" : "退出登录")
                        Spacer()
                        if account.isLoggingOut { ProgressView() }
                    }
                    .frame(minHeight: 62)
                }
                .listRowInsets(rowInsets)
                .disabled(account.isLoggingOut)
                .accessibilityIdentifier("account.logout")
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .listSectionSpacing(16)
        .navigationTitle("账户设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出网易云音乐？", isPresented: $confirmsLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task {
                    do { try await account.logout() }
                    catch is CancellationError { }
                    catch { logoutError = error.localizedDescription }
                }
            }
        } message: {
            Text("退出后仍可使用本地音乐。")
        }
        .alert("退出未完成", isPresented: Binding(get: { logoutError != nil }, set: {
            if !$0 { logoutError = nil }
        })) {
            Button("好", role: .cancel) { logoutError = nil }
        } message: {
            Text(logoutError ?? "")
        }
        .accessibilityIdentifier("account.settings")
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
    }

    private func detailRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 62)
    }
}

private struct AccountValidationStatus: View {
    let account: NeteaseAccount
    var login: (() -> Void)? = nil

    var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 8) {
                if account.validationState == .validating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在验证账户…")
                    }
                }
                if let error = account.error {
                    Text(error)
                }
                if account.validationState == .unverified {
                    Button("重新验证") { Task { await account.revalidate() } }
                } else if account.validationState == .requiresLogin, let login {
                    Button("重新登录", action: login)
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private var hasContent: Bool {
        account.validationState == .validating || account.error != nil ||
        account.validationState == .unverified ||
        (account.validationState == .requiresLogin && login != nil)
    }
}
