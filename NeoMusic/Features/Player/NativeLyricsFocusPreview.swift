#if DEBUG
// Shares the MeloX-derived lyric row appearance and geometry (GPL-3.0).
import SwiftUI

/// Exercises production lyric positioning with local, variable-height sample lines.
struct NativeLyricsFocusPreview: View {
    @State private var time = 160.0
    @State private var isInterfaceHidden = false
    private let lyrics = Self.sampleLyrics
    private var activeID: Int? { lyrics.activeLine(at: time) }

    var body: some View {
        GeometryReader { geometry in
            let frame = CGRect(origin: .zero, size: geometry.size)
            AppleMusicLocalLyricsView(lyrics: lyrics, playerFrame: frame, activeID: activeID,
                                      bottomOverlayHeight: 0, isActive: true,
                                      isInterfaceHidden: $isInterfaceHidden, onSeek: { time = $0 },
                                      playerCoordinateSpace: .named("LyricsFocusPreviewPlayer"))
            .padding(.horizontal, 32)
        }
        .coordinateSpace(name: "LyricsFocusPreviewPlayer")
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

    private static let sampleLyrics: ReferenceLyrics = {
        let lines = (0..<80).map { index in
            let text: String
            switch index % 4 {
            case 0: text = "第\(index + 1)行 · 让旋律慢慢展开"
            case 1: text = "第\(index + 1)行 · 风经过窗边\n留下这一刻的回声"
            case 2: text = "第\(index + 1)行 · 沿着熟悉的街道继续向前，看远处的光渐渐亮起"
            default: text = "第\(index + 1)行 · 把故事留给明天"
            }
            return LyricsLine(id: index, time: Double(index * 4), text: text)
        }
        return ReferenceLyrics(lines: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "本地定位示例")
    }()
}

#Preview("歌词 · 原生定位核验") {
    NativeLyricsFocusPreview()
}
#endif
