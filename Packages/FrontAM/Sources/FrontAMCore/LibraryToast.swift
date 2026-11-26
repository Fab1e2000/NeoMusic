import SwiftUI
import UIKit

public enum LibraryToast {
    case error(String)
    case favorited, unfavorited, pinned, unpinned
    case playingNext, addedToQueue
    case addedToPlaylist(count: Int, title: String, artwork: Artwork, playlistID: String)
    case addedToPlaylists(count: Int, playlistCount: Int)
    case movedToFolder(folderName: String, folderID: String)

    public var title: String {
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
        case .movedToFolder(let name, _): "已移至\(name)"
        }
    }

    public var systemImage: String {
        switch self {
        case .error: "exclamationmark.circle"
        case .favorited: "star.fill"
        case .unfavorited: "star"
        case .pinned: "pin.fill"
        case .unpinned: "pin.slash"
        case .playingNext: "text.line.first.and.arrowtriangle.forward"
        case .addedToQueue: "text.line.last.and.arrowtriangle.forward"
        case .addedToPlaylist, .addedToPlaylists: "text.badge.plus"
        case .movedToFolder: "folder"
        }
    }

    public func dismissalDelay(voiceOverEnabled: Bool) -> Duration? {
        switch self {
        case .addedToPlaylist, .error:
            voiceOverEnabled ? nil : .seconds(5)
        case .addedToPlaylists:
            .seconds(5)
        case .movedToFolder:
            voiceOverEnabled ? nil : .seconds(3)
        default:
            .seconds(1.5)
        }
    }

    public var insets: EdgeInsets {
        if case .movedToFolder = self { return .init(top: 0, leading: 0, bottom: 12, trailing: 0) }
        return .init(top: 0, leading: 12, bottom: 25, trailing: 12)
    }

    public var accessibilityAnnouncement: AttributedString {
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

@MainActor @Observable
public final class LibraryToastCenter {
    public struct Presentation: Equatable {
        public let toast: LibraryToast
        public let id = UUID()

        public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    public private(set) var current: Presentation?
    @ObservationIgnored private var dismissal: Task<Void, Never>?
    @ObservationIgnored private var voiceOverEnabled: Bool
    @ObservationIgnored private var lastAnnouncedID: UUID?
    private let sleep: @MainActor (Duration) async throws -> Void

    public init(voiceOverEnabled: Bool? = nil,
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.voiceOverEnabled = voiceOverEnabled ?? UIAccessibility.isVoiceOverRunning
        self.sleep = sleep
    }

    public func show(_ toast: LibraryToast) {
        let presentation = Presentation(toast: toast)
        current = presentation
        scheduleDismissal(for: presentation)
    }

    public func updateVoiceOverEnabled(_ enabled: Bool) {
        guard voiceOverEnabled != enabled else { return }
        let previous = voiceOverEnabled
        voiceOverEnabled = enabled
        guard let presentation = current,
              presentation.toast.dismissalDelay(voiceOverEnabled: previous)
                != presentation.toast.dismissalDelay(voiceOverEnabled: enabled) else { return }
        scheduleDismissal(for: presentation)
    }

    public func takeAccessibilityAnnouncement() -> AttributedString? {
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

    public func dismiss(_ presentation: Presentation) {
        guard current == presentation else { return }
        dismissal?.cancel()
        dismissal = nil
        current = nil
    }
}

extension EnvironmentValues {
    @Entry public var libraryToastCenter: LibraryToastCenter? = nil
}

extension View {
    public func frontAMLibraryToasts(_ center: LibraryToastCenter, open: @escaping (FrontAMToastDestination) -> Void) -> some View {
        modifier(LibraryToastOverlay(center: center, open: open))
    }

    public func libraryToastFeedback(_ center: LibraryToastCenter) -> some View {
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
            case .favorited, .unfavorited, .pinned, .unpinned, .playingNext, .addedToQueue, .error, .movedToFolder:
                return false
            default:
                return true
            }
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: center.current?.id) { _, new in
            guard new != nil else { return false }
            switch center.current?.toast {
            case .playingNext, .addedToQueue:
                return true
            default:
                return false
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

public enum LibraryHaptics {
    @MainActor private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)
    @MainActor private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    @MainActor private static let notificationGenerator = UINotificationFeedbackGenerator()

    public static func impact() {
        runOnMain {
            softGenerator.impactOccurred(intensity: 0.6)
            softGenerator.prepare()
        }
    }

    public static func lightImpact() {
        runOnMain {
            lightGenerator.impactOccurred()
            lightGenerator.prepare()
        }
    }

    public static func mediumImpact() {
        runOnMain {
            mediumGenerator.impactOccurred()
            mediumGenerator.prepare()
        }
    }

    public static func success() {
        runOnMain {
            notificationGenerator.notificationOccurred(.success)
            notificationGenerator.prepare()
        }
    }

    private static func runOnMain(_ play: @escaping @MainActor () -> Void) {
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
    let open: (FrontAMToastDestination) -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.libraryToastCenter, center)
            .overlay(alignment: .bottom) {
                if let presentation = center.current {
                    LibraryToastView(toast: presentation.toast, dismiss: { center.dismiss(presentation) },
                                     openRoute: open)
                        .padding(presentation.toast.insets)
                        .transition(reducesMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.9)))
                        .id(presentation.id)
                }
            }
            .animation(reducesMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.3), value: center.current)
    }
}

public enum FrontAMToastDestination { case playlist(String), folder(String) }

public struct LibraryToastView: View {
    public let toast: LibraryToast
    public let dismiss: () -> Void
    public let openRoute: (FrontAMToastDestination) -> Void

    public var body: some View {
        Group {
            if case .movedToFolder(let name, let folderID) = toast {
                movedFolder(name: name, id: folderID)
            } else {
                content
                    .frame(minHeight: 53)
                    .background(.regularMaterial, in: .rect(cornerRadius: 18))
                    .accessibilityElement(children: .combine)
            }
        }
        .accessibilityAction(named: "关闭提示", dismiss)
    }

    public func openFolder(_ folderID: String) {
        dismiss()
        openRoute(.folder(folderID))
    }

    private func movedFolder(name: String, id: String) -> some View {
        Button { openFolder(id) } label: {
            HStack(spacing: 10) {
                Image(systemName: toast.systemImage).font(.system(size: 17))
                VStack(alignment: .leading, spacing: 0) {
                    Text("已移至").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 2) {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(toast.title)
        .accessibilityHint("打开文件夹")
    }

    public func openPlaylist(_ playlistID: String) {
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

    public init(toast: LibraryToast,
                dismiss: @escaping () -> Void,
                openRoute: @escaping (FrontAMToastDestination) -> Void) {
        self.toast = toast
        self.dismiss = dismiss
        self.openRoute = openRoute
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
