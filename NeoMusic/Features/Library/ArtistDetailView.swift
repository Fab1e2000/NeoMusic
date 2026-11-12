import SwiftUI

@MainActor func artistPreview(_ artist: LibraryArtistItem) -> LibraryNavigationPreview {
    .init(route: .artist(artist.id), ownerID: nil, title: artist.name, artwork: artist.artwork ?? .missing)
}

enum ArtistSection: String, Hashable { case songs, albums, singles, similar
    var title: String { switch self { case .songs: "歌曲排行"; case .albums: "专辑"; case .singles: "单曲与 EP"; case .similar: "类似艺人" } }
}
struct ArtistDetail {
    let name: String
    var artwork: Artwork?
    var isFavorite = false
    let albums: [LibraryShelfItem]
    var id = ""
    var biography = ""
    var songs: [LibrarySongItem] = []
    var singles: [LibraryShelfItem] = []
    var similar: [LibraryArtistItem] = []
    var latest: LibraryShelfItem?
    var latestCaption: String?
    var shareURL: URL?
    var errors: [String: String] = [:]
}

struct ArtistDetailView: View {
    let detail: ArtistDetail
    var playSong: ((LibrarySongItem) -> Void)?
    var toggleFavorite: (() -> Void)?
    var collectRelease: ((LibraryShelfItem) -> Void)?
    var retry: ((String) -> Void)?
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.libraryNavigationChrome) private var chrome
    @Environment(\.libraryNavigationPreview) private var navigationPreview
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .largeTitle) private var nameSize = 34.0
    @ScaledMetric(relativeTo: .subheadline) private var captionSize = 14.0
    @ScaledMetric(relativeTo: .callout) private var releaseTitleSize = 16.0
    @ScaledMetric(relativeTo: .title3) private var headingSize = 20.0
    @State private var biography = false
    @State private var releaseFeedback = 0
    private var identity: String { detail.id.isEmpty ? detail.name : detail.id }
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 398)
                    Text(detail.name).font(.system(size: nameSize, weight: .bold))
                        .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, -43)
                    HStack(spacing: 24) {
                        Button { biography = true } label: { Image(systemName: "info").font(.system(size: 22, weight: .semibold)).frame(width: 48, height: 48).background(.white.opacity(0.1), in: Circle()) }.disabled(detail.biography.isEmpty).accessibilityLabel("艺人简介")
                        Button { if let first = detail.songs.first, let playSong { playSong(first) } else { actions.play(.artist(identity), false) } } label: { Image(systemName: "play.fill").font(.system(size: 36)).foregroundStyle(Color(white: 0.49)).frame(width: 72, height: 72).background(.white, in: Circle()) }.accessibilityLabel("播放")
                        Button(action: favorite) { Image(systemName: detail.isFavorite ? "star.fill" : "star").font(.system(size: 20)).frame(width: 48, height: 48).background(.white.opacity(0.1), in: Circle()) }.accessibilityLabel(detail.isFavorite ? "取消喜爱" : "喜爱")
                    }.buttonStyle(.plain).padding(.top, 34.0 / 3)
                }
                if let latest = detail.latest {
                    let layout = textSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        CollectionCardLink(item: latest) { ArtworkView(artwork: latest.artwork).frame(width: 96, height: 96) }
                        CollectionCardLink(item: latest) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let caption = detail.latestCaption { Text(caption).font(.system(size: captionSize)) }
                                Text(latest.title).font(.system(size: releaseTitleSize, weight: .semibold))
                                    .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                                if let subtitle = latest.subtitle {
                                    Text(subtitle).font(.system(size: captionSize))
                                        .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if latest.isFavorite, let route = latest.route {
                            CollectionDownloadButton(route: route, songs: [], compact: true)
                        } else if let collectRelease {
                            Button {
                                releaseFeedback &+= 1
                                collectRelease(latest)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 20, weight: .semibold))
                                    .frame(width: 32, height: 32)
                                    .background(.white.opacity(0.2), in: Circle())
                                    .frame(width: 44, height: 44)
                                    .contentShape(.rect)
                            }
                            .accessibilityLabel("将\(latest.title)加入资料库")
                        }
                    }.padding(12).padding(.trailing, 8).background(.white.opacity(0.13), in: .rect(cornerRadius: 26)).overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.17), lineWidth: 0.7)).padding(.horizontal, 20).padding(.top, 24)
                        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: releaseFeedback)
                }
                if !detail.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        heading(.songs)
                        ForEach(detail.songs.prefix(5)) { song in ArtistSongRow(song: song, songs: detail.songs, source: detail.name, dark: true, playSong: playSong) }
                    }.padding(.horizontal, 20).padding(.top, 24)
                }
                ForEach(detail.errors.keys.sorted(), id: \.self) { key in
                    VStack(spacing: 8) {
                        Text(detail.errors[key] ?? "").font(.footnote)
                        if let retry { Button("重试") { retry(key) } }
                    }.padding(.horizontal, 20).padding(.top, 16)
                }
                shelf(.albums, items: detail.albums)
                shelf(.singles, items: detail.singles)
                if !detail.similar.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(.similar).padding(.horizontal, 20)
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(detail.similar) { artist in
                                    LibraryRouteLink(value: .artist(artist.id), preview: artistPreview(artist)) {
                                        VStack {
                                            ArtistAvatar(artwork: artist.artwork).frame(width: 120, height: 120)
                                            Text(artist.name).font(.system(size: captionSize))
                                                .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                                        }.frame(width: 120)
                                    }
                                }
                            }.scrollTargetLayout()
                        }.fixedSize(horizontal: false, vertical: true)
                            .contentMargins(.horizontal, 20).scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
                    }.padding(.top, 24)
                }
            }.padding(.bottom, 24).background { ArtistDetailBackdrop(artwork: detail.artwork, preview: matchingPreview?.artwork) }
        }
        .modifier(ArtistPageShade())
        .ignoresSafeArea(edges: .top).scrollEdgeEffectHidden(true, for: .top).foregroundStyle(.white)
        .toolbarColorScheme(.dark, for: .navigationBar, .tabBar)
        .libraryTitleDisplayMode(.inline)
        .onAppear { chrome?.setColorScheme(.dark) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let url = detail.shareURL { ShareLink(item: url) { Image(systemName: "square.and.arrow.up").foregroundStyle(.white) } }
                Menu { Button(detail.isFavorite ? "取消喜爱" : "喜爱", systemImage: detail.isFavorite ? "star.fill" : "star", action: favorite) } label: { Image(systemName: "ellipsis").foregroundStyle(.white) }
            }
        }
        .sheet(isPresented: $biography) {
            NavigationStack { ScrollView { Text(detail.biography).frame(maxWidth: .infinity, alignment: .leading).padding(20) }.navigationTitle(detail.name).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { biography = false } } } }.presentationDetents([.large])
        }
    }
    private var matchingPreview: LibraryNavigationPreview? {
        guard let navigationPreview, navigationPreview.route == .artist(identity) else { return nil }
        return navigationPreview
    }
    private func favorite() {
        LibraryHaptics.impact()
        if let toggleFavorite {
            toggleFavorite()
        } else {
            actions.toggleFavorite(.artist(identity))
            actions.notify(detail.isFavorite ? .unfavorited : .favorited)
        }
    }
    private func heading(_ section: ArtistSection) -> some View {
        LibraryRouteLink(value: .artistSection(identity, section)) {
            HStack(spacing: 6) {
                Text(section.title).font(.system(size: headingSize, weight: .bold))
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold))
            }
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func shelf(_ section: ArtistSection, items: [LibraryShelfItem]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                heading(section).padding(.horizontal, 20)
                ScrollView(.horizontal) { LazyHStack(alignment: .top, spacing: 12) { ForEach(items) { item in CollectionCardLink(item: item) { AlbumCard(item: item) }.frame(width: 160) } }.scrollTargetLayout() }
                    .fixedSize(horizontal: false, vertical: true)
                    .contentMargins(.horizontal, 20).scrollTargetBehavior(.viewAligned).scrollIndicators(.hidden)
            }.padding(.top, 24)
        }
    }
}

