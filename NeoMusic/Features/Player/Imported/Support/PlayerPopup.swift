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

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(ReferencePlayerState.self) private var player
    @AppStorage(ImmersiveMode.storageKey) private var isImmersive = false
    @State private var isBarPresented = false
    @State private var artwork: UIImage?
    @State private var compactControls = false
    @State private var interactionDelegate = PlayerPopupInteractionDelegate()

    private var shouldShowBar: Bool { player.currentTrack != nil && !isSuppressed }
    private var prefetchURLs: [URL] { isPresented || player.isPlaying ? player.adjacentArtworkURLs : [] }

    func body(content: Content) -> some View {
        content
            .popup(isBarPresented: $isBarPresented, isPopupOpen: $isPresented, onClose: onClose) {
                PlayerPopupContent(barImage: barImage, compact: compactControls) { isPresented = false }
                    .statusBarHidden(isImmersive)
            }
            .popupBarStyle(.floatingCompact)
            // Keep the bar's inherited appearance and dynamic colors so its glass
            // and content can adapt together to the page underneath.
            .popupContentViewCustomizer { view in
                view.overrideUserInterfaceStyle = .dark
                view.popupInteractionGestureRecognizer.delegate = interactionDelegate
            }
            .popupInteractionStyle(.automatic)
            .popupCloseButtonStyle(.none)
            .popupBarMarqueeScrollEnabled(!compactControls)
            .onPopupBarGeometryChange(for: Bool.self, of: { proxy in
                MiniPlayerLayout.usesCompactControls(width: proxy.effectiveBarContentSize.width)
            }) { compact in
                // LNPopup can report geometry inside updateUIViewController. Publish
                // after that update returns, preserving the order of layout changes.
                DispatchQueue.main.async { compactControls = compact }
            }
            .onChange(of: shouldShowBar, initial: true) { _, visible in
                if !visible { isPresented = false }
                isBarPresented = visible
            }
            .task(id: player.currentTrack?.coverURL) {
                guard let url = player.currentTrack?.coverURL else { artwork = nil; return }
                var request = ImageRequest(url: url)
                request.thumbnail = .init(size: CGSize(width: 160, height: 160), unit: .pixels,
                                          contentMode: .aspectFill)
                let image = try? await ImagePipeline.shared.image(for: request)
                guard !Task.isCancelled else { return }
                artwork = image
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
            if let artwork {
                NowPlayingBackdropImage(image: artwork, animated: !reducesMotion)
            } else {
                Color.clear
            }
        }
    }

}

private struct PlayerPopupContent: View {
    let barImage: PopupItemViewImage
    let compact: Bool
    let onDismiss: () -> Void
    @Environment(ReferencePlayerState.self) private var player
    @Environment(\.popupBarPlacement) private var placement

    var body: some View {
        let isCompact = compact || placement == .inline
        Group {
            if let track = player.currentTrack {
                ReferenceNowPlayingView(onDismiss: onDismiss)
                    .popupItem {
                        PopupItem(id: track.id, image: barImage, title: {
                            ReferenceMiniPlayerTitlePager(height: isCompact ? 18 : 36, song: track, currentIndex: player.currentQueueIndex,
                                                 previous: player.previousInOrder, next: player.nextInOrder,
                                                 select: player.skip(toQueueIndex:)) { song, interactive in
                                VStack(alignment: .leading, spacing: 2) {
                                    NowPlayingMarqueeText(text: song.title, isActive: interactive && !isCompact)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                    if !isCompact {
                                        Text(song.artists)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                            }
                            .frame(height: isCompact ? 18 : 36)
                            .clipped()
                            .environment(player)
                            .accessibilityIdentifier("mini.trackTitle")
                        }, buttons: {
                            ToolbarItem(placement: .popupBar) {
                                MiniPlayerControls(isPlaying: player.isPlaying, isLoading: player.isLoading,
                                                   canPlayNext: player.canPlayNext, compact: isCompact,
                                                   togglePlayback: player.togglePlayback, next: player.next)
                            }
                        })
                    }
            }
        }
    }
}

/// One fixed-size toolbar item gives LN a single, stable title exclusion rect.
struct MiniPlayerControls: View {
    let isPlaying: Bool
    let isLoading: Bool
    let canPlayNext: Bool
    let compact: Bool
    let togglePlayback: () -> Void
    let next: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @State private var nextTrigger = 0
    @State private var showsLoadingIndicator = false

    var body: some View {
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
            if !compact {
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
            }
        }
        .tint(.primary)
        .foregroundStyle(.primary)
        .fixedSize()
    }
}

nonisolated enum MiniPlayerLayout {
    static func usesCompactControls(width: CGFloat) -> Bool { width > 0 && width < 300 }
}

@MainActor final class PlayerPopupInteractionDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let travel = pan.translation(in: pan.view)
        return abs(travel.y) >= abs(travel.x)
    }
}
