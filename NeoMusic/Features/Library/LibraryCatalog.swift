import SwiftUI
import Observation

@MainActor @Observable final class LibraryCatalog {
    var artists: [LibraryArtistItem] = []
    var albums: [LibraryShelfItem] = []
    var downloadedAlbums: [LibraryShelfItem] = []
    @ObservationIgnored var loadAlbumSongs: ((String) async throws -> [LibrarySongItem])?
    @ObservationIgnored var loadArtistDetail: ((String) async throws -> ArtistDetail?)?
    @ObservationIgnored var actions = CollectionMenuActions()
    @ObservationIgnored var openSongAlbum: ((String, @escaping (LibraryRoute) -> Void) -> Void)?
    @ObservationIgnored var openSongArtist: ((String, String?, @escaping (LibraryRoute) -> Void) -> Void)?
    @ObservationIgnored var downloadedOnlineSongID: ((String) -> Int64?)?
    func handles(_ route: LibraryRoute) -> Bool {
        switch route {
        case .artist(let id), .album(let id), .artistSection(let id, _): CatalogRouteIdentity.isCatalogID(id)
        default: false
        }
    }
}
