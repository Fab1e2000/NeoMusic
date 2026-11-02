import SwiftUI

#if DEBUG || ACCOUNT_REFERENCE_PREVIEW
@MainActor private enum AccountReferenceFixture {
    #if ACCOUNT_REFERENCE_PREVIEW
    static let isEnabled = true
    static let directory = Bundle.main.bundleURL.appendingPathComponent("AccountReference", isDirectory: true)
    #else
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-accountReferencePreview") }
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountReference", isDirectory: true)
    #endif
    static let values = (try? Data(contentsOf: directory.appendingPathComponent("profile.json")))
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    static var name: String { values["name"] ?? "预览用户" }
    static var initials: String { values["initials"] ?? "NM" }
    static func image(_ name: String) -> UIImage? {
        UIImage(contentsOfFile: directory.appendingPathComponent(name + ".png").path)
    }
    static let toolbarAvatar: UIImage = {
        let renderer = ImageRenderer(content: AccountReferenceMonogram(size: 38))
        renderer.scale = 3
        return renderer.uiImage ?? UIImage()
    }()
}

struct AccountReferenceToolbar: ToolbarContent {
    var body: some ToolbarContent {
        if AccountReferenceFixture.isEnabled {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) { AccountReferenceButton() }
        }
    }
}

private struct AccountReferenceButton: View {
    @State private var isPresented = ProcessInfo.processInfo.arguments.contains("-accountReferenceSheet")

    var body: some View {
        Button { isPresented = true } label: {
            Image(uiImage: AccountReferenceFixture.toolbarAvatar).renderingMode(.original)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账户")
        .sheet(isPresented: $isPresented) { AccountReferencePage() }
    }
}

private struct AccountReferenceMonogram: View {
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(red: 0.67, green: 0.77, blue: 0.90),
                                         Color(red: 0.47, green: 0.51, blue: 0.73)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Text(AccountReferenceFixture.initials)
                    .font(.system(size: size * 0.447, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Isolated visual reference. Its rows explain unavailable services instead of simulating account operations.
private struct AccountReferencePage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var unavailable = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { unavailable = true } label: {
                        HStack(spacing: 8) {
                            Group {
                                if let photo = AccountReferenceFixture.image("photo") {
                                    Image(uiImage: photo).resizable().scaledToFill()
                                } else {
                                    AccountReferenceMonogram(size: 55)
                                }
                            }
                            .frame(width: 55, height: 55).clipShape(.circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AccountReferenceFixture.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text("账户信息、付款方式和设置").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            chevron
                        }
                        .frame(height: 85)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 63 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    HStack(spacing: 8) {
                        AccountReferenceMonogram(size: 30).frame(width: 55)
                        Text(AccountReferenceFixture.name)
                        Spacer()
                        Button("编辑") { unavailable = true }.fontWeight(.semibold)
                    }
                    .frame(height: 60)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                } footer: {
                    Text("你的姓名和照片会在播放列表中或是在一起聆听时向其他人展示。").padding(.horizontal, 4)
                }

                Section {
                    Button("设置个人资料") { unavailable = true }
                        .frame(height: 52, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                } footer: {
                    Text("设置个人资料即可分享你的音乐，并可查看朋友正在播放的内容。").padding(.horizontal, 4)
                }

                Section {
                    ForEach(["订阅", "购买记录", "通知", "隐私与访问"], id: \.self) { title in
                        Button { unavailable = true } label: {
                            HStack {
                                Text(title).foregroundStyle(.primary)
                                Spacer()
                                chevron
                            }
                            .frame(height: 52)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                }

                Section {
                    Button("从其他服务传输音乐") { unavailable = true }
                        .frame(height: 52, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                } footer: {
                    Text("将你在其他音乐服务中保存的音乐和播放列表添加到你的 Apple Music 资料库。").padding(.horizontal, 4)
                }
            }
            .listStyle(.insetGrouped)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        if let symbol = AccountReferenceFixture.image("account-symbol") {
                            Image(uiImage: symbol).resizable().frame(width: 28, height: 28)
                        }
                        Text("Apple 账户").font(.body.weight(.semibold))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 8)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
            .alert("效果稿", isPresented: $unavailable) {
                Button("好", role: .cancel) {}
            } message: {
                Text("当前仅展示参考界面，尚未接入 Apple 账户及相关服务。")
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}
#endif
