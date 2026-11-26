import SwiftUI
import UIKit

struct NowPlayingArtistButton: View {
    let track: PlayerTrack
    var interactive = true
    var lineHeight: CGFloat = 26
    var fontSize: CGFloat = 20
    var fontSizeIsScaled = false
    @ScaledMetric private var scaledLineHeight: CGFloat

    init(track: PlayerTrack, interactive: Bool = true, lineHeight: CGFloat = 26,
         fontSize: CGFloat = 20, fontSizeIsScaled: Bool = false) {
        self.track = track
        self.interactive = interactive
        self.lineHeight = lineHeight
        self.fontSize = fontSize
        self.fontSizeIsScaled = fontSizeIsScaled
        _scaledLineHeight = ScaledMetric(wrappedValue: lineHeight, relativeTo: fontSize == 13 ? .footnote : .subheadline)
    }

    private var resolvedLineHeight: CGFloat {
        fontSizeIsScaled || fontSize == 20 ? lineHeight : scaledLineHeight
    }

    var body: some View {
        if interactive {
            label
                .accessibilityHidden(true)
                .frame(
                    maxWidth: .infinity,
                    minHeight: max(28, resolvedLineHeight),
                    maxHeight: max(28, resolvedLineHeight),
                    alignment: .leading
                )
                .overlay {
                    NowPlayingArtistMenuButton(track: track, lineHeight: resolvedLineHeight)
                }
        } else {
            label.frame(height: resolvedLineHeight)
        }
    }

    private var label: some View {
        NowPlayingVibrantLabel(text: track.artists, fontSize: fontSize, fontSizeIsScaled: fontSizeIsScaled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
    }
}

struct NowPlayingVibrantLabel: View {
    let text: String
    let fontSize: CGFloat
    var fontSizeIsScaled = false
    var opacity: Double = NowPlayingVisualHierarchy.subtitleOpacity
    @ScaledMetric private var scaledFontSize: CGFloat
    @Environment(\.trackSwipeVibrantEdge) private var trackSwipeEdge

    init(
        text: String,
        fontSize: CGFloat,
        fontSizeIsScaled: Bool = false,
        opacity: Double = NowPlayingVisualHierarchy.subtitleOpacity
    ) {
        self.text = text
        self.fontSize = fontSize
        self.fontSizeIsScaled = fontSizeIsScaled
        self.opacity = opacity
        _scaledFontSize = ScaledMetric(
            wrappedValue: fontSize,
            relativeTo: fontSize == 13 ? .footnote : .subheadline
        )
    }

    private var resolvedFontSize: CGFloat {
        (fontSizeIsScaled || fontSize == 20) ? fontSize : scaledFontSize
    }

