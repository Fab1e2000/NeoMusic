import Foundation
import Observation

extension LibraryArtistIdentity {
    var onlineRoute: LibraryRoute? {
        guard case .catalog(let id, _) = self, let number = CatalogRouteIdentity.parseArtistID(id), number > 0 else { return nil }
        return .artist(id)
    }

    func belongs(to owner: String?) -> Bool {
        switch self {
        case .local: true
        case .catalog(_, let ownerID): ownerID == owner
        }
    }
}

@MainActor @Observable
final class LibraryArtistPreferences {
    private struct Snapshot: Codable {
        var localIDs: [String: UUID] = [:]
        var favorites: Set<LibraryArtistIdentity> = []
        var pins: [LibraryArtistIdentity: String] = [:]
    }

    private var snapshot: Snapshot
    private let defaults: UserDefaults
    private let key = AppDefaultsKey.libraryArtistPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        snapshot = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
    }

    static func localCredits(for song: LibrarySongItem) -> [String] {
        (song.artist.components(separatedBy: " / ") + song.albumArtist.components(separatedBy: " / "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func creditKey(_ credit: String) -> String {
        credit.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    func registerLocalCredits(in songs: [LibrarySongItem]) {
        var updated = snapshot
        for song in songs where song.artistReferences.isEmpty {
            for credit in Self.localCredits(for: song) {
                let key = Self.creditKey(credit)
                if updated.localIDs[key] == nil { updated.localIDs[key] = UUID() }
            }
        }
        if updated.localIDs != snapshot.localIDs { save(updated) }
    }

    func localIdentity(for credit: String) -> LibraryArtistIdentity? {
        snapshot.localIDs[Self.creditKey(credit)].map(LibraryArtistIdentity.local)
    }

    func pins(for owner: String?) -> [LibraryArtistIdentity: String] {
        snapshot.pins.filter { $0.key.belongs(to: owner) }
    }

    func isFavorite(_ id: LibraryArtistIdentity, owner: String?) -> Bool {
        id.belongs(to: owner) && snapshot.favorites.contains(id)
    }

    func toggleFavorite(_ id: LibraryArtistIdentity, owner: String?) {
        guard id.belongs(to: owner) else { return }
        if case .catalog(_, .some) = id { return } // Signed-in favorites are confirmed by the subscription service.
        var updated = snapshot
        if !updated.favorites.insert(id).inserted { updated.favorites.remove(id) }
        save(updated)
    }

    func togglePin(_ id: LibraryArtistIdentity, name: String, owner: String?) {
        guard id.belongs(to: owner) else { return }
        var updated = snapshot
        if updated.pins.removeValue(forKey: id) == nil { updated.pins[id] = name }
        save(updated)
    }

    private func save(_ updated: Snapshot) {
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: key)
        snapshot = updated
    }
}

@MainActor
enum LibraryArtistCatalog {
    static func make(local: [LibrarySongItem], online: [LibrarySongItem], subscribed: [LibraryArtistItem],
                     albums: [LibraryShelfItem], owner: String?, preferences: LibraryArtistPreferences,
                     downloadedID: (String) -> Int64?) -> [LibraryArtistEntry] {
        let pins = preferences.pins(for: owner)
        var entries = pins.reduce(into: [LibraryArtistIdentity: LibraryArtistEntry]()) { entries, pin in
            entries[pin.key] = .init(id: pin.key, name: pin.value, isPinned: true)
        }
        for artist in subscribed where owner != nil {
            let id = LibraryArtistIdentity.catalog(id: artist.id, ownerID: owner)
            guard id.onlineRoute != nil else { continue }
            entries[id] = .init(id: id, name: artist.name, portrait: artist.artwork,
                                isFavorite: artist.isFavorite, isPinned: pins[id] != nil)
        }
        let downloadedIDs = Set(local.compactMap { downloadedID($0.id) })
        var seenSongs = Set<String>()
        for song in local + online where seenSongs.insert(song.id).inserted {
            let onDevice = !song.isOnline
            guard onDevice || (owner != nil && song.onlineOwnerID == owner && song.onlineSongID.map(downloadedIDs.contains) != true) else { continue }
            let credits: [(LibraryArtistIdentity, String)]
            if !song.artistReferences.isEmpty {
                credits = song.artistReferences.compactMap {
                    let id = LibraryArtistIdentity.catalog(id: $0.id, ownerID: owner)
                    return id.onlineRoute == nil ? nil : (id, $0.name)
                }
            } else if onDevice {
                credits = LibraryArtistPreferences.localCredits(for: song).compactMap { credit in
                    preferences.localIdentity(for: credit).map { ($0, credit) }
                }
            } else {
                continue
            }
            var seenArtists = Set<LibraryArtistIdentity>()
            for (id, name) in credits where seenArtists.insert(id).inserted {
                if entries[id] == nil { entries[id] = .init(id: id, name: name) }
                if onDevice { entries[id]?.isDownloaded = true }
                entries[id]?.songs.append(song)
            }
        }
        let availableAlbums = albums.filter { $0.sourceOwnerID == nil || $0.sourceOwnerID == owner }
        let albumsByID = Dictionary(availableAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var creditedAlbums: [LibraryArtistIdentity: [LibraryShelfItem]] = [:]
        for album in availableAlbums where album.sourceOwnerID != nil {
            for credit in album.artistReferences {
                let id = LibraryArtistIdentity.catalog(id: credit.id, ownerID: owner)
                guard id.onlineRoute != nil else { continue }
                if entries[id] == nil { entries[id] = .init(id: id, name: credit.name, portrait: credit.artwork) }
                else if entries[id]?.portrait == nil { entries[id]?.portrait = credit.artwork }
                creditedAlbums[id, default: []].append(album)
            }
        }
        return entries.values.map { entry in
            var result = entry
            result.catalogRoute = entry.id.onlineRoute
            result.isFavorite = entry.isFavorite || preferences.isFavorite(entry.id, owner: owner)
            let groups = Dictionary(grouping: entry.songs, by: \.albumID)
            var seenAlbums = Set<String>()
            let trackAlbums: [LibraryShelfItem] = groups.keys.sorted().compactMap { id in
                let tracks = groups[id, default: []]
                let ordered = tracks.sorted(by: LibrarySongItem.albumOrder)
                let addedOrder = ordered.map { max($0.addedOrder, Int($0.favoriteAddedAt?.timeIntervalSince1970 ?? 0)) }.max() ?? 0
                if var known = albumsByID[id] {
                    known.addedOrder = max(known.addedOrder, addedOrder)
                    if known.artwork == .missing, let track = ordered.first(where: { $0.artwork != .missing }) {
                        known.artwork = track.artwork
                        known.albumBackdrop = track.artworkBackdrop
                    }
                    return known
                }
                guard let first = ordered.first, CatalogRouteIdentity.parseAlbumID(id) != nil else { return nil }
                let cover = ordered.first { $0.artwork != .missing } ?? first
                return LibraryShelfItem(id: id, title: first.album, subtitle: first.albumArtist,
                    artwork: cover.artwork, route: .album(id),
                    addedOrder: addedOrder, year: first.year,
                    sourceOwnerID: first.onlineOwnerID, albumBackdrop: cover.artworkBackdrop)
            }
            let matches = trackAlbums + creditedAlbums[entry.id, default: []]
            result.albums = matches.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seenAlbums.insert($0.id).inserted }
                .sorted(byName: \.title)
            result.songs = entry.songs.sorted {
                if $0.albumID == $1.albumID { return LibrarySongItem.albumOrder($0, $1) }
                return $0.albumID.localizedStandardCompare($1.albumID) == .orderedAscending
            }
            return result
        }
    }
}
