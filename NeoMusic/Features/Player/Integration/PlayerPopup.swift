import FullScreenPlayer
// Source: NeoDizzy Features/Player/PlayerPopup.swift; see Resources/PlayerSourceNotices.txt.
import LNPopupUI
import SwiftUI
import UIKit

struct PlayerPopup: ViewModifier {
    @Binding var isPresented: Bool
    let isSuppressed: Bool
    let onClose: () -> Void
    var barColorScheme: ColorScheme? = nil
    var toasts: LibraryToastCenter? = nil

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(PlayerState.self) private var player
    @Environment(\.artworkLoadAction) private var loadArtwork
    @State private var artwork: UIImage?
    @State private var artworkTrackID: String?
    @State private var interactionDelegate = PlayerPopupInteractionDelegate()
    @State private var volumeHUDRefreshID = 0

    private var displayedTrack: PlayerTrack? { isSuppressed ? nil : player.currentTrack }
    private var isBarActive: Bool { displayedTrack != nil && !isPresented && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .environment(\.songPlaybackIndicatorsActive, !isPresented)
            .background {
                if displayedTrack != nil {
                    PlayerPopupArtworkPrefetcher(
                        isPresented: isPresented,
                        scenePhase: scenePhase,
                        loadArtwork: { loadArtwork($0) }
                    )
                }
            }
            .transaction { transaction in
                if reducesMotion { transaction.disablesAnimations = true }
            } body: { content in
                content.popup(isBarPresented: .constant(true), isPopupOpen: displayedTrack == nil ? .constant(false) : $isPresented, onOpen: {
                    volumeHUDRefreshID &+= 1
                }, onClose: onClose) {
                    PlayerPopupContent(track: displayedTrack, barImage: barImage,
                                       barColorScheme: barColorScheme ?? colorScheme,
                                       isActive: isPresented,
                                       isBarActive: isBarActive,
                                       toasts: toasts) { isPresented = false }
                        .environment(\.playerVolumeHUDRefreshID, volumeHUDRefreshID)
                }
            }
            .popupBarStyle(.floatingCompact)
            .popupContentViewCustomizer { view in
                view.overrideUserInterfaceStyle = .dark
                view.isTranslucent = false
                view.popupInteractionGestureRecognizer.delegate = interactionDelegate
            }
            .popupInteractionStyle(displayedTrack == nil ? .none : .automatic)
            .popupBarCustomizer { bar in
                let empty = displayedTrack == nil
                bar.popupOpenGestureRecognizer.isEnabled = !empty
                bar.barHighlightGestureRecognizer.isEnabled = !empty
                bar.isAccessibilityElement = empty
                bar.accessibilityLabel = empty ? "未在播放，迷你播放器" : nil
                bar.accessibilityTraits = empty ? [.staticText, .notEnabled] : []
            }
            .popupCloseButtonStyle(.none)
            .popupBarMarqueeScrollEnabled(isBarActive)
            .onChange(of: displayedTrack == nil, initial: true) { _, empty in
                if empty { isPresented = false }
            }
            .task(id: displayedTrack) {
                let track = displayedTrack
                if artworkTrackID != track?.id {
                    artwork = track?.coverURL.flatMap { Self.cachedArtwork(for: $0) }
                    artworkTrackID = track?.id
                }
                guard let url = track?.coverURL else {
                    if track?.artworkLoadID == nil { artwork = nil }
                    return
                }
                let request = PlayerArtworkRequest(url: url, pixelWidth: 160, pixelHeight: 160)
                if let cached = ArtworkImagePipeline.cached(request, usesTargetBounds: true) {
                    artwork = cached
                    return
                }
                guard let image = try? await ArtworkImagePipeline.load(request, usesTargetBounds: true),
                      !Task.isCancelled else { return }
                artwork = image
            }
    }

    private var barImage: PopupItemViewImage {
        PopupItemViewImage {
            if let artwork = displayedArtwork {
                NowPlayingBackdropImage(image: artwork, animated: !reducesMotion)
            } else {
                ArtworkView(artwork: .missing, cornerRadius: 3)
                    .environment(\.nativeArtworkSurfaceEnabled, false)
            }
        }
    }

