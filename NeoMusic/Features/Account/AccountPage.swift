import SwiftUI

enum AccountRoute: Hashable {
    case settings, login, quality, tabs
}

struct AccountPage: View {
    let account: NeteaseAccount
    private let authenticationEnabled: Bool
    private let tabOrderDefaults: UserDefaults
    @Environment(\.dismiss) private var dismiss
    @State private var path: [AccountRoute]

    init(account: NeteaseAccount, initialRoute: AccountRoute? = nil, authenticationEnabled: Bool = true,
         tabOrderDefaults: UserDefaults = .standard) {
        self.account = account
        self.authenticationEnabled = authenticationEnabled
        self.tabOrderDefaults = tabOrderDefaults
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
                Section {
                    NavigationLink("标签页", value: AccountRoute.tabs)
                        .accessibilityIdentifier("account.tabs")
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
                case .tabs:
                    TabOrderPage(defaults: tabOrderDefaults)
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
        .alert("", isPresented: $confirmsLogout) {
            Button("退出登录", role: .destructive) {
                Task {
                    do { try await account.logout() }
                    catch is CancellationError { }
                    catch { logoutError = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出网易云音乐？退出后仍可使用本地音乐。")
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

private struct TabOrderPage: View {
    @AppStorage(AppTabOrder.storageKey) private var storedOrder = AppTabOrder.defaultRaw
    @AppStorage(AppTabOrder.hiddenKey) private var storedHidden: String?
    private var playlistIDs: [String] {
        LocalLibrary.playlistLibrary.playlists.compactMap { item in
            guard !item.isSystem, !item.isDownloadedSnapshot, !item.id.isEmpty, !item.id.contains(",") else { return nil }
            return item.id
        }
    }
    private var order: [AppTab] { AppTabOrder.resolve(storedOrder, playlists: playlistIDs) }
    private var hidden: Set<AppTab> { AppTabOrder.effectiveHidden(order: storedOrder, hidden: storedHidden, playlists: playlistIDs) }
    private var shown: [AppTab] { order.filter { !hidden.contains($0) } }
    private var hiddenInOrder: [AppTab] { order.filter { hidden.contains($0) } }

    init(defaults: UserDefaults = .standard) {
        _storedOrder = AppStorage(wrappedValue: AppTabOrder.defaultRaw, AppTabOrder.storageKey, store: defaults)
        _storedHidden = AppStorage(AppTabOrder.hiddenKey, store: defaults)
    }

    var body: some View {
        Form {
            Section {
                ForEach(shown) { tab in
                    HStack {
                        tabLabel(tab)
                        Spacer()
                        Button { setHidden(tab, true) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .disabled(shown.count <= 1)
                        .accessibilityLabel("移除\(title(for: tab))")
                    }
                    .accessibilityIdentifier("tab-order.\(tab.rawValue)")
                }
                .onMove(perform: moveShown)
                tabLabel(.search)
                    .foregroundStyle(.secondary)
                    .moveDisabled(true)
            } header: {
                Text("显示的标签")
            } footer: {
                Text("拖动右侧的把手调整顺序，点红色按钮从标签栏移除。连同末尾的搜索，最多 \(AppTabOrder.maxVisible + 1) 个，不会出现「更多」。")
            }

            if !hiddenInOrder.isEmpty {
                Section {
                    ForEach(hiddenInOrder) { tab in
                        HStack {
                            tabLabel(tab).foregroundStyle(.secondary)
                            Spacer()
                            Button { setHidden(tab, false) } label: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                            }
                            .buttonStyle(.borderless)
                            .disabled(shown.count >= AppTabOrder.maxVisible)
                            .accessibilityLabel("添加\(title(for: tab))")
                        }
                        .moveDisabled(true)
                    }
                } header: {
                    Text("可添加的标签")
                } footer: {
                    if shown.count >= AppTabOrder.maxVisible {
                        Text("显示的标签已满，先移除一个才能添加。")
                    }
                }
            }

            Section {
                Button("恢复默认") {
                    storedOrder = AppTabOrder.defaultRaw
                    storedHidden = AppTabOrder.raw(AppTabOrder.defaultHidden)
                }
                .disabled(shown == [.home, .library] && hidden.subtracting(playlistIDs.map(AppTab.playlist)) == AppTabOrder.defaultHidden)
            }
        }
        // 编辑模式一直开着时，后插入的行不会带上系统排序把手。按当前显示的标签重建列表，把手会马上出现。
        .id(shown.map(\.rawValue).sorted().joined(separator: ","))
        .environment(\.editMode, .constant(.active))
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .navigationTitle("标签页")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("account.tab-order")
    }

    /// 只在显示的标签之间拖动；未显示的标签留在原来的相对位置。
    private func moveShown(from source: IndexSet, to destination: Int) {
        var reordered = shown
        reordered.move(fromOffsets: source, toOffset: destination)
        var iterator = reordered.makeIterator()
        storedOrder = AppTabOrder.raw(order.map { hidden.contains($0) ? $0 : iterator.next()! })
    }

    private func setHidden(_ tab: AppTab, _ isHidden: Bool) {
        var updated = hidden
        if isHidden { updated.insert(tab) } else { updated.remove(tab) }
        let current = order
        if case .playlist = tab, !isHidden { storedOrder = AppTabOrder.raw(current) }
        storedHidden = AppTabOrder.raw(current.filter(updated.contains))
    }

    private func title(for tab: AppTab) -> String {
        if case .playlist(let id) = tab { return LocalLibrary.playlistLibrary.playlist(id)?.title ?? "播放列表" }
        return tab.title
    }

    private func tabLabel(_ tab: AppTab) -> some View {
        Label {
            Text(title(for: tab))
        } icon: {
            if tab == .home {
                Image("HomeTabIcon").resizable().scaledToFit()
            } else {
                Image(systemName: tab.systemImage)
            }
        }
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
                    AccountErrorMessage(message: error, technicalDetails: account.errorTechnicalDetails)
                }
                if account.validationState == .unverified {
                    Button("重新验证") { Task { await account.revalidate() } }
                        .foregroundStyle(.tint)
                } else if account.validationState == .requiresLogin, let login {
                    Button("重新登录", action: login)
                        .foregroundStyle(.tint)
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

struct AccountErrorMessage: View {
    let message: String
    let technicalDetails: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
            if let technicalDetails {
                DisclosureGroup("技术详情") {
                    Text(technicalDetails)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("账户验证错误") {
    List {
        Section {
            Label("网易云账户", systemImage: "person.crop.circle")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                AccountErrorMessage(message: NeteaseAccountError.keychain(-34018).localizedDescription,
                                    technicalDetails: NeteaseAccountError.keychain(-34018).technicalDetails)
                Button("重新验证") {}.foregroundStyle(.tint)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
    .listStyle(.insetGrouped)
}
