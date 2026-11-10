import SwiftUI
import UIKit

/// Temporary playback information uses UIKit's native popover lifecycle.
struct NowPlayingAudioQualityControl: View {
    let quality: PlayerAudioQuality
    var openAudioQualitySettings: (() -> Void)?
    @State private var isPresented = false
    @State private var opensSettingsAfterDismiss = false

    var body: some View {
        Button { isPresented = true } label: {
            NowPlayingAudioQualityBadge(quality: quality)
                .frame(minWidth: 44, minHeight: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("音频质量，\(quality.title)")
        .accessibilityValue(quality.detail ?? "")
        .accessibilityHint("显示当前播放资源的音频质量")
        .background {
            NowPlayingQualityPopover(isPresented: $isPresented, quality: quality,
                                     canOpenSettings: openAudioQualitySettings != nil,
                                     openSettings: {
                opensSettingsAfterDismiss = true
                isPresented = false
            }, done: { isPresented = false }, didDismiss: openRequestedSettings)
        }
    }

    private func openRequestedSettings() {
        guard opensSettingsAfterDismiss else { return }
        opensSettingsAfterDismiss = false
        openAudioQualitySettings?()
    }
}

private struct NowPlayingQualityPopover: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let quality: PlayerAudioQuality
    let canOpenSettings: Bool
    let openSettings: () -> Void
    let done: () -> Void
    let didDismiss: () -> Void

    func makeUIViewController(context: Context) -> PlayerQualityPopoverController {
        PlayerQualityPopoverController()
    }

    func updateUIViewController(_ controller: PlayerQualityPopoverController, context: Context) {
        controller.didDismiss = {
            isPresented = false
            didDismiss()
        }
        let content = NowPlayingAudioQualityInfo(quality: quality, canOpenSettings: canOpenSettings,
                                                openSettings: openSettings, done: done)
        controller.update(content: content, isPresented: isPresented)
    }

    static func dismantleUIViewController(_ controller: PlayerQualityPopoverController, coordinator: ()) {
        let host = controller.presentedViewController as? UIHostingController<NowPlayingAudioQualityInfo>
        host?.dismiss(animated: false)
    }
}

private final class PlayerQualityPopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    var didDismiss: () -> Void = {}

    func update(content: NowPlayingAudioQualityInfo, isPresented: Bool) {
        if let host = presentedViewController as? UIHostingController<NowPlayingAudioQualityInfo> {
            if isPresented {
                host.rootView = content
            } else if !host.isBeingDismissed {
                dismiss(animated: true) { [weak self] in self?.didDismiss() }
            }
            return
        }
        guard isPresented, let window = view.window else { return }
        let host = UIHostingController(rootView: content)
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .popover
        host.sizingOptions = [.preferredContentSize]
        host.preferredContentSize = host.sizeThatFits(in: CGSize(width: 320,
                                                               height: window.safeAreaLayoutGuide.layoutFrame.height))
        guard let popover = host.popoverPresentationController else { return }
        popover.delegate = self
        popover.permittedArrowDirections = []
        popover.canOverlapSourceViewRect = true
        popover.sourceView = window
        let safeFrame = window.safeAreaLayoutGuide.layoutFrame
        popover.sourceRect = CGRect(x: safeFrame.midX, y: safeFrame.midY, width: 0, height: 0)
        present(host, animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController,
                                   traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        didDismiss()
    }
}

struct NowPlayingAudioQualityBadge: View {
    let quality: PlayerAudioQuality
    @ScaledMetric(relativeTo: .caption2) private var fontSize = 12
    @ScaledMetric(relativeTo: .caption2) private var symbolWidth = 14
    @ScaledMetric(relativeTo: .caption2) private var lineHeight = 18