    private var displayedArtwork: UIImage? {
        guard let track = displayedTrack,
              track.coverURL != nil || track.artworkLoadID != nil else { return nil }
        if let url = track.coverURL, let cached = Self.cachedArtwork(for: url) {
            return cached
        }
        return artworkTrackID == track.id ? artwork : nil
    }

    static func cachedArtwork(for url: URL) -> UIImage? {
        let request = PlayerArtworkRequest(url: url, pixelWidth: 160, pixelHeight: 160)
        return ArtworkImagePipeline.cached(request, usesTargetBounds: true)
            ?? ArtworkImagePipeline.displayFallback(request, usesTargetBounds: true)
    }

}

private struct PlayerPopupContent: View {
    let track: PlayerTrack?
    let barImage: PopupItemViewImage
    let barColorScheme: ColorScheme
    let isActive: Bool
    let isBarActive: Bool
    var toasts: LibraryToastCenter? = nil
    let onDismiss: () -> Void
    @Environment(PlayerState.self) private var player

    var body: some View {
        Group {
            if let track {
                PlayerNowPlayingHostView(onDismiss: onDismiss, isActive: isActive)
                    .modifier(OptionalPlayerToastModifier(toasts: isActive ? toasts : nil))
                    .onChange(of: isActive, initial: true) { _, active in
                        AppLogger.ui.notice("popup.content active=\(active) titleEmpty=\(track.title.isEmpty) cover=\(track.coverURL != nil)")
                    }
            } else {
                Color.clear
            }
        }
        .popupItem {
            PopupItem(id: track?.id, image: barImage,
                      accessibilityLabel: [track?.title ?? "未在播放", track?.artists ?? "", "迷你播放器"]
                        .filter { !$0.isEmpty }.joined(separator: "，"),
                      accessibilityHint: track == nil ? "" : "打开正在播放", title: {
                Group {
                    if let track {
                        MiniPlayerTitle(fallbackTrack: track, isActive: isBarActive)
                            .environment(player)
                    } else {
                        Text("未在播放")
                            .font(.footnote.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)
                    }
                }
                .environment(\.colorScheme, barColorScheme)
                .accessibilityIdentifier("mini.trackTitle")
            }, buttons: {
                ToolbarItem(placement: .popupBar) {
                    MiniPlayerControlsObserver(hasTrack: track != nil)
                        .environment(player)
                        .environment(\.colorScheme, barColorScheme)
                }
            })
        }
    }
}

private struct PlayerPopupArtworkPrefetcher: View {
    let isPresented: Bool
    let scenePhase: ScenePhase
    let loadArtwork: (String) -> Void
    @Environment(PlayerState.self) private var player

    private var prefetchURLs: [URL] {
        scenePhase == .active && (isPresented || player.isPlaying) ? player.adjacentArtworkURLs : []
    }

    private var artworkLoadIDs: [String] {
        let current = [player.currentTrack?.artworkLoadID].compactMap { $0 }
        guard scenePhase == .active, isPresented || player.isPlaying else { return current }
        return current + [player.previousInOrder?.track.artworkLoadID, player.nextInOrder?.track.artworkLoadID].compactMap { $0 }
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: artworkLoadIDs) {
                for id in Set(artworkLoadIDs) { loadArtwork(id) }
            }
            .task(id: prefetchURLs) {
                let requests = prefetchURLs.flatMap { url in
                    [160, 240].map { PlayerArtworkRequest(url: url, pixelWidth: $0, pixelHeight: $0) }
                }
                await ArtworkImagePipeline.prefetch(requests, usesTargetBounds: true)
            }
    }
}

private struct MiniPlayerControlsObserver: View {
    let hasTrack: Bool
    @Environment(PlayerState.self) private var player

    var body: some View {
        MiniPlayerControls(
            isPlaying: hasTrack && player.isPlaying,
            canPlayNext: hasTrack && player.canPlayNext,
            togglePlayback: player.togglePlayback,
            next: player.next
        )
        .disabled(!hasTrack)
        .opacity(hasTrack ? 1 : 0.3)
    }
}

private struct OptionalPlayerToastModifier: ViewModifier {
    let toasts: LibraryToastCenter?
    func body(content: Content) -> some View {
        content.overlay {
            if let toasts {
                Color.clear.libraryToasts(toasts)
            }
        }
    }
}

