#if DEBUG
import SwiftUI

struct FrontendPressFeedbackPreview: View {
    @State private var artworkSources = LibraryArtworkSources()
    @State private var originalPlayCount = 0
    @State private var nativePlayCount = 0
    @State private var originalSongSelected = false
    @State private var nativeSongSelected = false

    private static let homeItem = HomeQuickActionItem(
        action: .heartMode, artwork: .image(Image("AlbumSample17")),
        subtitle: "从喜欢的歌曲，听见更多心动。"
    )
    private static let song = LibrarySongItem(
        id: "press-preview:song", title: "NEW ROMANCER", artist: "RIM",
        album: "NEW ROMANCER", albumArtist: "RIM", trackNumber: 1,
        artwork: .image(Image("AlbumSample17"))
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    instructions
                        .padding(.horizontal, HomeMetrics.margin)
                    homeComparison
                    songComparison
                        .padding(.horizontal, HomeMetrics.margin)
                }
                .padding(.vertical, 20)
            }
            .background(Color(.systemBackground))
            .navigationTitle("按下反馈")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重置", systemImage: "arrow.counterclockwise", action: reset)
                        .disabled(originalPlayCount == 0 && nativePlayCount == 0 &&
                                  !originalSongSelected && !nativeSongSelected)
                        .accessibilityIdentifier("press-preview.reset")
                }
            }
            .accessibilityIdentifier("frontend.press-feedback")
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按住，再松开")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("原方案按住时保持原色；已接入的原生反馈会短暂改变明暗。两侧使用相同的尺寸、字体和内容。")
            Text("可以按住后移出控件再松开，体验取消。本页仅更新示例选择。")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var homeComparison: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("主页直接播放卡")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, HomeMetrics.margin)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: HomeMetrics.cardSpacing) {
                    VStack(alignment: .leading, spacing: 12) {
                        comparisonTitle("原方案", detail: "按住保持原色")
                        Button {
                            LibraryHaptics.impact()
                            originalPlayCount += 1
                        } label: {
                            HomeQuickActionCardLabel(item: Self.homeItem, state: .idle,
                                                     sources: artworkSources, sourceID: "press-preview.home.original")
                        }
                        .buttonStyle(OriginalPressFeedbackButtonStyle())
                        .accessibilityLabel(Self.homeItem.action.title)
                        .accessibilityValue(Self.homeItem.subtitle)
                        .accessibilityHint("选择本页播放示例")
                        .accessibilityIdentifier("press-preview.home.original")
                        selectionCount(originalPlayCount)
                            .accessibilityIdentifier("press-preview.home.original.result")
                    }
                    .frame(width: HomeMetrics.heroWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        comparisonTitle("原生反馈", detail: "已接入正式组件")
                        HomeQuickActionCard(item: Self.homeItem, state: .idle,
                                            sources: artworkSources, sourceID: "press-preview.home.native") {
                            nativePlayCount += 1
                        }
                        .accessibilityHint("选择本页播放示例")
                        .accessibilityIdentifier("press-preview.home.native")
                        selectionCount(nativePlayCount)
                            .accessibilityIdentifier("press-preview.home.native.result")
                    }
                    .frame(width: HomeMetrics.heroWidth, alignment: .leading)
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var songComparison: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("选歌行")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 8) {
                comparisonTitle("原方案", detail: "按住保持原色")
                Button {
                    originalSongSelected.toggle()
                } label: {
                    MusicPickerSongRowLabel(song: Self.song, selected: originalSongSelected)
                }
                .buttonStyle(OriginalPressFeedbackButtonStyle())
                .accessibilityLabel("\(Self.song.title)，\(Self.song.artist)")
                .accessibilityValue(originalSongSelected ? "已选择" : "未选择")
                .accessibilityHint(originalSongSelected ? "轻点取消选择" : "轻点添加")
                .accessibilityIdentifier("press-preview.song.original")
                songResult(originalSongSelected)
                    .accessibilityIdentifier("press-preview.song.original.result")
            }

            VStack(alignment: .leading, spacing: 8) {
                comparisonTitle("原生反馈", detail: "已接入正式组件")
                MusicPickerSongRow(song: Self.song, selected: nativeSongSelected, alreadyAdded: false) {
                    nativeSongSelected.toggle()
                }
                .accessibilityIdentifier("press-preview.song.native")
                songResult(nativeSongSelected)
                    .accessibilityIdentifier("press-preview.song.native.result")
            }
        }
    }

    private func comparisonTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func selectionCount(_ count: Int) -> some View {
        Text(count == 0 ? "尚未选择" : "已选择心动模式 · \(count) 次")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func songResult(_ selected: Bool) -> some View {
        Text(selected ? "已选择「\(Self.song.title)」" : "尚未选择")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func reset() {
        originalPlayCount = 0
        nativePlayCount = 0
        originalSongSelected = false
        nativeSongSelected = false
    }
}

private struct OriginalPressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

#Preview("按下反馈") {
    FrontendPressFeedbackPreview()
}

#Preview("按下反馈 · 深色") {
    FrontendPressFeedbackPreview().preferredColorScheme(.dark)
}
#endif
