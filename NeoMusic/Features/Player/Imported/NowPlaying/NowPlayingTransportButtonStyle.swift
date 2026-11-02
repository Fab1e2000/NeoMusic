// Direct source port from MeloX (GPL-3.0), b8bc60f.
// NeoDizzy adapters are limited to track data, available playback features and localization.
import SwiftUI

struct NowPlayingTransportButtonStyle: ButtonStyle {
    let reducesMotion: Bool
    /// 松手时图标用带过冲的弹簧弹回（播放/暂停按钮用），否则平缓回到原大。
    var springsBack = false
    var diameter: CGFloat = 64
    var showsHighlight = true

    func makeBody(configuration: Configuration) -> some View {
        NowPlayingTransportButtonStyleBody(
            label: configuration.label,
            isPressed: configuration.isPressed,
            reducesMotion: reducesMotion,
            springsBack: springsBack,
            diameter: diameter,
            showsHighlight: showsHighlight
        )
    }
}

private struct NowPlayingTransportButtonStyleBody<Label: View>: View {
    let label: Label
    let isPressed: Bool
    let reducesMotion: Bool
    let springsBack: Bool
    let diameter: CGFloat
    let showsHighlight: Bool

    @State private var iconScale: CGFloat = 1
    @State private var highlightScale =
        NowPlayingTransportButtonAnimation.pressedHighlightScale
    @State private var highlightOpacity = 0.0

    var body: some View {
        ZStack {
            if showsHighlight {
                Circle()
                .fill(
                    .white.opacity(
                        NowPlayingTransportButtonAnimation.highlightOpacity
                    )
                )
                .frame(
                    width: diameter,
                    height: diameter
                )
                .scaleEffect(highlightScale)
                .opacity(highlightOpacity)
            }

            label
                .scaleEffect(iconScale)
        }
        .frame(
            width: diameter,
            height: diameter
        )
        .contentShape(.circle)
        .onAppear {
            updatePressedState(isPressed, animated: false)
        }
        .onChange(of: isPressed) { _, isPressed in
            updatePressedState(isPressed, animated: true)
        }
    }

    private func updatePressedState(
        _ isPressed: Bool,
        animated: Bool
    ) {
        guard animated, !reducesMotion else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                iconScale =
                    isPressed && !reducesMotion
                        ? NowPlayingTransportButtonAnimation.pressedIconScale
                        : 1
                highlightScale =
                    isPressed
                        ? NowPlayingTransportButtonAnimation
                            .pressedHighlightScale
                        : 1
                highlightOpacity = isPressed ? 1 : 0
            }
            return
        }

        if isPressed {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                highlightScale =
                    NowPlayingTransportButtonAnimation
                    .pressedHighlightScale
            }

            withAnimation(
                .easeInOut(
                    duration: NowPlayingTransportButtonAnimation.pressDuration
                )
            ) {
                iconScale =
                    NowPlayingTransportButtonAnimation.pressedIconScale
                highlightOpacity = 1
            }
        } else {
            withAnimation(
                springsBack
                    ? .spring(duration: 0.45, bounce: 0.5)
                    : .easeInOut(
                        duration: NowPlayingTransportButtonAnimation.releaseDuration
                    )
            ) {
                iconScale = 1
            }
            withAnimation(
                .easeOut(
                    duration: NowPlayingTransportButtonAnimation
                        .highlightExpansionDuration
                )
            ) {
                highlightScale = 1
            }
            withAnimation(
                .easeIn(
                    duration: NowPlayingTransportButtonAnimation.releaseDuration
                )
            ) {
                highlightOpacity = 0
            }
        }
    }
}

private enum NowPlayingTransportButtonAnimation {
    static let pressedIconScale: CGFloat = 0.8
    static let pressedHighlightScale: CGFloat = 0.86
    static let highlightOpacity = 0.1
    static let pressDuration: TimeInterval = 0.16
    static let releaseDuration: TimeInterval = 0.4
    static let highlightExpansionDuration: TimeInterval = 0.18
}
