import SwiftUI

/// 操作完成后在迷你播放条上方短暂显示的提示，对照 Apple Music。
enum LibraryToast {
    case favorited, unfavorited, pinned, unpinned
    /// 插播、随后播放（添加到队列）。
    case playingNext, addedToQueue
    /// 加入播放列表：封面、加入数量与播放列表名称，点按打开该播放列表。
    case addedToPlaylist(count: Int, title: String, artwork: Artwork, playlistID: String)
    /// 多选加入多个播放列表：只有图标与一行文字。
    case addedToPlaylists(count: Int, playlistCount: Int)

    var title: String {
        switch self {
        case .favorited: "已喜爱"
        case .unfavorited: "已取消喜爱"
        case .pinned: "已置顶"
        case .unpinned: "已取消置顶"
        case .playingNext: "下个播放"
        case .addedToQueue: "已添加到队列"
        case .addedToPlaylist(let count, _, _, _): "已添加\(count)首歌曲"
        case .addedToPlaylists(let count, let playlists): "已将\(count)首歌曲添加到\(playlists)个播放列表"
        }
    }

    var systemImage: String {
        switch self {
        case .favorited: "star.fill"
        case .unfavorited: "star"
        case .pinned: "pin.fill"
        case .unpinned: "pin.slash"
        case .playingNext: "text.line.first.and.arrowtriangle.forward"
        case .addedToQueue: "text.line.last.and.arrowtriangle.forward"
        case .addedToPlaylist, .addedToPlaylists: "text.badge.plus"
        }
    }
}

/// 当前显示的提示。由持有资料库的宿主创建，菜单操作通过 `CollectionMenuActions.notify` 发出提示。
@MainActor @Observable
final class LibraryToastCenter {
    struct Presentation: Equatable {
        let toast: LibraryToast
        let id = UUID()

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    private(set) var current: Presentation?
    private var dismissal: Task<Void, Never>?

    /// 显示 1.5 秒后自动收起。计时放在这里而不是提示视图上：页面刷新可能重建视图并取消它的任务，
    /// 提示会一出现就被收起。
    func show(_ toast: LibraryToast) {
        let presentation = Presentation(toast: toast)
        current = presentation
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.3)) { self?.dismiss(presentation) }
        }
    }

    func dismiss(_ presentation: Presentation) {
        if current == presentation { current = nil }
    }
}

extension View {
    /// 在页面底部（安全区内，即迷你播放条上方）显示提示。要挂在导航栈里的各个页面上：
    /// 标签栏与迷你播放条占用的安全区只传给页面，挂在导航栈外会被标签栏挡住。
    func libraryToasts(_ center: LibraryToastCenter) -> some View {
        modifier(LibraryToastOverlay(center: center))
    }

    /// 提示出现时的触感反馈；每个提示只反馈一次，挂在根部。
    func libraryToastFeedback(_ center: LibraryToastCenter) -> some View {
        sensoryFeedback(.success, trigger: center.current?.id) { _, new in new != nil }
    }
}

private struct LibraryToastOverlay: ViewModifier {
    let center: LibraryToastCenter

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let presentation = center.current {
                    LibraryToastView(toast: presentation.toast)
                        .padding(.bottom, 25)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .id(presentation.id)
                }
            }
            .animation(.smooth(duration: 0.3), value: center.current)
    }
}

/// 实测 Apple Music：不是玻璃，而是接近不透明的浅灰模糊底，高 53pt。
private struct LibraryToastView: View {
    let toast: LibraryToast
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    var body: some View {
        content
            .frame(height: 53)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        if case .addedToPlaylist(_, let title, let artwork, let playlistID) = toast {
            Button { openLibraryRoute(.playlist(playlistID)) } label: {
                HStack(spacing: 10) {
                    ArtworkView(artwork: artwork, cornerRadius: 4)
                        .frame(width: 33)
                    VStack(alignment: .leading, spacing: 0) {
                        // 实测 Apple Music：说明 13pt、名称 15pt 半粗体，箭头更小、为次要色。
                        Text(toast.title).font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            Text(title).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                .padding(.leading, 10)
                .padding(.trailing, 18)
            }
            .buttonStyle(.plain)
        } else {
            Label(toast.title, systemImage: toast.systemImage)
                .labelStyle(ToastLabelStyle())
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
        }
    }
}

private struct ToastLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.font(.body.weight(.semibold))
            configuration.title
        }
    }
}
