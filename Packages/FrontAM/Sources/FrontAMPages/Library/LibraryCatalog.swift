import FrontAMCore
import SwiftUI
import Observation

@MainActor @Observable public final class LibraryCatalog {
    public var artists: [LibraryArtistItem] = []
    public var artistOwnerID: String?
    public var albums: [LibraryShelfItem] = []
    public var downloadedAlbums: [LibraryShelfItem] = []
    @ObservationIgnored public var cachedAlbumItem: ((String) -> LibraryShelfItem?)?
    @ObservationIgnored public var loadAlbumSongs: ((String) async throws -> [LibrarySongItem])?
    @ObservationIgnored public var loadArtistDetail: ((String) async throws -> ArtistDetail?)?
    @ObservationIgnored public var activeArtistOwner: (() -> String?)?
    @ObservationIgnored public var activeArtistSession: (() -> UUID?)?
    @ObservationIgnored public var actions = CollectionMenuActions()
    @ObservationIgnored public var openSongAlbum: ((LibrarySongItem, @escaping (LibraryRoute) -> Void) -> Void)?
    @ObservationIgnored public var openSongArtist: ((LibrarySongItem, String?, @escaping (LibraryRoute) -> Void) -> Void)?
    @ObservationIgnored public var downloadedOnlineSongID: ((String) -> Int64?)?
    public init() {}
}
