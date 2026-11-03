import SwiftUI
import Observation

/// Library projections and actions supplied by the app's catalog integration.
@MainActor @Observable final class LibraryCatalog {
    var artists: [LibraryArtistItem] = []
    var albums: [LibraryShelfItem] = []
    @ObservationIgnored var loadAlbumSongs: ((String) async throws -> [LibrarySongItem])?
    @ObservationIgnored var actions = CollectionMenuActions()
    @ObservationIgnored var openSongAlbum: ((String, @escaping (LibraryRoute) -> Void) -> Void)?
    @ObservationIgnored var openSongArtist: ((String, String?, @escaping (LibraryRoute) -> Void) -> Void)?
    func handles(_ route: LibraryRoute) -> Bool {
        switch route {
        case .artist(let id), .album(let id), .artistSection(let id, _): id.hasPrefix("catalog:")
        default: false
        }
    }
}
