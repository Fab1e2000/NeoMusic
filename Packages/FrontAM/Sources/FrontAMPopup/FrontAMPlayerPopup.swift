// Source: NeoDizzy Features/Player/PlayerPopup.swift; see THIRD_PARTY_NOTICES.md.
import FrontAMPlayer
import LNPopupUI
import SwiftUI
import UIKit

public struct FrontAMPlayerPopup<MissingArtwork: View, ExpandedContent: View>: ViewModifier {
    @Binding private var isPresented: Bool
    private let isSuppressed: Bool
    private let artworkProvider: PlayerArtworkProvider
    private let barColorScheme: ColorScheme?
    private let onClose: () -> Void
    private let onContentActivityChange: ((Bool, PlayerTrack) -> Void)?
    private let missingArtwork: () -> MissingArtwork
    private let expandedContent: (Bool, @escaping () -> Void) -> ExpandedContent

    public init(
        isPresented: Binding<Bool>,
        isSuppressed: Bool = false,
        artwork: PlayerArtworkProvider,
        barColorScheme: ColorScheme? = nil,
        onClose: @escaping () -> Void = {},
        onContentActivityChange: ((Bool, PlayerTrack) -> Void)? = nil,
        @ViewBuilder missingArtwork: @escaping () -> MissingArtwork,
        @ViewBuilder expandedContent: @escaping (_ isActive: Bool, _ onDismiss: @escaping () -> Void) -> ExpandedContent
    ) {
        _isPresented = isPresented
        self.isSuppressed = isSuppressed
        artworkProvider = artwork
        self.barColorScheme = barColorScheme
        self.onClose = onClose
        self.onContentActivityChange = onContentActivityChange
        self.missingArtwork = missingArtwork
        self.expandedContent = expandedContent
    }

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(PlayerState.self) private var player
    @State private var artwork: UIImage?
    @State private var artworkTrackID: String?
    @State private var interactionDelegate = PlayerPopupInteractionDelegate()
    @State private var volumeHUDRefreshID = 0

    private var displayedTrack: PlayerTrack? { isSuppressed ? nil : player.currentTrack }
    private var isBarActive: Bool { displayedTrack != nil && !isPresented && scenePhase == .active }

    public func body(content: Content) -> some View {
        content
            .background {
                if displayedTrack != nil {
                    PlayerPopupArtworkPrefetcher(
                        isPresented: isPresented,
                        scenePhase: scenePhase,
                        artwork: artworkProvider
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
                                       interactionDelegate: interactionDelegate,
                                       onContentActivityChange: onContentActivityChange) {
                        expandedContent(isPresented) { isPresented = false }
                    }
                        .environment(\.playerVolumeHUDRefreshID, volumeHUDRefreshID)
                }
            }
            .popupBarStyle(.floatingCompact)
            .popupContentViewCustomizer { view in
                view.overrideUserInterfaceStyle = .dark
                view.isTranslucent = false
                view.popupInteractionGestureRecognizer.delegate = interactionDelegate
                interactionDelegate.popupContentView = view
            }
            .popupInteractionStyle(displayedTrack == nil ? .none : .automatic)
            .popupBarCustomizer { bar in
                interactionDelegate.popupBar = bar
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
                    artwork = track?.coverURL.flatMap { PlayerPopupArtwork.cached(for: $0, using: artworkProvider) }
                    artworkTrackID = track?.id
                }
                guard let url = track?.coverURL else {
                    if track?.artworkLoadID == nil { artwork = nil }
                    return
                }
                let request = PlayerPopupArtwork.request(for: url)
                if let cached = artworkProvider.cached(request) {
                    artwork = cached
                    return
                }
                guard let image = try? await artworkProvider.load(request),
                      !Task.isCancelled else { return }
                artwork = image
            }
    }

    private var barImage: PopupItemViewImage {
        PopupItemViewImage {
            if let artwork = displayedArtwork {
                NowPlayingBackdropImage(image: artwork, animated: !reducesMotion)
            } else {
                missingArtwork()
            }
        }
    }

    private var displayedArtwork: UIImage? {
        guard let track = displayedTrack,
              track.coverURL != nil || track.artworkLoadID != nil else { return nil }
        if let url = track.coverURL, let cached = PlayerPopupArtwork.cached(for: url, using: artworkProvider) {
            return cached
        }
        return artworkTrackID == track.id ? artwork : nil
    }

}

@MainActor enum PlayerPopupArtwork {
    static func request(for url: URL) -> PlayerArtworkRequest {
        PlayerArtworkRequest(url: url, pixelWidth: 160, pixelHeight: 160)
    }

    static func cached(for url: URL, using artwork: PlayerArtworkProvider) -> UIImage? {
        let request = request(for: url)
        return artwork.cached(request) ?? artwork.displayFallback(request)
    }
}

private struct PlayerPopupContent<ExpandedContent: View>: View {
    let track: PlayerTrack?
    let barImage: PopupItemViewImage
    let barColorScheme: ColorScheme
    let isActive: Bool
    let isBarActive: Bool
    let interactionDelegate: PlayerPopupInteractionDelegate
    let onContentActivityChange: ((Bool, PlayerTrack) -> Void)?
    @ViewBuilder let expandedContent: () -> ExpandedContent
    @Environment(PlayerState.self) private var player

    var body: some View {
        Group {
            if let track {
                expandedContent()
                    .onChange(of: isActive, initial: true) { _, active in
                        onContentActivityChange?(active, track)
                    }
            } else {
                Color.clear
            }
        }
        .environment(\.playerTrackSwipeGestureRole, interactionDelegate.trackSwipeRole(for:))
        .popupItem {
            PopupItem(id: track?.id, image: barImage,
                      accessibilityLabel: [track?.title ?? "未在播放", track?.artists ?? "", "迷你播放器"]
                        .filter { !$0.isEmpty }.joined(separator: "，"),
                      accessibilityHint: track == nil ? "" : "打开正在播放", title: {
                Group {
                    if let track {
                        MiniPlayerTitle(fallbackTrack: track, isActive: isBarActive)
                            .environment(player)
                            .environment(\.playerTrackSwipeGestureRole, interactionDelegate.trackSwipeRole(for:))
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
    let artwork: PlayerArtworkProvider
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
                for id in Set(artworkLoadIDs) { artwork.prepare(id) }
            }
            .task(id: prefetchURLs) {
                let requests = prefetchURLs.flatMap { url in
                    [160, 240].map { PlayerArtworkRequest(url: url, pixelWidth: $0, pixelHeight: $0) }
                }
                await artwork.prefetch(requests)
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

private struct MiniPlayerControls: View {
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
    weak var popupBar: LNPopupBar?
    weak var popupContentView: LNPopupContentView?
    private weak var queuePanAllowedToDismiss: UIPanGestureRecognizer?

    func trackSwipeRole(for gesture: UIGestureRecognizer) -> PlayerTrackSwipeGestureRole? {
        if gesture === popupBar?.barHighlightGestureRecognizer { return .highlight }
        if gesture === popupBar?.popupOpenGestureRecognizer ||
            gesture === popupContentView?.popupInteractionGestureRecognizer {
            return .yieldsToTrackSwipe
        }
        return nil
    }

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
