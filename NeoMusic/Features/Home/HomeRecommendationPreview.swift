#if DEBUG
import SwiftUI

/// Isolated presentation data for approving the three real-content home shelves.
struct HomeRecommendationPreview: View {
    enum Mode: String { case signedIn, guest, error }
    let mode: Mode
    var onLogin: () -> Void = {}
    @State private var hasRetried = false
    @Environment(\.displayScale) private var displayScale
    private var showsError: Bool { mode == .error && !hasRetried }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HomeMetrics.sectionSpacing) {
                    shelf("专属精选推荐") {
                        hero("喜爱歌曲", subtitle: "收藏的旋律，随时重温。", eyebrow: "由你制作", artwork: .favorites)
                        if mode != .guest {
                            dailyCard
                        }
                    }
                    if mode == .guest {
                        HStack(spacing: 16) {
                            Text("登录，发现为你推荐的音乐")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("登录", action: onLogin).font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, HomeMetrics.margin)
                    }
                    shelf("最近播放") {
                        album("NEW ROMANCER", artist: "RIM", image: "AlbumSample17")
                        album("塌陷于 38°C 的蓝", artist: "46", image: "AlbumSample07")
                        album("我的流动", artist: "晴空乐队", image: "AlbumSample01")
                    }
                    if showsError {
                        VStack(alignment: .leading, spacing: HomeMetrics.headingSpacing) {
                            heading("推荐歌单")
                            HStack {
                                Text("暂时无法获取推荐歌单")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Button("重试") { hasRetried = true }
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, HomeMetrics.margin)
                        }
                    } else {
                        shelf("推荐歌单") {
                            hero("夜晚散步", subtitle: "让音乐陪你慢慢走。", eyebrow: mode == .guest ? "精选歌单" : "为你推荐", artwork: .image("AlbumSample07"))
                            hero("今日好心情", subtitle: "属于此刻的轻快旋律。", eyebrow: mode == .guest ? "精选歌单" : "为你推荐", artwork: .image("AlbumSample17"))
                        }
                    }
                }
                .padding(.top, 15)
                .padding(.bottom, 24)
            }
            .background(.white)
            .navigationTitle("主页")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { AccountToolbar() }
            .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
            .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
            .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
        }
        .environment(\.colorScheme, .light)
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.system(size: 20, weight: .bold))
            .lineLimit(1)
            .frame(height: HomeMetrics.headingHeight, alignment: .leading)
            .padding(.horizontal, HomeMetrics.margin)
            .accessibilityAddTraits(.isHeader)
    }

    private func shelf<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HomeMetrics.headingSpacing) {
            heading(title)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: HomeMetrics.cardSpacing, content: content)
                    .scrollTargetLayout()
            }
            .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var dailyCard: some View {
        ZStack(alignment: .bottomLeading) {
            // The existing new-music mesh composition, with recommendation wording.
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.7, 0.38], [1, 0.5], [0, 1], [0.5, 1], [1, 1]
            ], colors: [
                Color(red: 1, green: 0.02, blue: 0.12), .pink, Color(red: 1, green: 0.18, blue: 0.25),
                .red, Color(red: 1, green: 0.63, blue: 0.69), Color(red: 1, green: 0.19, blue: 0.35),
                Color(red: 1, green: 0.47, blue: 0.49), Color(red: 1, green: 0.63, blue: 0.69), Color(red: 1, green: 0.38, blue: 0.51)
            ])
            .overlay { Text("每日推荐").font(.system(size: 44, weight: .bold)).foregroundStyle(.white) }
            VStack(alignment: .leading, spacing: 2) {
                Text("为你推荐").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                Text("每天，遇见新的喜欢。")
                    .font(.system(size: 14)).foregroundStyle(.white)
            }.padding(16)
        }
        .frame(width: HomeMetrics.heroWidth, height: HomeMetrics.heroHeight)
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 12)
    }

    private func hero(_ title: String, subtitle: String, eyebrow: String, artwork: HomeArtworkSource) -> some View {
        ZStack(alignment: .bottomLeading) {
            HomeArtwork(artwork: artwork)
            if case .image = artwork {
                LinearGradient(colors: [.clear, .black.opacity(0.08), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow).font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
                Text(title).font(.system(size: 15, weight: .bold))
                Text(subtitle).font(.system(size: 14)).lineLimit(2)
            }.foregroundStyle(.white).padding(16)
        }
        .frame(width: HomeMetrics.heroWidth, height: HomeMetrics.heroHeight)
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 12)
    }

    private func album(_ title: String, artist: String, image: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeArtwork(artwork: .image(image))
                .frame(width: HomeMetrics.artworkSize, height: HomeMetrics.artworkSize)
                .clipShape(.rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.10), lineWidth: 1 / displayScale) }
            VStack(alignment: .leading, spacing: 0) {
                Text(title).foregroundStyle(.black).frame(height: 16, alignment: .leading)
                Text(artist).foregroundStyle(Color(white: 0.50)).frame(height: 16, alignment: .leading)
            }.font(.system(size: 13)).lineLimit(1)
        }.frame(width: HomeMetrics.artworkSize, alignment: .leading)
    }
}
#endif
