// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import SwiftUI

struct NowPlayingBottomControls: View {
    static let utilityHeight: CGFloat = 62
    static let coreHeight: CGFloat = 279
    static let overlayHeight = utilityHeight + coreHeight

    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion

    @Environment(\.nowPlayingLayout) private var layout

    let song: ReferenceTrack
    @Binding var page: NowPlayingPage
    let hasLyrics: Bool
    let showsLyricsUtilities: Bool
    let hasLyricsTranslations: Bool
    let hasLyricsRomanizations: Bool
    let isInterfaceHidden: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                interfaceLayer(.progress) {
                    NowPlayingProgressControl(song: song)
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(587))

                interfaceLayer(.transport) {
                    NowPlayingTransportControls()
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(664))

                interfaceLayer(.volume) {
                    NowPlayingVolumeControl()
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(756.5))

                interfaceLayer(.pageSelector) {
                    NowPlayingPageSelector(page: $page, hasLyrics: hasLyrics)
                }
                .position(x: proxy.size.width / 2, y: layout.controlsY(811.23))
            }
        }
        .frame(height: Self.overlayHeight)
    }

    private func interfaceLayer<Content: View>(
        _ layer: NowPlayingInterfaceTransition.ControlLayer,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .offset(
                y: isInterfaceHidden
                    ? NowPlayingInterfaceTransition.hiddenOffset(
                        for: layer
                    )
                    : 0
            )
            .opacity(isInterfaceHidden ? 0 : 1)
            .animation(
                NowPlayingInterfaceTransition.controlAnimation(
                    for: layer,
                    isVisible: !isInterfaceHidden,
                    reducesMotion: accessibilityReduceMotion
                ),
                value: isInterfaceHidden
            )
    }
}

