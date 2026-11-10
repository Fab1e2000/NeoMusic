import SwiftUI
import UIKit

/// 操作完成后在迷你播放条上方短暂显示的提示，对照 Apple Music。
enum LibraryToast {
    case error(String)
    case favorited, unfavorited, pinned, unpinned
    /// 插播、随后播放（添加到队列）。
    case playingNext, addedToQueue
    /// 加入播放列表：封面、加入数量与播放列表名称，点按打开该播放列表。
    case addedToPlaylist(count: Int, title: String, artwork: Artwork, playlistID: String)
    /// 多选加入多个播放列表：图标与数量摘要。
    case addedToPlaylists(count: Int, playlistCount: Int)

    var title: String {
        switch self {
        case .error(let message): message
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
        case .error: "exclamationmark.circle"
        case .favorited: "star.fill"
        case .unfavorited: "star"
        case .pinned: "pin.fill"
        case .unpinned: "pin.slash"
        case .playingNext: "text.line.first.and.arrowtriangle.forward"
        case .addedToQueue: "text.line.last.and.arrowtriangle.forward"
        case .addedToPlaylist, .addedToPlaylists: "text.badge.plus"
        }
    }

    func dismissalDelay(voiceOverEnabled: Bool) -> Duration? {
        switch self {
        case .addedToPlaylist, .error:
            voiceOverEnabled ? nil : .seconds(5)
        case .addedToPlaylists:
            .seconds(5)
        default:
            .seconds(1.5)
        }
    }

