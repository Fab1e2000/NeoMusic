import SwiftUI

public struct NowPlayingPlayPauseIcon: View {
    let isPlaying: Bool
    let reducesMotion: Bool
    var playOffsetX: CGFloat = 1.8

    public init(isPlaying: Bool, reducesMotion: Bool, playOffsetX: CGFloat = 1.8) {
        self.isPlaying = isPlaying; self.reducesMotion = reducesMotion; self.playOffsetX = playOffsetX
    }

    public var body: some View {
        ZStack {
            if isPlaying {
                Image(systemName: "pause.fill")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .transition(morphTransition)
            } else {
                Image(systemName: "play.fill")
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(0.99)
                    .offset(x: playOffsetX)
                    .transition(morphTransition)
            }
        }
        .animation(reducesMotion ? nil : .spring(duration: 0.50, bounce: 0.36), value: isPlaying)
    }

    private var morphTransition: AnyTransition {
        if reducesMotion {
            return .opacity
        }
        return AnyTransition(NowPlayingPlayPauseTransition())
    }
}

private struct NowPlayingPlayPauseTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        let isDisappearing = phase == .didDisappear
        let scale: CGFloat = switch phase {
        case .willAppear: 0.14
        case .identity: 1.0
        case .didDisappear: 0.10
        }
        content
            .scaleEffect(scale)
            .animation(
                isDisappearing
                    ? .easeInOut(duration: 0.15)
                    : .spring(duration: 0.50, bounce: 0.36),
                value: phase
            )
            .opacity(phase == .identity ? 1 : 0)
            .animation(
                isDisappearing
                    ? .linear(duration: 0.13)
                    : .easeOut(duration: 0.19),
                value: phase
            )
    }
}

struct NowPlayingPlayGlyph: View {
    let cornerRadius: CGFloat
    var verticalInset: CGFloat = 0.05

    var body: some View {
        let shape = NowPlayingPlayShape(inset: cornerRadius, verticalInset: verticalInset)
        ZStack {
            shape.fill()
            shape.stroke(style: StrokeStyle(lineWidth: cornerRadius * 2, lineJoin: .round))
        }
        .compositingGroup()
    }
}

private struct NowPlayingPlayShape: Shape {
    let inset: CGFloat
    let verticalInset: CGFloat

    func path(in bounds: CGRect) -> Path {
        let vertical = bounds.height * verticalInset
        let rect = bounds.insetBy(dx: inset, dy: inset + vertical)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
