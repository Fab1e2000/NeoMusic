// Source: NeoDizzy Features/Player/PlayerPopup.swift; see Resources/PlayerSourceNotices.txt.
import LNPopupUI
import Nuke
import SwiftUI
import UIKit

/// Shared presentation adapter; playback and full-screen content retain their existing owners.
struct PlayerPopup: ViewModifier {
    @Binding var isPresented: Bool
    let isSuppressed: Bool
    let onClose: () -> Void
    var barColorScheme: ColorScheme? = nil

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ReferencePlayerState.self) private var player
    @Environment(\.artworkLoadAction) private var loadArtwork
    @AppStorage(ImmersiveMode.storageKey) private var isImmersive = false
    @State private var isBarPresented = false
    @State private var hasPresentedBar = false
    @State private var artwork: UIImage?
    @State private var artworkTrackID: String?
    @State private var interactionDelegate = PlayerPopupInteractionDelegate()

    private var shouldShowBar: Bool { player.currentTrack != nil && !isSuppressed }
    private var isBarActive: Bool { shouldShowBar && !isPresented && scenePhase == .active }
    private var prefetchURLs: [URL] { scenePhase == .active && (isPresented || player.isPlaying) ? player.adjacentArtworkURLs : [] }
    private var artworkLoadIDs: [String] {
        let current = [player.currentTrack?.artworkLoadID].compactMap { $0 }
        guard scenePhase == .active, isPresented || player.isPlaying else { return current }
        return current + [player.previousInOrder?.track.artworkLoadID, player.nextInOrder?.track.artworkLoadID].compactMap { $0 }
    }

    func body(content: Content) -> some View {
        content
            .popup(isBarPresented: $isBarPresented, isPopupOpen: $isPresented, onClose: onClose) {
                PlayerPopupContent(barImage: barImage,
                                   barColorScheme: barColorScheme ?? colorScheme,
                                   isActive: isPresented && scenePhase == .active,
                                   isBarActive: isBarActive) { isPresented = false }
                    .statusBarHidden(isImmersive)
            }
            .popupBarStyle(.floatingCompact)
            .popupBarCustomizer { bar in
                bar.overrideUserInterfaceStyle = barColorScheme.map { UIUserInterfaceStyle($0) } ?? .unspecified
            }
            .popupContentViewCustomizer { view in
                view.overrideUserInterfaceStyle = .dark
                view.popupInteractionGestureRecognizer.delegate = interactionDelegate
            }
            .popupInteractionStyle(.automatic)
            .popupCloseButtonStyle(.none)
            .popupBarMarqueeScrollEnabled(isBarActive)
            .onChange(of: shouldShowBar, initial: true) { _, visible in
                PerformanceDiagnostics.restoration("popup.visibility visible=\(visible) suppressed=\(isSuppressed) track=\(player.currentTrack != nil) titleEmpty=\(player.currentTrack?.title.isEmpty ?? true)")
                let restoresPausedBar = visible && !hasPresentedBar && !player.isPlaying && !isPresented
                if restoresPausedBar {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isBarPresented = true
                        hasPresentedBar = true
                    }
                } else {
                    if !visible { isPresented = false }
                    isBarPresented = visible
                    if visible { hasPresentedBar = true }
                }
            }
            .task(id: player.currentTrack) {
                let track = player.currentTrack
                if artworkTrackID != track?.id {
                    artwork = nil
                    artworkTrackID = track?.id
                }
                guard let url = track?.coverURL else { return }
                if let cached = LocalArtworkImages.cached(url, pixels: 160) {
                    artwork = cached
                    return
                }
                var request = ImageRequest(url: url)
                request.thumbnail = .init(size: CGSize(width: 160, height: 160), unit: .pixels,
                                          contentMode: .aspectFill)
                guard let image = try? await ImagePipeline.shared.image(for: request),
                      !Task.isCancelled else { return }
                artwork = image
            }
            .task(id: artworkLoadIDs) {
                for id in Set(artworkLoadIDs) { loadArtwork(id) }
            }
            .task(id: prefetchURLs) {
                let requests = prefetchURLs.flatMap { url in
                    [160, 240].map { size in
                        var request = ImageRequest(url: url)
                        request.thumbnail = .init(size: CGSize(width: size, height: size), unit: .pixels,
                                                  contentMode: .aspectFill)
                        return request
                    }
                }
                await ArtworkImagePipeline.prefetch(requests)
            }
    }

    private var barImage: PopupItemViewImage {
        PopupItemViewImage {
            if let artwork, artworkTrackID == player.currentTrack?.id {
                NowPlayingBackdropImage(image: artwork, animated: !reducesMotion)
            } else {
                ArtworkView(artwork: .missing, cornerRadius: 3)
                    .environment(\.nativeArtworkSurfaceEnabled, false)
            }
        }
    }

}

