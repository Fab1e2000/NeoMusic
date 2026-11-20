import SwiftUI

struct NowPlayingPageSelector: View {
    @Environment(\.accessibilityReduceMotion)
    private var accessibilityReduceMotion
    @Environment(PlayerState.self) private var player

    @Environment(\.nowPlayingLayout) private var layout

    let page: NowPlayingPage
    let onPageTap: (NowPlayingPage) -> Void
    let hasLyrics: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // A selected lyrics page remains dismissible while the next track loads.
                pageButton(page: .lyrics, systemImage: "quote.bubble", accessibilityLabel: "歌词")
                    .disabled(!hasLyrics && page != .lyrics)
                    .opacity(hasLyrics || page == .lyrics ? 1 : 0.32)
                    .position(x: layout.x(87), y: 25)
                ReferenceAirPlayButton(opacity: NowPlayingVisualHierarchy.airPlayOpacity)
                    .frame(width: 44, height: 44)
                    .position(x: proxy.size.width / 2, y: 25)
                pageButton(page: .queue, systemImage: "list.bullet", accessibilityLabel: "继续播放",
                           badgeSystemImage: page == .queue ? nil : player.queueModeBadgeSystemImage)
                    .position(x: layout.x(315), y: 25)
            }
        }
        .frame(height: 50)
        .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.25), value: hasLyrics)
    }

    private func pageButton(
        page destination: NowPlayingPage,
        systemImage: String,
        accessibilityLabel: String,
        badgeSystemImage: String? = nil
    ) -> some View {
        let isSelected = page == destination

        return Button {
            onPageTap(destination)
        } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if isSelected {
                        ZStack {
                            Circle()
                                .fill(.white.opacity(NowPlayingVisualHierarchy.bottomButtonSelectedFillOpacity))
                                .frame(width: 38, height: 38)
                            Image(systemName: systemImage)
                                .resizable()
                                .symbolVariant(.fill)
                                .fontWeight(.medium)
                                .scaledToFit()
                                .frame(width: destination == .queue ? 20 : 21,
                                       height: destination == .queue ? 15 : 21.5)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                        .blendMode(.plusLighter)
                        .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: systemImage)
                            .resizable()
                            .symbolVariant(.none)
                            .fontWeight(.medium)
                            .scaledToFit()
                            .frame(width: destination == .queue ? 20 : 21,
                                   height: destination == .queue ? 15 : 21.5)
                            .frame(width: 44, height: 44)
                            .nowPlayingPlusLighter(NowPlayingVisualHierarchy.bottomButtonUnselectedOpacity)
                    }
                }
                .offset(y: isSelected && destination == .lyrics ? 1 : 0)

                if let badgeSystemImage {
                    Image(systemName: badgeSystemImage)
                        .font(.system(size: 9, weight: .bold))
                        .nowPlayingPlusLighter(0.85)
                        .frame(width: 17, height: 17)
                        .background {
                            Circle()
                                .fill(.white.opacity(NowPlayingVisualHierarchy.repeatBadgeOpacity))
                                .blendMode(.plusLighter)
                        }
                        .offset(x: 1, y: 1)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .animation(accessibilityReduceMotion ? nil : .easeOut(duration: 0.1), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
