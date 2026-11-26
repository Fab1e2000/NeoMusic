// Source: NeoDizzy Features/Player/MiniPlayerTitlePager.swift; see Resources/PlayerSourceNotices.txt.
import SwiftUI

public struct ReferenceMiniPlayerTitlePager<Title: View, Artist: View>: View {
    var height: CGFloat = 36
    let song: PlayerTrack
    @ViewBuilder let title: (_ track: PlayerTrack, _ marqueeActive: Bool) -> Title
    @ViewBuilder let artist: (_ track: PlayerTrack, _ interactive: Bool) -> Artist

    public var body: some View {
        NowPlayingTrackSwipe(
            song: song,
            slotHeight: height,
            rowSpacing: 2,
            viewportInsets: .miniPlayer,
            usesUIKitTouchSurface: true,
            title: title,
            artist: artist
        )
    }
    public init(height: CGFloat = 36, song: PlayerTrack,
                @ViewBuilder title: @escaping (PlayerTrack, Bool) -> Title,
                @ViewBuilder artist: @escaping (PlayerTrack, Bool) -> Artist) {
        self.height = height; self.song = song; self.title = title; self.artist = artist
    }

}
