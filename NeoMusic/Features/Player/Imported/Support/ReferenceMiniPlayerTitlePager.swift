// Source: NeoDizzy Features/Player/MiniPlayerTitlePager.swift; see Resources/PlayerSourceNotices.txt.
import SwiftUI

/// 迷你条标题区复用与全屏播放页一致的滑动切歌交互、同歌手固定与阈值触感反馈；
/// 封面与播放控制按钮保持原地不动。
struct ReferenceMiniPlayerTitlePager<Title: View, Artist: View>: View {
    var height: CGFloat = 36
    let song: ReferenceTrack
    @ViewBuilder let title: (_ track: ReferenceTrack, _ marqueeActive: Bool) -> Title
    @ViewBuilder let artist: (_ track: ReferenceTrack, _ interactive: Bool) -> Artist

    var body: some View {
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
}