    var body: some View {
        HStack(spacing: 4) {
            if quality.isLossless {
                PlayerLosslessSymbol()
                    .stroke(style: StrokeStyle(lineWidth: symbolWidth / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: symbolWidth, height: symbolWidth * 36 / 66)
            }
            Text(quality.title).font(.system(size: fontSize, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 6)
        .frame(minHeight: lineHeight)
        .background(.white.opacity(0.08), in: .rect(cornerRadius: 4))
        .accessibilityHidden(true)
    }
}

private struct NowPlayingAudioQualityInfo: View {
    let quality: PlayerAudioQuality
    let canOpenSettings: Bool
    let openSettings: () -> Void
    let done: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var titleSize = 17
    @ScaledMetric(relativeTo: .body) private var symbolWidth = 66

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if quality.isLossless {
                    PlayerLosslessSymbol()
                        .stroke(style: StrokeStyle(lineWidth: symbolWidth / 24, lineCap: .round, lineJoin: .round))
                } else {
                    Image(systemName: "waveform").resizable().scaledToFit()
                }
            }
            .foregroundStyle(LinearGradient(colors: [.white.opacity(0.5), Color(red: 1, green: 0.35, blue: 0.43)],
                                            startPoint: .leading, endPoint: .trailing))
            .frame(width: symbolWidth, height: symbolWidth * 36 / 66)
            .accessibilityHidden(true)
            .padding(.top, 43)
            .padding(.bottom, 39)

            VStack(spacing: 4) {
                Text(quality.title).font(.system(size: titleSize))
                if let detail = quality.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 24)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            if usesVerticalButtons {
                VStack(spacing: 8) { settingsButton; doneButton }
                    .padding(.horizontal, 16)
            } else {
                HStack(spacing: 8) { settingsButton; doneButton }
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var usesVerticalButtons: Bool {
        dynamicTypeSize.isAccessibilitySize || titleSize * 6 + 16 > 140
    }

    private func buttonHeight(for title: String) -> CGFloat {
        guard usesVerticalButtons else { return 48 }
        let bounds = (title as NSString).boundingRect(with: CGSize(width: 272, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [.font: UIFont.systemFont(ofSize: titleSize, weight: .semibold)],
            context: nil)
        return max(48, ceil(bounds.height) + 16)
    }

    private var settingsButton: some View {
        PlayerQualityDialogButton(title: "音频质量设置", fontSize: titleSize,
                                  isPrimary: false, isEnabled: canOpenSettings,
                                  allowsWrapping: usesVerticalButtons, action: openSettings)
            .frame(height: buttonHeight(for: "音频质量设置"))
    }

    private var doneButton: some View {
        PlayerQualityDialogButton(title: "好", fontSize: titleSize,
                                  isPrimary: true, isEnabled: true,
                                  allowsWrapping: usesVerticalButtons, action: done)
            .frame(height: buttonHeight(for: "好"))
    }
}

private struct PlayerQualityDialogButton: UIViewRepresentable {
    let title: String
    let fontSize: CGFloat
    let isPrimary: Bool
    let isEnabled: Bool
    let allowsWrapping: Bool
    let action: () -> Void

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func activate() { action() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton()
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        var configuration = isPrimary ? UIButton.Configuration.prominentGlass() : .glass()
        configuration.title = title
        let verticalInset: CGFloat = allowsWrapping ? 8 : 0
        configuration.contentInsets = NSDirectionalEdgeInsets(top: verticalInset, leading: 8,
                                                             bottom: verticalInset, trailing: 8)
        configuration.cornerStyle = .capsule
        configuration.titleLineBreakMode = allowsWrapping ? .byWordWrapping : .byClipping
        configuration.baseForegroundColor = isPrimary ? .black : .white
        if isPrimary { configuration.baseBackgroundColor = .white }
        let buttonFontSize = fontSize
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var attributes = incoming
            attributes.font = .systemFont(ofSize: buttonFontSize, weight: .semibold)
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.numberOfLines = allowsWrapping ? 0 : 1
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 140, height: proposal.height ?? 48)
    }
}

/// Vector adaptation of the supplied lossless mark.
private struct PlayerLosslessSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for offset in [CGFloat(0), 11, 22] {
            path.move(to: CGPoint(x: 1 + offset, y: 20))
            path.addCurve(to: CGPoint(x: 14 + offset, y: 8),
                          control1: CGPoint(x: 4 + offset, y: -2),
                          control2: CGPoint(x: 10 + offset, y: -4))
            path.addCurve(to: CGPoint(x: 29 + offset, y: 34),
                          control1: CGPoint(x: 19 + offset, y: 20),
                          control2: CGPoint(x: 21 + offset, y: 38))
            path.addCurve(to: CGPoint(x: 43 + offset, y: 15),
                          control1: CGPoint(x: 37 + offset, y: 37),
                          control2: CGPoint(x: 40 + offset, y: 30))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 66, y: rect.height / 36)
            .translatedBy(x: rect.minX, y: rect.minY))
    }
}

#if DEBUG
/// All content is an isolated layout example, with no playback or account side effects.
struct PlayerAudioQualityPreview: View {
    let openAudioQualitySettings: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var content: PlayerAudioQualityPreviewContent?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let content {
                ReferenceNowPlayingView(onDismiss: { dismiss() })
                    .environment(content.player)
                    .environment(content.library)
                    .environment(ReferencePlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
                        addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in },
                        audioQuality: { id in
                            id == content.owner.current.id
                                ? PlayerAudioQuality(title: "无损", isLossless: true) : nil
                        }, openAudioQualitySettings: openAudioQualitySettings))
                    .overlay(alignment: .topLeading) {
                        Text("示例数据 · 暂停资源")
                            .font(.caption2).dynamicTypeSize(.large).lineLimit(1)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 16).padding(.top, 4)
                            .allowsHitTesting(false)
                    }
            } else if let loadError {
                ContentUnavailableView("无法读取示例", systemImage: "music.note", description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task {
            guard content == nil else { return }
            do { content = try PlayerAudioQualityPreviewContent() }
            catch { loadError = error.localizedDescription }
        }
    }
}

@MainActor private final class PlayerAudioQualityPreviewContent {
    let owner: NowPlayingModel
    let player: ReferencePlayerState
    let library: ReferenceLibrary
    private let directory: URL

    init() throws {
        guard let data = UIImage(named: "AlbumSample17")?.jpegData(compressionQuality: 0.92) else {
            throw URLError(.cannotDecodeContentData)
        }
        directory = URL.temporaryDirectory.appendingPathComponent("NeoMusicQualityPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artwork = directory.appendingPathComponent("cover.jpg")
        try data.write(to: artwork)
        let song = LibrarySongItem(id: "quality-preview", title: "Window Light", artist: "NeoMusic 示例",
            album: "音频质量版式预览", albumArtist: "NeoMusic 示例", trackNumber: 1,
            artwork: .file(artwork), artworkURL: artwork, duration: 243)
        owner = NowPlayingModel(queue: [song], currentIndex: 0, isPlaying: false, elapsed: 17)
        owner.repeatMode = .off
        player = ReferencePlayerState(model: owner)
        library = ReferenceLibrary(reader: ReferenceLyricsReader(storageDirectory: directory.appendingPathComponent("Lyrics"),
                                                                  root: directory, resolveAudioURL: { _ in nil }))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

#Preview("音频质量 · 示例数据") {
    NavigationStack { PlayerAudioQualityPreview(openAudioQualitySettings: {}) }
}
#endif
