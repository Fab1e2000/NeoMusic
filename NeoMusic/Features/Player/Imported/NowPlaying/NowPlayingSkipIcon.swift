import SwiftUI

struct NowPlayingSkipIcon: View {
    enum Direction { case forward, backward }
    let direction: Direction
    let trigger: Int
    let reducesMotion: Bool

    var body: some View {
        if reducesMotion { symbol }
        else { symbol.symbolEffect(.bounce, options: .nonRepeating, value: trigger) }
    }

    private var symbol: some View {
        Image(systemName: direction == .forward ? "forward.fill" : "backward.fill")
            .resizable()
            .scaledToFit()
    }
}
