import FrontAMCore
import SwiftUI

public struct LibraryArtistEntry: Identifiable {
    public let id: LibraryArtistIdentity
    public var name: String
    public var catalogRoute: LibraryRoute? = nil
    public var portrait: Artwork?
    public var isFavorite = false
    public var isPinned = false
    public var isDownloaded = false
    public var songs: [LibrarySongItem] = []
    public var albums: [LibraryShelfItem] = []

    public var avatar: ArtistAvatarArtwork {
        if let portrait, portrait != .missing { return .portrait(portrait) }
        return albumAvatar
    }

    public var libraryAvatar: ArtistAvatarArtwork {
        guard catalogRoute != nil else { return avatar }
        if case .portrait(.image) = avatar { return avatar }
        return albumAvatar
    }

    private var albumAvatar: ArtistAvatarArtwork {
        if let cover = albums.first(where: { $0.artwork != .missing }) {
            return .album(cover.artwork, cover.albumBackdrop)
        }
        return .missing
    }

    public var shelfItem: LibraryShelfItem {
        LibraryShelfItem(id: id.itemID, title: name, artwork: .missing,
                         route: .libraryArtist(id), isFavorite: isFavorite, isPinned: isPinned,
                         artistAvatar: libraryAvatar)
    }

    public static func visible(_ artists: [Self], filter: LibraryFilter, query: String) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return artists.filter { artist in
            switch filter {
            case .all: break
            case .favorites: guard artist.isFavorite else { return false }
            case .downloaded: guard artist.isDownloaded else { return false }
            }
            guard !term.isEmpty else { return true }
            if artist.name.localizedStandardContains(term) { return true }
            let key = TitleSection<Self>.sortKey(artist.name)
            return key.localizedStandardContains(term)
                || key.filter { !$0.isWhitespace }.localizedStandardContains(term.filter { !$0.isWhitespace })
        }.sorted(byName: \.name)
    }

    public init(id: LibraryArtistIdentity,
                name: String,
                catalogRoute: LibraryRoute? = nil,
                portrait: Artwork? = nil,
                isFavorite: Bool = false,
                isPinned: Bool = false,
                isDownloaded: Bool = false,
                songs: [LibrarySongItem] = [],
                albums: [LibraryShelfItem] = []) {
        self.id = id
        self.name = name
        self.catalogRoute = catalogRoute
        self.portrait = portrait
        self.isFavorite = isFavorite
        self.isPinned = isPinned
        self.isDownloaded = isDownloaded
        self.songs = songs
        self.albums = albums
    }
}