/// Continuous scrolling updates only this background, leaving the page's content stable.
private struct ArtistPageShade: ViewModifier {
    @State private var shade: CGFloat = 96

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) {
                max(44, 96 - max(0, $0.contentOffset.y + $0.contentInsets.top - 192) * 0.047)
            } action: { _, value in shade = value }
            .background {
                Color(red: shade / 255, green: (shade - 1) / 255, blue: (shade - 2) / 255).ignoresSafeArea()
            }
    }
}

struct ArtistSectionView: View {
    let detail: ArtistDetail
    let section: ArtistSection
    var playSong: ((LibrarySongItem) -> Void)?
    @Environment(\.libraryNavigationChrome) private var chrome
    @Environment(\.dynamicTypeSize) private var textSize
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: textSize.isAccessibilitySize ? 1 : 2)
    }
    var body: some View {
        Group {
            switch section {
            case .songs: List(detail.songs) { song in ArtistSongRow(song: song, songs: detail.songs, source: detail.name, dark: false, playSong: playSong).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)).listRowSeparator(.hidden) }.listStyle(.plain)
            case .similar:
                List(detail.similar) { artist in
                    LibraryRouteLink(value: .artist(artist.id), preview: artistPreview(artist)) {
                        HStack(spacing: 12) {
                            ArtistAvatar(artwork: artist.artwork).frame(width: 64, height: 64)
                            Text(artist.name).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }.padding(.vertical, 8)
                    }.listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                }.listStyle(.plain)
            case .albums, .singles:
                ScrollView { LazyVGrid(columns: columns, alignment: .leading, spacing: 20) { ForEach(section == .albums ? detail.albums : detail.singles) { item in CollectionCardLink(item: item) { AlbumCard(item: item) } } }.padding(.horizontal, 20) }
            }
        }.navigationTitle(section.title).libraryTitleDisplayMode(.inline).onAppear { chrome?.setColorScheme(nil) }
    }
}

private struct ArtistSongRow: View {
    let song: LibrarySongItem
    let songs: [LibrarySongItem]
    let source: String
    let dark: Bool
    var playSong: ((LibrarySongItem) -> Void)?
    @Environment(\.songMenuActions) private var actions
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var titleSize = 17.0
    @ScaledMetric(relativeTo: .footnote) private var albumSize = 13.0
    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let playSong { playSong(song) }
                else if let index = songs.firstIndex(where: { $0.id == song.id }) { actions.play(songs, index, source) }
            } label: {
                HStack(spacing: 12) {
                    PlaylistSongArtwork(song: song).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).font(.system(size: titleSize))
                            .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                        Text(song.album).font(.system(size: albumSize))
                            .foregroundStyle(dark ? Color.white.opacity(0.72) : Color.secondary)
                            .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(.rect)
            }.buttonStyle(.automatic)
            TrackMoreButton(song: song, color: dark ? Color.white.opacity(0.8) : Color.secondary).frame(width: 44, height: 44).padding(.trailing, 2)
        }.padding(.vertical, 4)
            .overlay(alignment: .bottom) { Rectangle().fill(dark ? Color.white.opacity(0.2) : Color.black.opacity(0.18)).frame(height: 0.33).padding(.leading, 60) }
            .songContextMenu(song)
    }
}
