import SwiftUI
import UIKit

enum HomeMetrics {
    static let margin: CGFloat = 20
    static let cardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 32
    static let headingHeight: CGFloat = 24
    static let headingSpacing: CGFloat = 14
    static let artworkSize: CGFloat = 161
    static let heroWidth: CGFloat = 248
    static let heroHeight: CGFloat = 330
}

struct HomeFeedView: View {
    let model: HomeContentModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HomeMetrics.sectionSpacing) {
                shelf("专属精选推荐", id: "featured", items: model.featured, large: true,
                      error: model.featuredError, retry: model.retryFeatured)
                if model.isGuest {
                    HStack(spacing: 16) {
                        Text("登录，发现为你推荐的音乐").font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("登录", action: model.login).font(.subheadline.weight(.semibold))
                    }.padding(.horizontal, HomeMetrics.margin)
                }
                if !model.recent.isEmpty {
                    shelf("最近播放", id: "recent", items: Array(model.recent.prefix(20)), large: false)
                }
                shelf("推荐歌单", id: "recommendations", items: model.recommendations, large: true,
                      error: model.recommendationsError, retry: model.retryRecommendations)
            }
            .padding(.top, 15)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("home.feed")
        .background(.white)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .libraryNavigationTitle("主页")
        .libraryHomeNavigation(title: "主页")
        .toolbar { AccountToolbar() }
        .environment(\.colorScheme, .light)
    }

    private func shelf(_ title: String, id: String, items: [HomeContentItem], large: Bool,
                       error: String? = nil, retry: @escaping () -> Void = {}) -> some View {
        VStack(alignment: .leading, spacing: HomeMetrics.headingSpacing) {
            Text(title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                .frame(height: HomeMetrics.headingHeight, alignment: .leading)
                .padding(.horizontal, HomeMetrics.margin)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.heading.\(id)")
            if !items.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: HomeMetrics.cardSpacing) {
                        ForEach(items) { item in HomeContentCard(item: item, large: large) }
                    }.scrollTargetLayout()
                }
                .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .accessibilityIdentifier("home.shelf.\(id)")
            }
            if let error {
                HStack {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试", action: retry).font(.subheadline.weight(.semibold))
                }.padding(.horizontal, HomeMetrics.margin)
            }
        }
    }
}

private struct HomeContentCard: View {
    let item: HomeContentItem
    let large: Bool
    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(\.displayScale) private var displayScale
    @State private var source = HomeCardSource()

    var body: some View {
        Button {
            openRoute(item.route, sourceProvider: { [weak source] in source?.view })
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HomeCardArtwork(content: AnyView(cover.frame(width: large ? HomeMetrics.heroWidth : HomeMetrics.artworkSize,
                                                           height: large ? HomeMetrics.heroHeight : HomeMetrics.artworkSize)), source: source)
                    .frame(width: large ? HomeMetrics.heroWidth : HomeMetrics.artworkSize,
                           height: large ? HomeMetrics.heroHeight : HomeMetrics.artworkSize)
                    .clipShape(.rect(cornerRadius: large ? 16 : 8))
                    .overlay { if !large { RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.10), lineWidth: 1 / displayScale) } }
                    .shadow(color: .black.opacity(large ? 0.18 : 0), radius: 16, x: 0, y: 12)
                if !large {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.title).foregroundStyle(.black).frame(height: 16, alignment: .leading)
                        Text(item.subtitle).foregroundStyle(Color(white: 0.50)).frame(height: 16, alignment: .leading)
                    }.font(.system(size: 13)).lineLimit(1)
                }
            }.frame(width: large ? HomeMetrics.heroWidth : HomeMetrics.artworkSize, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title)，\(item.subtitle)")
        .accessibilityIdentifier("home.item.\(item.id)")
    }

    private var cover: some View {
        ZStack(alignment: .bottomLeading) {
            switch item.style {
            case .favorites: HomeArtwork(artwork: .favorites)
            case .daily: HomeDailyArtwork()
            case .artwork:
                if large {
                    HomePlaylistArtwork(artwork: item.artwork)
                } else {
                    ArtworkView(artwork: item.artwork, cornerRadius: 0)
                        .environment(\.nativeArtworkSurfaceEnabled, false)
                }
            }
            if large {
                VStack(alignment: .leading, spacing: 4) {
                    if let eyebrow = item.eyebrow, !eyebrow.isEmpty {
                        Text(eyebrow)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    if item.style != .daily {
                        Text(item.title)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(2)
                    }
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.leading)
                .foregroundStyle(.white)
                .frame(width: HomeMetrics.heroWidth - 32, alignment: .leading)
                .padding(16)
            }
        }
    }
}

@MainActor private final class HomeCardSource { weak var view: UIView? }

private struct HomeCardArtwork: UIViewRepresentable {
    let content: AnyView
    let source: HomeCardSource
    func makeUIView(context: Context) -> LibraryArtworkSurfaceView {
        let view = LibraryArtworkSurfaceView()
        view.isUserInteractionEnabled = false
        source.view = view
        return view
    }
    func updateUIView(_ view: LibraryArtworkSurfaceView, context: Context) {
        let configuration = UIHostingConfiguration { content }.margins(.all, 0)
        if let hosted = view.subviews.first as? any UIContentView {
            hosted.configuration = configuration
        } else {
            let hosted = configuration.makeContentView()
            hosted.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(hosted)
            NSLayoutConstraint.activate([
                hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor), hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hosted.topAnchor.constraint(equalTo: view.topAnchor), hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }
    }
}
