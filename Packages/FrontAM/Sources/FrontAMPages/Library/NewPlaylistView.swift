import FrontAMCore
import PhotosUI
import SwiftUI

public struct NewPlaylistView: View {
    public let library: any FrontAMPlaylistSource
    public var folderID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var coverSelection = PlaylistCoverSelection()
    @State private var showsDiscard = false
    @FocusState private var isTitleFocused: Bool

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !coverSelection.isLoading
    }

    private var hasChanges: Bool {
        PlaylistDraftSnapshot().hasChanges(title: title, hasCoverChange: coverSelection.image != nil)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    PlaylistFormCover(selection: coverSelection, accessibilityLabel: pageText("添加播放列表封面"), bottomSpacing: 64)

                    TextField(pageText("播放列表标题"), text: $title)
                        .font(.body.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .focused($isTitleFocused)
                        .submitLabel(.done)
                        .onSubmit { isTitleFocused = false }
                        .frame(minHeight: 44)
                    Divider()
                    Toggle(pageText("在个人资料页和搜索中显示"), isOn: .constant(false))
                        .font(.subheadline)
                        .tint(.green)
                        .frame(minHeight: 40)
                        .disabled(true)
                        .accessibilityHint(pageText("本地播放列表暂不支持公开显示"))
                }
                .padding(.horizontal, 20)
            }
            .background(Color(.systemBackground))
            .navigationTitle(pageText("新建播放列表"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(pageText("取消"), systemImage: "xmark", action: requestDismiss)
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
                    .accessibilityLabel(pageText("创建"))
                    .buttonStyle(.glassProminent)
                    .tint(canCreate ? Color.primary : Color(.systemGray4))
                    .disabled(!canCreate)
                }
            }
            .task { isTitleFocused = true }
            .modifier(PlaylistCoverPicker(selection: coverSelection))
            .interactiveDismissDisabled(hasChanges)
            .onSheetDismissAttempt(requestDismiss)
            .alert("", isPresented: $showsDiscard) {
                Button(pageText("放弃更改"), role: .destructive, action: close)
                Button(pageText("取消"), role: .cancel) {}
            } message: {
                Text(pageText("确定要放弃更改吗？"))
            }
        }
    }

    private func requestDismiss() {
        if hasChanges { showsDiscard = true } else { close() }
    }

    private func close() {
        coverSelection.cancelPendingLoad()
        dismiss()
    }

    public init(library: any FrontAMPlaylistSource,
                folderID: String? = nil) {
        self.library = library
        self.folderID = folderID
    }
}
