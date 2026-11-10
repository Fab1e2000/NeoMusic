// Official-site authentication follows MeloX / NeoDizzy (GPL-3.0).
// WebKit owns the website and its temporary cookie store; the account owns credentials.
import SwiftUI
import WebKit

struct NeteaseLoginPage: View {
    let account: NeteaseAccount
    let completed: () -> Void
    @State private var browser = NeteaseLoginBrowser()
    @State private var loginTask: Task<Void, Never>?
    @State private var error: String?
    @State private var errorTechnicalDetails: String?
    @State private var pageError: String?
    @State private var loadID = 0
    @State private var checking = false

    var body: some View {
        VStack(spacing: 0) {
            if let pageError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pageError).foregroundStyle(.red)
                    Button("重新加载") { loadID += 1 }
                }
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            if let error {
                AccountErrorMessage(message: error, technicalDetails: errorTechnicalDetails)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("account.login.error")
            }
            if browser.page.isLoading {
                ProgressView(value: browser.page.estimatedProgress)
                    .accessibilityLabel("正在加载网易云音乐官网")
            }
            WebView(browser.page)
        }
        .navigationTitle("登录网易云音乐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    loginTask = Task { await finishLogin() }
                } label: {
                    LoginCompletionLabel(checking: checking)
                }
                .disabled(checking || account.isAuthenticating || account.isLoggingOut)
                .accessibilityIdentifier("account.login.complete")
            }
        }
        .task(id: loadID) {
            pageError = nil
            do {
                for try await _ in browser.page.load(URLRequest(url: URL(string: "https://music.163.com/#")!)) { }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                pageError = "无法打开网易云音乐官网：\(error.localizedDescription)"
            }
        }
        .onDisappear {
            let pendingLogin = loginTask
            pendingLogin?.cancel()
            browser.page.stopLoading()
            Task { await pendingLogin?.value }
        }
    }

    private func finishLogin() async {
        checking = true
        error = nil
        errorTechnicalDetails = nil
        defer { checking = false }
        do {
            let cookies = await browser.dataStore.httpCookieStore.allCookies()
            try Task.checkCancellation()
            let credential = try NeteaseCredential(cookies: cookies)
            try await account.completeLogin(credential: credential)
            try Task.checkCancellation()
            completed()
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            errorTechnicalDetails = (error as? NeteaseAccountError)?.technicalDetails
        }
    }
}

struct LoginCompletionLabel: View {
    let checking: Bool

    var body: some View {
        HStack(spacing: 6) {
            if checking { ProgressView().controlSize(.small) }
            Text(checking ? "正在验证登录" : "完成")
        }
        .accessibilityElement(children: .combine)
    }
}

@Observable @MainActor
private final class NeteaseLoginBrowser {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    let page: WebPage

    init() {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.defaultNavigationPreferences.preferredContentMode = .desktop
        page = WebPage(configuration: configuration)
    }
}

#Preview("登录核查进度") {
    NavigationStack {
        Color(.systemBackground)
            .navigationTitle("登录网易云音乐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {} label: { LoginCompletionLabel(checking: true) }
                        .disabled(true)
                }
            }
    }
}
