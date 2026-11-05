import PhotosUI
import SwiftUI

/// 对照 Apple Music 录屏的原生效果稿；创建结果与公开显示开关均不接入在线服务。
struct NewPlaylistView: View {
    let library: PlaylistLibrary
    var folderID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var showsOnProfile = true
    @State private var coverSelection = PlaylistCoverSelection()
    @FocusState private var isTitleFocused: Bool

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coverSelection.isLoading
    }

    var body: some View {
        let displayedCover = coverSelection.image
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Color(.tertiarySystemFill)
                        if let cover = displayedCover {
                            Image(uiImage: cover).resizable().scaledToFill()
                        }
                        PlaylistCoverMenu(selection: coverSelection, accessibilityLabel: "添加播放列表封面")
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.04)) }
                    .padding(.top, 20)
                    .padding(.bottom, 64)

                    TextField("播放列表标题", text: $title)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .focused($isTitleFocused)
                        .submitLabel(.done)
                        .onSubmit { isTitleFocused = false }
                        .frame(minHeight: 44)
                    Divider()
                    // 本阶段只演示参照页面的开关状态，不发布资料或调用账号服务。
                    Toggle("在个人资料页和搜索中显示", isOn: $showsOnProfile)
                        .font(.subheadline)
                        .tint(.green)
                        .frame(minHeight: 40)
                }
                .padding(.horizontal, 20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("新建播放列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") { dismiss() }
                        .tint(.primary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let artwork = coverSelection.image.map { Artwork.image(Image(uiImage: $0)) } ?? .playlist
                        let created = withAnimation { library.createPlaylist(named: title, artwork: artwork, in: folderID) }
                        if created != nil { dismiss() }
                    } label: {
                        Image(systemName: "checkmark")
                            .foregroundStyle(canCreate ? Color(.systemBackground) : Color(.secondaryLabel))
                    }
                    .accessibilityLabel("创建")
                    .buttonStyle(.glassProminent)
                    .tint(canCreate ? Color.primary : Color(.systemGray4))
                    .disabled(!canCreate)
                }
            }
            .task { isTitleFocused = true }
            .modifier(PlaylistCoverPicker(selection: coverSelection))
        }
    }
}

#Preview("新建播放列表") {
    NewPlaylistView(library: PlaylistLibrary(playlists: []))
}