private struct MiniPlayerTitle: View {
    let fallbackTrack: PlayerTrack
    let isActive: Bool
    @Environment(PlayerState.self) private var player
    @Environment(\.popupBarPlacement) private var placement
    @ScaledMetric(relativeTo: .footnote) private var titleSize = 13.0
    @ScaledMetric(relativeTo: .caption) private var artistSize = 12.0
    @ScaledMetric(relativeTo: .footnote) private var compactHeight = 18.0
    @ScaledMetric(relativeTo: .footnote) private var regularHeight = 36.0

    var body: some View {
        let compact = placement == .inline
        let activeTrack = player.currentTrack ?? fallbackTrack
        ReferenceMiniPlayerTitlePager(height: compact ? compactHeight : regularHeight, song: activeTrack) { song, marqueeActive in
            NowPlayingMarqueeText(text: song.title, isActive: isActive && marqueeActive && !compact)
                .font(.system(size: titleSize, weight: .medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } artist: { song, _ in
            Text(song.artists)
                .font(.system(size: artistSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: compact ? 0 : nil)
                .opacity(compact ? 0 : 1)
                .accessibilityHidden(compact)
        }
        .padding(.leading, 8)
        .frame(height: compact ? compactHeight : regularHeight)
    }
}

struct MiniPlayerControls: View {
    let isPlaying: Bool
    let canPlayNext: Bool
    let togglePlayback: () -> Void
    let next: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.popupBarPlacement) private var placement
    @State private var nextTrigger = 0

    var body: some View {
        let compact = placement == .inline
        HStack(spacing: 0) {
            Button(action: togglePlayback) {
                NowPlayingPlayPauseIcon(isPlaying: isPlaying, reducesMotion: reducesMotion,
                                        playOffsetX: 0.8)
                    .frame(width: 14, height: 17)
                    .offset(x: 8)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(NowPlayingTransportButtonStyle(reducesMotion: reducesMotion,
                                                        springsBack: true, diameter: 44, showsHighlight: false))
            .accessibilityLabel(isPlaying ? "暂停" : "播放")
            .accessibilityIdentifier("mini.playPause")
            Button {
                nextTrigger += 1
                next()
            } label: {
                NowPlayingSkipIcon(direction: .forward, trigger: nextTrigger,
                                   reducesMotion: reducesMotion, cornerRadius: 1.3)
                    .frame(width: 24, height: 17)
                    .offset(x: 8)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(NowPlayingTransportButtonStyle(reducesMotion: reducesMotion, diameter: 44, showsHighlight: false))
            .disabled(!canPlayNext)
            .accessibilityLabel("下一首")
            .accessibilityIdentifier("mini.next")
            .frame(width: compact ? 0 : 44)
            .opacity(compact ? 0 : 1)
            .clipped()
            .allowsHitTesting(!compact)
            .accessibilityHidden(compact)
        }
        .tint(.primary)
        .foregroundStyle(.primary)
        .fixedSize()
    }
}

@MainActor final class PlayerPopupInteractionDelegate: NSObject, UIGestureRecognizerDelegate {
    private weak var queuePanAllowedToDismiss: UIPanGestureRecognizer?

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        shouldReceiveTouch(in: touch.view)
    }

    func shouldReceiveTouch(in hitView: UIView?) -> Bool {
        queuePanAllowedToDismiss = nil
        var view = hitView
        while let candidate = view {
            if let scrollView = candidate as? UIScrollView,
               scrollView.panGestureRecognizer.name == PlayerInteraction.queueScrollGestureName {
                // LN can drive dismissal from this scroll pan. Sample the top before the list moves
                // so a drag that only reaches the top cannot also dismiss the player.
                if scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top {
                    queuePanAllowedToDismiss = scrollView.panGestureRecognizer
                }
                return false
            }
            view = candidate.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let travel = pan.translation(in: pan.view)
        return abs(travel.y) >= abs(travel.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if otherGestureRecognizer.name == PlayerInteraction.queueScrollGestureName {
            return otherGestureRecognizer === queuePanAllowedToDismiss
        }
        return otherGestureRecognizer.name != PlayerInteraction.trackSwipeGestureName
    }
}
