#if DEBUG
// Shares the MeloX-derived lyric row appearance and geometry (GPL-3.0).
import SwiftUI

/// Exercises production lyric positioning with local, variable-height sample lines.
public struct NativeLyricsFocusPreview: View {
    public init() {}
    @State private var time = 160.0
    @State private var isInterfaceHidden = false
    private let lyrics = Self.sampleLyrics
    private var activeID: Int? { lyrics.activeLine(at: time) }

    public var body: some View {
        AppleMusicLocalLyricsView(lyrics: lyrics, activeID: activeID,
                                  bottomOverlayHeight: 0, isActive: true,
                                  isInterfaceHidden: $isInterfaceHidden, onSeek: { time = $0 })
            .padding(.horizontal, 32)
        .background(.black)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Text("第 \((activeID ?? 0) + 1) / 80 行")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("lyrics.focus.currentLine")
                Slider(value: $time, in: 0...316)
                    .accessibilityLabel("歌词预览进度")
                    .frame(minHeight: 44)
                HStack {
                    Button("开头") { time = 0 }
                    Spacer()
                    Button("中段") { time = 160 }
                    Spacer()
                    Button("结尾") { time = 316 }
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationTitle("歌词原生定位核验")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static let sampleLyrics: PlayerLyrics = {
        let lines = (0..<80).map { index in
            let text: String
            switch index % 4 {
            case 0: text = "第\(index + 1)行 · 让旋律慢慢展开"
            case 1: text = "第\(index + 1)行 · 风经过窗边\n留下这一刻的回声"
            case 2: text = "第\(index + 1)行 · 沿着熟悉的街道继续向前，看远处的光渐渐亮起"
            default: text = "第\(index + 1)行 · 把故事留给明天"
            }
            return PlayerLyricLine(id: index, time: Double(index * 4), text: text)
        }
        return PlayerLyrics(lines: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "本地定位示例")
    }()
}

#Preview("歌词 · 原生定位核验") {
    NativeLyricsFocusPreview()
}

/// Interactive preview demonstrating the 3-dot interlude indicator lifecycle
/// (row expansion, 1.2s entrance, 3-segment progress, 4.5s breathing, anticipation & collapse).
private struct LyricsInterludeIndicatorPreview: View {
    @State private var isPlaying = true
    @State private var anchor = PlayerTimelineAnchor(baseElapsed: 0, rate: 1, duration: 36)
    @State private var isInterfaceHidden = false
    @State private var activeID: Int?

    private static let sampleLyrics = PlayerLyrics(
        lines: [
            PlayerLyricLine(id: 0, time: 0.0, text: "混線足る致死量"),
            PlayerLyricLine(id: 1, time: 2.5, text: "迫るエンドロールの\n中で"),
            PlayerLyricLine(id: 2, time: 5.5, text: ""),
            PlayerLyricLine(id: 3, time: 20.5, text: "不幸自慢ばかり捩り\n拗れた"),
            PlayerLyricLine(id: 4, time: 24.5, text: "抗弁垂れた to eat\nご馳走"),
            PlayerLyricLine(id: 5, time: 28.5, text: "寧ろ 君のが針のモロ謡")
        ],
        plainText: "",
        source: "间奏示例"
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { _ in
            let headstart = anchor.rate > 0 ? AppleMusicLyricsMotionProfile.iOS26_6.animationHeadstart : 0
            let liveTime = anchor.elapsed()
            let nextID = Self.sampleLyrics.activeLine(at: liveTime + headstart)
            AppleMusicLocalLyricsView(
                lyrics: Self.sampleLyrics,
                activeID: activeID,
                bottomOverlayHeight: 120,
                isActive: true,
                isInterfaceHidden: $isInterfaceHidden,
                onSeek: { time in
                    anchor = PlayerTimelineAnchor(baseElapsed: time, rate: isPlaying ? 1 : 0, duration: 36)
                    activeID = Self.sampleLyrics.activeLine(at: time)
                },
                topOverlayHeight: 60,
                isPlaying: isPlaying,
                timelineAnchor: anchor
            )
            .padding(.horizontal, 32)
            .background(
                LinearGradient(
                    colors: [Color(white: 0.22), Color(white: 0.34), Color(white: 0.26)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .foregroundStyle(.white)
            .preferredColorScheme(.dark)
            .onChange(of: nextID, initial: true) { _, value in
                activeID = value
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 16) {
                    Button(isPlaying ? "暂停" : "播放") {
                        let current = anchor.elapsed()
                        isPlaying.toggle()
                        anchor = PlayerTimelineAnchor(baseElapsed: current, rate: isPlaying ? 1 : 0, duration: 36)
                    }
                    Button("重播间奏") {
                        isPlaying = true
                        anchor = PlayerTimelineAnchor(baseElapsed: 3.5, rate: 1, duration: 36)
                    }
                    Spacer()
                    Text(String(format: "%.1fs / 36.0s", liveTime))
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
    }
}

#Preview("歌词 · 三圆点间奏进度指示器") {
    LyricsInterludeIndicatorPreview()
}
#endif
