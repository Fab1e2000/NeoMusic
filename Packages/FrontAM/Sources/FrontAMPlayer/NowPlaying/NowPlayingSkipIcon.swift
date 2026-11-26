import SwiftUI

public struct NowPlayingSkipIcon: View {
    public enum Direction {
        case forward
        case backward
    }

    let direction: Direction
    let trigger: Int
    let reducesMotion: Bool
    var cornerRadius: CGFloat = 2.5

    @State private var progress: CGFloat = 0

    public var body: some View {
        NowPlayingSkipTriangles(progress: progress, cornerRadius: cornerRadius)
            .scaleEffect(x: direction == .forward ? 1 : -1)
            .onChange(of: trigger) {
                guard !reducesMotion else { return }
                withAnimation(.smooth(duration: 0.42)) {
                    progress += 1
                }
            }
    }
    public init(direction: Direction, trigger: Int, reducesMotion: Bool, cornerRadius: CGFloat = 2.5) {
        self.direction = direction; self.trigger = trigger; self.reducesMotion = reducesMotion; self.cornerRadius = cornerRadius
    }

}

nonisolated private struct NowPlayingSkipTriangles: View, Animatable {
    var progress: CGFloat
    let cornerRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width / 2
            let height = proxy.size.height
            let phase = progress - progress.rounded(.down)
            ZStack(alignment: .leading) {
                ForEach(-1...1, id: \.self) { index in
                    let position = CGFloat(index) + phase
                    NowPlayingPlayGlyph(cornerRadius: cornerRadius, verticalInset: 0.08)
                        .frame(width: width, height: height)
                        .scaleEffect(Self.visibility(at: position))
                        .opacity(Self.visibility(at: position))
                        .offset(x: position * width)
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .leading)
            .transaction { $0.animation = nil }
        }
    }

    private static func visibility(at position: CGFloat) -> CGFloat {
        if position < 0 { return max(0, 1 + position) }
        if position > 1 { return max(0, 2 - position) }
        return 1
    }
}