private struct PlayerPopupContent: View {
    let barImage: PopupItemViewImage
    let barColorScheme: ColorScheme
    let isActive: Bool
    let isBarActive: Bool
    let onDismiss: () -> Void
    @Environment(ReferencePlayerState.self) private var player

    var body: some View {
        Group {
            if let track = player.currentTrack {
                ReferenceNowPlayingView(onDismiss: onDismiss, isActive: isActive)
                    .onChange(of: isActive, initial: true) { _, active in
                        PerformanceDiagnostics.restoration("popup.content active=\(active) titleEmpty=\(track.title.isEmpty) cover=\(track.coverURL != nil)")
                    }
                    .popupItem {
                        PopupItem(id: track.id, image: barImage,
                                  accessibilityLabel: [track.title, track.artists, "迷你播放器"].filter { !$0.isEmpty }.joined(separator: "，"),
                                  accessibilityHint: "打开正在播放", title: {
                            MiniPlayerTitle(track: track, isActive: isBarActive)
                                .environment(player)
                                .environment(\.colorScheme, barColorScheme)
                                .accessibilityIdentifier("mini.trackTitle")
                        }, buttons: {
                            ToolbarItem(placement: .popupBar) {
                                MiniPlayerControls(isPlaying: player.isPlaying, isLoading: player.isLoading,
                                                   canPlayNext: player.canPlayNext,
                                                   togglePlayback: player.togglePlayback, next: player.next)
                                    .environment(\.colorScheme, barColorScheme)
                            }
                        })
                    }
            }
        }
    }
}

/// Placement invalidates only the title host, leaving the popup item and full-screen root intact.
private struct MiniPlayerTitle: View {
    let track: ReferenceTrack
    let isActive: Bool
    @Environment(ReferencePlayerState.self) private var player
    @Environment(\.popupBarPlacement) private var placement
    @ScaledMetric(relativeTo: .footnote) private var titleSize = 13.0
    @ScaledMetric(relativeTo: .caption) private var artistSize = 12.0
    @ScaledMetric(relativeTo: .footnote) private var compactHeight = 18.0
    @ScaledMetric(relativeTo: .footnote) private var regularHeight = 36.0

    var body: some View {
        let compact = placement == .inline
        ReferenceMiniPlayerTitlePager(height: compact ? compactHeight : regularHeight, song: track,
            currentIndex: player.currentQueueIndex, previous: player.previousInOrder,
            next: player.nextInOrder, select: player.skip(toQueueIndex:)) { song, interactive in
                VStack(alignment: .leading, spacing: 2) {
                    NowPlayingMarqueeText(text: song.title, isActive: isActive && interactive && !compact)
                        .font(.system(size: titleSize, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(song.artists)
                        .font(.system(size: artistSize))
                        .foregroundStyle(.primary)
                        .frame(height: compact ? 0 : nil)
                        .opacity(compact ? 0 : 1)
                        .accessibilityHidden(compact)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .frame(height: compact ? compactHeight : regularHeight)
            .clipped()
    }
}

/// One fixed-size toolbar item gives LN a single, stable title exclusion rect.
struct MiniPlayerControls: View {
    let isPlaying: Bool
    let isLoading: Bool
    let canPlayNext: Bool
    let togglePlayback: () -> Void
    let next: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.popupBarPlacement) private var placement
    @State private var nextTrigger = 0
    @State private var showsLoadingIndicator = false

    var body: some View {
        let compact = placement == .inline
        HStack(spacing: 0) {
            Button(action: togglePlayback) {
                ZStack {
                    NowPlayingPlayPauseIcon(isPlaying: isPlaying, reducesMotion: reducesMotion,
                                            cornerRadius: 2.2)
                        .frame(width: 14, height: 17)
                        .opacity(showsLoadingIndicator ? 0 : 1)
                        .scaleEffect(showsLoadingIndicator ? 0.6 : 1)
                    if showsLoadingIndicator {
                        ProgressView().allowsHitTesting(false).transition(.opacity)
                    }
                }
                .offset(x: compact ? 0 : 8)
                .frame(width: 44, height: 44)
                .task(id: isLoading) {
                    if isLoading {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                    }
                    withAnimation(reducesMotion ? nil : .smooth(duration: 0.2)) {
                        showsLoadingIndicator = isLoading
                    }
                }
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
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let travel = pan.translation(in: pan.view)
        return abs(travel.y) >= abs(travel.x)
    }
}