    var accessibilityAnnouncement: AttributedString {
        let message: String
        if case .addedToPlaylist(_, let playlistTitle, _, _) = self {
            message = "\(title)，\(playlistTitle)"
        } else {
            message = title
        }
        var announcement = AttributedString(message)
        if case .error = self {
            announcement.accessibilitySpeechAnnouncementPriority = .default
        } else {
            announcement.accessibilitySpeechAnnouncementPriority = .low
        }
        return announcement
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
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private var voiceOverEnabled: Bool
    @ObservationIgnored private var lastAnnouncedID: UUID?
    private let sleep: @MainActor (Duration) async throws -> Void

    init(voiceOverEnabled: Bool? = nil,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.voiceOverEnabled = voiceOverEnabled ?? UIAccessibility.isVoiceOverRunning
        self.sleep = sleep
    }

    /// 宿主持有计时，页面重建不会提前收起提示；新反馈替换旧反馈并重新计时。
    func show(_ toast: LibraryToast) {
        let presentation = Presentation(toast: toast)
        current = presentation
        scheduleDismissal(for: presentation)
    }

    func updateVoiceOverEnabled(_ enabled: Bool) {
        guard voiceOverEnabled != enabled else { return }
        let previous = voiceOverEnabled
        voiceOverEnabled = enabled
        guard let presentation = current,
              presentation.toast.dismissalDelay(voiceOverEnabled: previous)
                != presentation.toast.dismissalDelay(voiceOverEnabled: enabled) else { return }
        scheduleDismissal(for: presentation)
    }

    func takeAccessibilityAnnouncement() -> AttributedString? {
        guard voiceOverEnabled, let presentation = current, lastAnnouncedID != presentation.id else { return nil }
        lastAnnouncedID = presentation.id
        return presentation.toast.accessibilityAnnouncement
    }

    private func scheduleDismissal(for presentation: Presentation) {
        dismissal?.cancel()
        dismissal = nil
        guard let delay = presentation.toast.dismissalDelay(voiceOverEnabled: voiceOverEnabled) else { return }
        let sleep = sleep
        dismissal = Task { [weak self] in
            do { try await sleep(delay) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.dismiss(presentation)
        }
    }

    func dismiss(_ presentation: Presentation) {
        guard current == presentation else { return }
        dismissal?.cancel()
        dismissal = nil
        current = nil
    }
}

extension View {
    /// 在页面底部（安全区内，即迷你播放条上方）显示提示。要挂在导航栈里的各个页面上：
    /// 标签栏与迷你播放条占用的安全区只传给页面，挂在导航栈外会被标签栏挡住。
    func libraryToasts(_ center: LibraryToastCenter) -> some View {
        modifier(LibraryToastOverlay(center: center))
    }

    /// 提示出现时的触感反馈；每个提示只反馈一次，挂在根部。
    /// 喜爱和取消喜爱由操作本身反馈，避免和这里再震一次；错误提示用错误触感。
    func libraryToastFeedback(_ center: LibraryToastCenter) -> some View {
        modifier(LibraryToastFeedback(center: center))
    }
}

private struct LibraryToastFeedback: ViewModifier {
    let center: LibraryToastCenter
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    func body(content: Content) -> some View {
        content.sensoryFeedback(.success, trigger: center.current?.id) { _, new in
            guard new != nil else { return false }
            switch center.current?.toast {
            case .favorited, .unfavorited, .error: return false
            default: return true
            }
        }
        .sensoryFeedback(.error, trigger: center.current?.id) { _, new in
            guard new != nil, case .error = center.current?.toast else { return false }
            return true
        }
        .onChange(of: voiceOverEnabled, initial: true) { _, enabled in
            center.updateVoiceOverEnabled(enabled)
            announceCurrentPresentation()
        }
        .onChange(of: center.current?.id, initial: true) { _, _ in
            announceCurrentPresentation()
        }
    }

    private func announceCurrentPresentation() {
        guard voiceOverEnabled, let announcement = center.takeAccessibilityAnnouncement() else { return }
        AccessibilityNotification.Announcement(announcement).post()
    }
}

/// 与播放、下载按钮相同的轻触感。可从菜单操作直接调用。
/// 常驻一个发生器并在触发后立即预热：几秒内的连续轻点（如连点喜欢）延迟更低。
enum LibraryHaptics {
    @MainActor private static let generator = UIImpactFeedbackGenerator(style: .soft)
    static func impact() {
        let play: @MainActor () -> Void = {
            generator.impactOccurred(intensity: 0.6)
            generator.prepare()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(play)
        } else {
            Task { @MainActor in play() }
        }
    }
}

private struct LibraryToastOverlay: ViewModifier {
    let center: LibraryToastCenter
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let presentation = center.current {
                    LibraryToastView(toast: presentation.toast, dismiss: { center.dismiss(presentation) },
                                     openRoute: openLibraryRoute)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 25)
                        .transition(reducesMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                        .id(presentation.id)
                }
            }
            .animation(reducesMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3), value: center.current)
    }
}

/// 短提示高 53pt，较大文字和长内容自适应增高。
struct LibraryToastView: View {
    let toast: LibraryToast
    let dismiss: () -> Void
    let openRoute: OpenLibraryRouteAction

    var body: some View {
        content
            .frame(minHeight: 53)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "关闭提示", dismiss)
    }

    func openPlaylist(_ playlistID: String) {
        dismiss()
        openRoute(.playlist(playlistID))
    }

    @ViewBuilder private var content: some View {
        if case .addedToPlaylist(_, let title, let artwork, let playlistID) = toast {
            Button { openPlaylist(playlistID) } label: {
                HStack(spacing: 10) {
                    ArtworkView(artwork: artwork, cornerRadius: 4)
                        .frame(width: 33, height: 33)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        // 实测 Apple Music：说明 13pt、名称 15pt 半粗体，箭头更小、为次要色。
                        Text(toast.title).font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 3) {
                            Text(title).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 10)
                .padding(.trailing, 18)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        } else {
            Label(toast.title, systemImage: toast.systemImage)
                .labelStyle(ToastLabelStyle())
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
    }
}

private struct ToastLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon.font(.body.weight(.semibold)).accessibilityHidden(true)
            configuration.title.lineLimit(nil).fixedSize(horizontal: false, vertical: true)
        }
    }
}