    var body: some View {
        Text(text)
            .font(.system(size: resolvedFontSize, weight: .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .modifier(TrackSwipeVibrantEdgeModifier(edge: trackSwipeEdge))
            .nowPlayingPlusLighter(opacity)
            .accessibilityLabel(text)
            .allowsHitTesting(false)
    }
}

private struct TrackSwipeVibrantEdgeModifier: ViewModifier {
    let edge: TrackSwipeVibrantEdge?

    func body(content: Content) -> some View {
        let active = edge.map { $0.isActive && !$0.isPinned && $0.slotWidth > 1 } ?? false
        let offsetX = active ? ((edge?.motion.value ?? 0) + (edge?.baseOffset ?? 0)) : 0
        let leftStart = -(edge?.insets.leadingBleed ?? 0)
        let fadeInEnd = leftStart + (edge?.insets.leadingFade ?? 0)
        let rightEnd = (edge?.slotWidth ?? 0) + (edge?.insets.trailingBleed ?? 0)
        let fadeOutStart = rightEnd - (edge?.insets.trailingFade ?? 0)
        content.colorEffect(
            PlayerResources.shaders.trackSwipeHorizontalFade(
                .float4(
                    Float(offsetX),
                    Float(leftStart),
                    Float(fadeInEnd),
                    Float(fadeOutStart)
                ),
                .float(Float(rightEnd))
            ),
            isEnabled: active
        )
    }
}

private struct NowPlayingArtistMenuButton: UIViewRepresentable {
    let track: PlayerTrack
    let lineHeight: CGFloat
    @Environment(PlayerActions.self) private var actions

    func makeCoordinator() -> PlayerArtistMenuController { PlayerArtistMenuController() }

    func makeUIView(context: Context) -> UIButton {
        let button = ExpandedHitTestArtistButton(type: .system)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .systemFont(ofSize: 20)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        button.setTitleColor(.clear, for: .normal)
        button.accessibilityHint = String(localized: "打开歌曲位置菜单")
        configure(button, coordinator: context.coordinator)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        configure(button, coordinator: context.coordinator)
    }

    private func configure(_ button: UIButton, coordinator: PlayerArtistMenuController) {
        let changed = coordinator.bind(track: track, actions: actions)
        guard changed || !coordinator.hasConfiguredButton else { return }
        if changed {
            button.contextMenuInteraction?.dismissMenu()
        }
        button.setTitle(track.artists, for: .normal)
        button.accessibilityLabel = track.artists
        button.isEnabled = !track.artists.isEmpty
        coordinator.hasConfiguredButton = true
        button.menu = coordinator.menu()
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: max(28, lineHeight))
    }

    static func dismantleUIView(_ uiView: UIButton, coordinator: PlayerArtistMenuController) {
        coordinator.cancel()
    }
}

private final class ExpandedHitTestArtistButton: UIButton {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let verticalExpansion = max(0, (44 - bounds.height) / 2)
        return bounds.insetBy(dx: 0, dy: -verticalExpansion).contains(point)
    }
}

@MainActor final class PlayerArtistMenuController {
    private var track: PlayerTrack?
    private weak var actions: PlayerActions?
    var hasConfiguredButton = false

    @discardableResult
    func bind(track: PlayerTrack?, actions: PlayerActions) -> Bool {
        let changed = self.track != track || self.actions !== actions
        self.track = track
        self.actions = actions
        return changed
    }

    func cancel() {}

    func destinations() -> [String] {
        guard let track, !track.artists.isEmpty else { return [] }
        return actions?.artistNames(for: track) ?? []
    }

    func menu() -> UIMenu? {
        guard let track else { return nil }
        var items: [UIMenuElement] = []
        if !track.albumTitle.isEmpty {
            items.append(UIAction(title: String(localized: "前往专辑"), subtitle: track.albumTitle,
                                  image: UIImage(systemName: "square.stack")) { [weak self] _ in
                if let self, let track = self.track { self.actions?.openAlbum(track) }
            })
        }
        items.append(contentsOf: destinations().map { destination in
            UIAction(title: String(localized: "前往艺人"), subtitle: destination,
                     image: UIImage(systemName: "music.microphone")) { [weak self] _ in
                if let self, let track = self.track { self.actions?.openArtist(destination, track: track) }
            }
        })
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    func action(for button: UIButton) -> UIMenuElement? {
        let destinations = destinations()
        guard !destinations.isEmpty else { return nil }
        if destinations.count == 1, let only = destinations.first {
            return UIAction(title: String(localized: "查看艺术家"), image: UIImage(systemName: "music.microphone")) { [weak self] _ in
                if let self, let track = self.track { self.actions?.openArtist(only, track: track) }
            }
        }
        return UIMenu(title: String(localized: "查看艺术家"), image: UIImage(systemName: "music.microphone"),
                      children: destinations.map { destination in
            UIAction(title: destination, image: UIImage(systemName: "music.microphone")) { [weak self] _ in
                if let self, let track = self.track { self.actions?.openArtist(destination, track: track) }
            }
        })
    }
}
