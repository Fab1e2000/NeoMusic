import SwiftUI
import UIKit

/// 作者名字形显示提亮后的背景，透明按钮保留原有点击和菜单。
struct NowPlayingArtistButton: View {
    let track: ReferenceTrack
    /// 为 false 时只显示文字（左右滑动切歌时相邻曲目的预览），大小和按钮一样。
    var interactive = true
    var lineHeight: CGFloat = 26
    var fontSize: CGFloat = 20
    var fontSizeIsScaled = false
    @ScaledMetric private var scaledLineHeight: CGFloat

    init(track: ReferenceTrack, interactive: Bool = true, lineHeight: CGFloat = 26,
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
            NowPlayingArtistMenuButton(track: track, lineHeight: resolvedLineHeight)
                .background(alignment: .leading) {
                    label.accessibilityHidden(true)
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

/// Shares the page's rendered image: no extra artwork requests or palette calculation.
/// The brighter copy is confined to glyphs; the page background is untouched.
struct NowPlayingVibrantLabel: View {
    let text: String
    let fontSize: CGFloat
    var role: PlayerEDRRole = .artist
    var fontSizeIsScaled = false
    @Environment(\.playerEDRLevels) private var edrLevels
    @Environment(\.nowPlayingBackdropImage) private var image
    @Environment(\.nowPlayingUndimmedBackdropImage) private var undimmedImage
    @Environment(\.nowPlayingBackdropAnchor) private var backdropAnchor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerArtistEDREnabled) private var edrEnabled

    private var glyphs: some View {
        NowPlayingGlyphMask(text: text, fontSize: fontSize, fontSizeIsScaled: fontSizeIsScaled)
    }

    var body: some View {
        glyphs.hidden()
            .overlay {
                if edrEnabled, let image = undimmedImage ?? image, let backdropAnchor {
                    PlayerEDRArtistLabel(text: text, fontSize: fontSize, image: image, anchor: backdropAnchor,
                                         brightness: edrLevels.value(for: role), fontSizeIsScaled: fontSizeIsScaled)
                } else {
                    ZStack {
                        Color(white: 0.88)
                        if let image, let backdropAnchor {
                            NowPlayingAlignedBackdrop(image: image, anchor: backdropAnchor,
                                                      animated: !reduceMotion)
                                .brightness(0.65)
                        }
                    }
                    .clipped()
                    .mask { glyphs }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .allowsHitTesting(false)
    }
}

/// Retain the existing UIKit font metrics and truncation for the glyph mask.
private struct NowPlayingGlyphMask: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let fontSizeIsScaled: Bool

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.textColor = .white
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
        return label
    }

    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = PlayerEDRGlyphView.textFont(fontSize: fontSize, weight: .regular, isWhite: false,
                                               fontSizeIsScaled: fontSizeIsScaled, traits: label.traitCollection)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: uiView.font.lineHeight)
    }
}

/// A native anchored menu, matching the player's More button rather than
/// presenting a confirmation sheet. Merely rendering it starts no requests.
private struct NowPlayingArtistMenuButton: UIViewRepresentable {
    let track: ReferenceTrack
    let lineHeight: CGFloat
    @Environment(ReferencePlayerActions.self) private var actions

    func makeCoordinator() -> PlayerArtistMenuController { PlayerArtistMenuController() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .systemFont(ofSize: 20)
        button.titleLabel?.lineBreakMode = .byTruncatingTail
        // 原生 Vibrancy 负责文字，这里只保留点击区域和菜单。
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
        button.setTitle(track.artists, for: .normal)
        button.accessibilityLabel = track.artists
        button.isEnabled = !track.artists.isEmpty
        guard changed || !coordinator.hasConfiguredButton else { return }
        coordinator.hasConfiguredButton = true
        button.menu = coordinator.menu()
        button.showsMenuAsPrimaryAction = true
        button.preferredMenuElementOrder = .fixed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: lineHeight)
    }

    static func dismantleUIView(_ uiView: UIButton, coordinator: PlayerArtistMenuController) {
        coordinator.cancel()
    }
}

/// 作者名按钮和「更多」菜单共用艺人目标。
@MainActor final class PlayerArtistMenuController {
    private var track: ReferenceTrack?
    private weak var actions: ReferencePlayerActions?
    /// 作者名按钮的菜单和点击动作已经按当前歌曲配置过。
    var hasConfiguredButton = false

    @discardableResult
    func bind(track: ReferenceTrack?, actions: ReferencePlayerActions) -> Bool {
        let changed = self.track != track || self.actions !== actions
        self.track = track
        self.actions = actions
        return changed
    }

    /// 以前用来取消加载请求；现在没有请求，保留给调用方的生命周期。
    func cancel() {}

    /// 每位作者一个去处；来源只有一个去处（比如 DizzyLab 的社团页）时只有一项。
    func destinations() -> [String] {
        guard let track, !track.artists.isEmpty else { return [] }
        return actions?.artistNames(for: track) ?? []
    }

    /// 点击作者名时由系统展示可用的歌曲位置。
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

    /// 「更多」菜单里的入口：一位作者是直接前往的按钮，多位是子菜单。
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
