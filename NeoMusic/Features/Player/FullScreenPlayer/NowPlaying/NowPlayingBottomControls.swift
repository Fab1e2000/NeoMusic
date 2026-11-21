// Direct source port from MeloX (GPL-3.0), b8bc60f.
import SwiftUI

struct NowPlayingBottomControls: View {
    nonisolated static let utilityHeight: CGFloat = 62
    nonisolated static let coreHeight: CGFloat = 279
    nonisolated static let overlayHeight = utilityHeight + coreHeight

    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion

    @Environment(\.nowPlayingLayout) private var layout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let song: PlayerTrack
    let page: NowPlayingPage
    let onPageTap: (NowPlayingPage) -> Void
    let hasLyrics: Bool
    let showsLyricsUtilities: Bool
    let hasLyricsTranslations: Bool
    let hasLyricsRomanizations: Bool
    let isInterfaceHidden: Bool

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 12) {
                interfaceLayer(.progress) {
                    NowPlayingProgressControl(song: song)
                }
                interfaceLayer(.transport) {
                    NowPlayingTransportControls()
                }
                .frame(height: 82)
                interfaceLayer(.volume) {
                    NowPlayingVolumeControl(isInterfaceHidden: isInterfaceHidden)
                }
                .frame(height: 52)
                interfaceLayer(.pageSelector) {
                    NowPlayingPageSelector(page: page, onPageTap: onPageTap, hasLyrics: hasLyrics)
                }
                .frame(height: 62)
            }
            .padding(.top, max(0, layout.controlsY(571) - 26))
            .fixedSize(horizontal: false, vertical: true)
        } else {
            referenceLayout
        }
    }

    private var referenceLayout: some View {
        GeometryReader { proxy in
            ZStack {
                interfaceLayer(.progress) {
                    NowPlayingProgressControl(song: song)
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(571))

                interfaceLayer(.transport) {
                    NowPlayingTransportControls()
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(652.5))

                interfaceLayer(.volume) {
                    NowPlayingVolumeControl(isInterfaceHidden: isInterfaceHidden)
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(744.5))

                interfaceLayer(.pageSelector) {
                    NowPlayingPageSelector(page: page, onPageTap: onPageTap, hasLyrics: hasLyrics)
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(796))
            }
        }
        .frame(height: Self.overlayHeight)
    }

    private func interfaceLayer<Content: View>(
        _ layer: NowPlayingInterfaceTransition.ControlLayer,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .animation(
                NowPlayingInterfaceTransition.controlAnimation(
                    for: layer,
                    isVisible: !isInterfaceHidden,
                    reducesMotion: accessibilityReduceMotion
                )
            ) {
                $0.offset(
                    y: isInterfaceHidden
                        ? NowPlayingInterfaceTransition.hiddenOffset(for: layer)
                            * layout.verticalScale
                        : 0
                )
            }
            .animation(
                NowPlayingInterfaceTransition.controlOpacityAnimation(
                    isVisible: !isInterfaceHidden,
                    reducesMotion: accessibilityReduceMotion
                )
            ) {
                $0.opacity(layer == .volume || !isInterfaceHidden ? 1 : 0)
            }
    }
}

