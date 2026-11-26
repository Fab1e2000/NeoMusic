import FrontAMCore
import FrontAMNavigation
import SwiftUI

public struct LibraryArtistDetailView: View {
    private enum Sort: Hashable {
        case name, addedDate, year
    }

    public let artist: LibraryArtistEntry
    public let play: (Bool) async -> Void
    public var isCatalogAlbum: (String) -> Bool = { _ in false }

    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var layout = LibraryLayout.grid
    @State private var sort = Sort.name
    @State private var playTask: Task<Void, Never>?

    private let margin = DesignTokens.Spacing.pageMargin
    private let rowCover: CGFloat = 64

    private var route: LibraryRoute { .libraryArtist(artist.id) }

    private var sortedAlbums: [LibraryShelfItem] {
        switch sort {
        case .name: return artist.albums
        case .addedDate: return artist.albums.sorted { $0.addedOrder > $1.addedOrder }
        case .year: return artist.albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        }
    }

    public var body: some View {
        let albums = sortedAlbums
        List {
            header
                .listRowInsets(.init(top: 20, leading: margin, bottom: 24, trailing: margin))
                .listRowSeparator(.hidden)
            if albums.isEmpty {
                ContentUnavailableView(pageText("暂无专辑"), systemImage: "square.stack")
                    .listRowSeparator(.hidden)
            } else if layout == .grid {
                LibraryCollectionGrid(rowSpacing: 16, alignment: .center) {
                    ForEach(albums) { album in
                        Button { openAlbum(album) } label: {
                            AlbumCard(item: displayAlbum(album))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowInsets(.init(top: 0, leading: margin, bottom: 0, trailing: margin))
                .listRowSeparator(.hidden)
            } else {
                ForEach(albums) { album in
                    let preview = albumPreview(album)
                    LibraryRouteLink(value: preview.route, preview: preview) {
                        HStack(spacing: 12) {
                            ArtworkView(artwork: album.artwork, cornerRadius: DesignTokens.Radius.songRowCover)
                                .frame(width: rowCover)
                                .modifier(ArtistFavoriteGutter(isFavorite: album.isFavorite))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(album.title).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                                if let year = album.year { Text(yearLabel(year)).foregroundStyle(.secondary) }
                            }
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] + rowCover + 12 }
                    }
                    .listRowInsets(.init(top: 8, leading: margin, bottom: 8, trailing: margin))
                    .listRowSeparator(album.id == albums.first?.id ? .hidden : .automatic, edges: .top)
                    .listRowSeparator(album.id == albums.last?.id ? .hidden : .automatic, edges: .bottom)
                }
            }
        }
        .listStyle(.plain)
        .libraryTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(artist.isFavorite ? pageText("取消喜爱") : pageText("喜爱"), systemImage: artist.isFavorite ? "star.fill" : "star") {
                    actions.toggleFavorite(route)
                }
                .tint(artist.isFavorite ? .yellow : .primary)
                LibrarySortMenu(layout: $layout, sort: $sort, options: [
                    .init(sort: .name, title: pageText("名称"), subtitle: "A-Z"),
                    .init(sort: .addedDate, title: pageText("添加日期")),
                    .init(sort: .year, title: pageText("年份"))
                ], leading: menuActions)
                .menuOrder(.fixed)
            }
        }
        .onDisappear { playTask?.cancel() }
    }

    private var header: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                ArtistAvatar(source: artist.libraryAvatar, identity: artist.id)
                    .frame(width: 86)
                    .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
                if let online = artist.catalogRoute {
                    Button { openRoute(online) } label: {
                        HStack(spacing: 4) {
                            Text(artist.name)
                            Image(systemName: "chevron.right")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(pageText("前往在线艺人主页"))
                } else {
                    Text(artist.name)
                }
            }
            .font(.title.bold())
            .multilineTextAlignment(.center)
            if artist.songs.contains(where: { $0.unavailabilityReason == nil })
                || artist.albums.contains(where: { $0.sourceOwnerID != nil && $0.isFavorite }) {
                PlayShuffleButtons(play: { startPlayback(false) }, shuffle: { startPlayback(true) })
            }
        }
    }

    private var menuActions: LibraryMenuSections {
        var groups: LibraryMenuSections = [
            [.init(title: artist.isFavorite ? pageText("取消喜爱") : pageText("喜爱"), systemImage: artist.isFavorite ? "star.slash" : "star") {
                actions.toggleFavorite(route)
            }],
            [.init(title: artist.isPinned ? pageText("取消置顶") : pageText("置顶艺人"), systemImage: artist.isPinned ? "pin.slash" : "pin") {
                actions.togglePin(route)
            }]
        ]
        if let online = artist.catalogRoute {
            groups.append([.init(title: pageText("前往艺人"), systemImage: "music.microphone") { openRoute(online) }])
        }
        return groups
    }

    private func startPlayback(_ shuffled: Bool) {
        playTask?.cancel()
        playTask = Task { await play(shuffled) }
    }

    private func displayAlbum(_ album: LibraryShelfItem) -> LibraryShelfItem {
        var item = album
        item.subtitle = album.year.map(yearLabel)
        return item
    }

    private func yearLabel(_ year: Int) -> String { pageText("\(year.formatted(.number.grouping(.never)))年") }

    private func albumPreview(_ album: LibraryShelfItem) -> LibraryNavigationPreview {
        let offline = album.sourceOwnerID == nil && isCatalogAlbum(album.id)
        let route: LibraryRoute = offline ? .libraryArtistAlbum(artist.id, album.id) : .album(album.id)
        return .init(route: route, ownerID: album.sourceOwnerID, title: album.title,
                     subtitle: album.subtitle, artwork: album.artwork, albumBackdrop: album.albumBackdrop)
    }

    private func openAlbum(_ album: LibraryShelfItem) {
        let preview = albumPreview(album)
        openRoute(preview.route, preview: preview)
    }

    public init(artist: LibraryArtistEntry,
                play: @escaping (Bool) async -> Void,
                isCatalogAlbum: @escaping (String) -> Bool = { _ in false }) {
        self.artist = artist
        self.play = play
        self.isCatalogAlbum = isCatalogAlbum
    }
}
