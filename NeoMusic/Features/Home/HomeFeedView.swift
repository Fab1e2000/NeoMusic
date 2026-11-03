import SwiftUI

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
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: HomeMetrics.sectionSpacing) {
                    ForEach(HomeFixtures.sections) { section in
                        HomeShelfView(section: section)
                    }
                }
                .padding(.top, 15)
                .padding(.bottom, 24)
            }
            .accessibilityIdentifier("home.feed")
            .background(.white)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle("主页")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar { AccountToolbar() }
            .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
            .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
            .toolbarMinimizationSafeAreaAdjustment(.disabled, for: .navigationBar)
        }
        .preferredColorScheme(.light)
    }
}

private struct HomeShelfView: View {
    let section: HomeSection

    var body: some View {
        VStack(alignment: .leading, spacing: HomeMetrics.headingSpacing) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.system(size: 20, weight: .bold))
                if section.id == "recent" {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.gray)
                }
            }
            .lineLimit(1)
            .frame(height: HomeMetrics.headingHeight, alignment: .leading)
            .padding(.horizontal, HomeMetrics.margin)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home.heading.\(section.id)")

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: HomeMetrics.cardSpacing) {
                    ForEach(section.items) { item in
                        Group {
                            if section.largeCards {
                                HomeHeroCard(item: item)
                            } else {
                                HomeAlbumCard(item: item)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(item.title)，\(item.subtitle)")
                        .accessibilityIdentifier("home.item.\(section.id).\(item.id)")
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .accessibilityIdentifier("home.shelf.\(section.id)")
        }
    }
}

private struct HomeAlbumCard: View {
    let item: HomeItem
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HomeArtwork(artwork: item.artwork)
                .frame(width: HomeMetrics.artworkSize, height: HomeMetrics.artworkSize)
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.black.opacity(0.10), lineWidth: 1 / displayScale)
                }
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).foregroundStyle(.black)
                    .frame(height: 16, alignment: .leading)
                Text(item.subtitle).foregroundStyle(Color(white: 0.50))
                    .frame(height: 16, alignment: .leading)
            }
            .font(.system(size: 13))
            .lineLimit(1)
        }
        .frame(width: HomeMetrics.artworkSize, alignment: .leading)
    }
}

private struct HomeHeroCard: View {
    let item: HomeItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            HomeArtwork(artwork: item.artwork)
            if case .image = item.artwork {
                LinearGradient(colors: [.clear, .black.opacity(0.08), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow = item.eyebrow {
                    Text(eyebrow).font(.system(size: 14))
                        .foregroundStyle(.white.opacity(item.id == "favorites" ? 1 : 0.7))
                }
                if item.id != "new-music" {
                    Text(item.title).font(.system(size: 15, weight: .bold))
                }
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.system(size: 14))
                        .lineLimit(item.id == "new-music" ? 3 : 2)
                }
            }
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: HomeMetrics.heroWidth, height: HomeMetrics.heroHeight)
        .clipShape(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 12)
    }
}
