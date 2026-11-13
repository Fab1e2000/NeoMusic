import SwiftUI
import UIKit

/// Temporary playback information uses a centered glass information card.
struct NowPlayingAudioQualityControl: View {
    let quality: PlayerAudioQuality
    var openAudioQualitySettings: (() -> Void)?
    @State private var presenter = PlayerQualityPresentationController()

    var body: some View {
        Button {
            presenter.show(quality: quality, openSettings: quality.isLocalFormat ? nil : openAudioQualitySettings)
        } label: {
            NowPlayingAudioQualityBadge(quality: quality)
                .frame(minWidth: 44, minHeight: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("音频质量，\(quality.title)")
        .accessibilityValue(quality.detail ?? "")
        .accessibilityHint("显示当前播放资源的音频质量")
        .background { NowPlayingQualityPresentation(controller: presenter) }
    }
}

private struct NowPlayingQualityPresentation: UIViewControllerRepresentable {
    let controller: PlayerQualityPresentationController

    func makeUIViewController(context: Context) -> PlayerQualityPresentationController { controller }

    func updateUIViewController(_ controller: PlayerQualityPresentationController, context: Context) {}

    static func dismantleUIViewController(_ controller: PlayerQualityPresentationController, coordinator: ()) {
        controller.presentedViewController?.dismiss(animated: false)
    }
}

private final class PlayerQualityPresentationController: UIViewController, UIViewControllerTransitioningDelegate {
    func show(quality: PlayerAudioQuality, openSettings: (() -> Void)?) {
        guard presentedViewController == nil, let window = view.window else { return }
        let content = PlayerQualityInformation(quality: quality, canOpenSettings: openSettings != nil,
            openSettings: { [weak self] in self?.dismiss(animated: true, completion: openSettings) },
            done: { [weak self] in self?.dismiss(animated: true) })
        let host = UIHostingController(rootView: content)
        host.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .custom
        host.transitioningDelegate = self
        host.sizingOptions = [.preferredContentSize]
        host.preferredContentSize = host.sizeThatFits(in: CGSize(width: 320, height: window.bounds.height))
        present(host, animated: true)
    }

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?,
                                source: UIViewController) -> UIPresentationController? {
        QualityCardPresentation(presentedViewController: presented, presenting: presenting)
    }
    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        QualityCardTransition(isPresenting: true)
    }
    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        QualityCardTransition(isPresenting: false)
    }
}

private final class QualityCardPresentation: UIPresentationController {
    private let dimming = UIControl()

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        let safe = containerView.bounds.inset(by: containerView.safeAreaInsets)
        let size = presentedViewController.preferredContentSize
        let width = min(size.width, safe.width - 32)
        let height = min(size.height, safe.height - 32)
        return CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
    }
    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        dimming.frame = containerView.bounds
        dimming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        dimming.alpha = 0
        dimming.addTarget(self, action: #selector(close), for: .touchUpInside)
        dimming.accessibilityLabel = "关闭音频信息"
        containerView.insertSubview(dimming, at: 0)
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.dimming.alpha = 1
        })
    }
    override func dismissalTransitionWillBegin() {
        presentedViewController.transitionCoordinator?.animate(alongsideTransition: { _ in
            self.dimming.alpha = 0
        })
    }
    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { dimming.removeFromSuperview() }
    }
    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed { dimming.removeFromSuperview() }
    }
    override func containerViewWillLayoutSubviews() {
        presentedView?.bounds.size = frameOfPresentedViewInContainerView.size
        presentedView?.center = CGPoint(x: frameOfPresentedViewInContainerView.midX,
                                        y: frameOfPresentedViewInContainerView.midY)
    }
    @objc private func close() { presentedViewController.dismiss(animated: true) }
}

private final class QualityCardTransition: NSObject, UIViewControllerAnimatedTransitioning {
    let isPresenting: Bool
    init(isPresenting: Bool) { self.isPresenting = isPresenting }
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.2 : (isPresenting ? 0.3 : 0.25)
    }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = context.viewController(forKey: key),
              let view = context.view(forKey: isPresenting ? .to : .from) else {
            context.completeTransition(false); return
        }
        let scale = UIAccessibility.isReduceMotionEnabled ? 1.0 : 1.08
        if isPresenting {
            context.containerView.addSubview(view)
            view.frame = context.finalFrame(for: controller)
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
        UIView.animate(withDuration: transitionDuration(using: context), delay: 0,
                       options: [.curveEaseOut, .beginFromCurrentState]) {
            view.alpha = self.isPresenting ? 1 : 0
            view.transform = self.isPresenting ? .identity : CGAffineTransform(scaleX: scale, y: scale)
        } completion: { _ in
            let completed = !context.transitionWasCancelled
            if !completed || !self.isPresenting { view.alpha = 1; view.transform = .identity }
            context.completeTransition(completed)
        }
    }
}

private struct PlayerQualityInformation: View {
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
                if quality.isLocalFormat {
                    VStack(spacing: 10) {
                        Image(systemName: "waveform").font(.system(size: 26, weight: .medium))
                        Text(quality.title).font(.system(size: 21, weight: .bold, design: .rounded)).tracking(1)
                    }
                    .frame(width: 104, height: 100)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.pink.opacity(0.8), lineWidth: 2))
                    .foregroundStyle(.pink)
                } else if quality.isLossless {
                    PlayerLosslessSymbol()
                        .stroke(style: StrokeStyle(lineWidth: symbolWidth / 24, lineCap: .round, lineJoin: .round))
                } else {
                    Image(systemName: "waveform").resizable().scaledToFit()
                }
            }
            .foregroundStyle(LinearGradient(colors: [.white.opacity(0.5), Color(red: 1, green: 0.35, blue: 0.43)],
                                            startPoint: .leading, endPoint: .trailing))
            .frame(width: quality.isLocalFormat ? 104 : symbolWidth, height: quality.isLocalFormat ? 100 : symbolWidth * 36 / 66)
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
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
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

struct NowPlayingAudioQualityBadge: View {
    let quality: PlayerAudioQuality
    @ScaledMetric(relativeTo: .caption2) private var fontSize = 12
    @ScaledMetric(relativeTo: .caption2) private var symbolWidth = 14
    @ScaledMetric(relativeTo: .caption2) private var lineHeight = 18

    var body: some View {
        HStack(spacing: 4) {
            if quality.isLocalFormat {
                Image(systemName: "waveform").font(.system(size: 11))
            } else if quality.isLossless {
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
