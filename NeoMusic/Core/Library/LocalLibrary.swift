import SwiftUI

struct PinnedOrderID: Hashable, Codable {
    enum Kind: String, Codable { case playlist, album, artist }
    let kind: Kind
    let id: String
    let ownerID: String?

    init(kind: Kind, id: String, ownerID: String? = nil) {
        self.kind = kind
        self.id = id
        self.ownerID = ownerID
    }

}

@MainActor @Observable
final class PinnedOrderStore {
    private(set) var order: [PinnedOrderID]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let canWrite: Bool

    init(defaults: UserDefaults = .standard, key: String = AppDefaultsKey.pinnedShelfOrder) {
        self.defaults = defaults
        self.key = key
        if let stored = defaults.object(forKey: key) {
            if let data = stored as? Data, let decoded = try? JSONDecoder().decode([PinnedOrderID].self, from: data) {
                var seen = Set<PinnedOrderID>()
                order = decoded.filter { seen.insert($0).inserted }
                canWrite = true
            } else {
                order = []
                canWrite = false
            }
        } else {
            order = []
            canWrite = true
        }
    }

    func ordered<T>(_ items: [T], id: (T) -> PinnedOrderID?) -> [T] {
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated().sorted { lhs, rhs in
            let left = id(lhs.element).flatMap { ranks[$0] } ?? Int.max
            let right = id(rhs.element).flatMap { ranks[$0] } ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    @discardableResult
    func reorder(visible: [PinnedOrderID], to requested: [PinnedOrderID]) -> Bool {
        let visibleSet = Set(visible)
        guard canWrite, visible.count == visibleSet.count, requested.count == visible.count,
              Set(requested) == visibleSet else { return false }
        let saved = Set(order)
        let all = order + visible.filter { !saved.contains($0) }
        var next = 0
        let updated = all.map { id in
            guard visibleSet.contains(id) else { return id }
            defer { next += 1 }
            return requested[next]
        }
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: key)
        order = updated
        return true
    }
}

@MainActor @Observable
final class LibrarySelectionSet {
    private(set) var ids: Set<String> { didSet { if let key { defaults.set(Array(ids), forKey: key) } } }
    private let key: String?
    private let defaults: UserDefaults

    init(ids: Set<String>, key: String? = nil, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        self.ids = key.flatMap { defaults.stringArray(forKey: $0) }.map(Set.init) ?? ids
    }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func insert(_ id: String) { ids.insert(id) }
    func remove(_ id: String) { ids.remove(id) }
}

@MainActor
final class LocalAlbumIndex {
    let items: [LibraryShelfItem]
    let itemsByID: [String: LibraryShelfItem]
    let songIDsByAlbum: [String: [String]]
    let albumIDsByArtist: [String: [String]]

    init(songs: [LibrarySongItem]) {
        let groups = Dictionary(grouping: songs, by: \.albumID)
        var items: [LibraryShelfItem] = []
        var songIDs: [String: [String]] = [:]
        var artistAlbums: [String: [String]] = [:]
        for id in groups.keys.sorted() {
            let members = groups[id, default: []].sorted(by: LibrarySongItem.albumOrder)
            guard let first = members.first else { continue }
            var credits: [String] = []
            for member in members where !credits.contains(member.albumArtist) { credits.append(member.albumArtist) }
            items.append(LibraryShelfItem(id: id, title: first.album, subtitle: credits.joined(separator: " / "),
                                          artwork: first.artwork, route: .album(id),
                                          addedOrder: members.map(\.addedOrder).max() ?? 0,
                                          year: members.compactMap(\.year).first,
                                          albumBackdrop: first.artworkBackdrop))
            songIDs[id] = members.map(\.id)
            for artist in credits { artistAlbums[artist, default: []].append(id) }
        }
        self.items = items
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        songIDsByAlbum = songIDs
        albumIDsByArtist = artistAlbums
    }

    static func hasSameMetadata(_ lhs: [LibrarySongItem], _ rhs: [LibrarySongItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.id == b.id && a.albumID == b.albumID && a.album == b.album && a.albumArtist == b.albumArtist
                && a.trackNumber == b.trackNumber && a.discNumber == b.discNumber
                && a.artwork == b.artwork && a.artworkBackdrop == b.artworkBackdrop && a.addedOrder == b.addedOrder
                && a.year == b.year
        }
    }
}

@MainActor @Observable
final class SongLibrary {
    private(set) var songs: [LibrarySongItem] {
        didSet {
            rebuildCatalog()
            if !LocalAlbumIndex.hasSameMetadata(oldValue, songs) {
                albumIndex = LocalAlbumIndex(songs: songs.filter { $0.onlineAlbumID == nil })
            }
        }
    }
    var localSongs: [LibrarySongItem] { songs }
    private(set) var albumIndex = LocalAlbumIndex(songs: [])
    @ObservationIgnored private var onlineSongsByID: [String: LibrarySongItem] = [:]
    private(set) var onlineSongs: [LibrarySongItem] = [] {
        didSet {
            onlineSongsByID = Dictionary(onlineSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rebuildCatalog()
        }
    }
    private(set) var externalSongs: [LibrarySongItem] = [] { didSet { rebuildCatalog() } }
    private var externalSources: [String: [LibrarySongItem]] = [:]
    private(set) var allSongs: [LibrarySongItem] = []
    private(set) var favoriteSongs: [LibrarySongItem] = []
    private var songsByID: [String: LibrarySongItem] = [:]
    @ObservationIgnored private var visibleSongIDs: Set<String> = []
    @ObservationIgnored private(set) var catalogRevision = 0
    private var isBatching = false
    @ObservationIgnored var downloadedFileID: (@MainActor (String) -> String?)?
    @ObservationIgnored var downloadedFavoriteAction: (@MainActor (LibrarySongItem, Bool, Bool) -> Bool)?

    func refreshDownloadPresentation() { rebuildCatalog() }

    func updateLocalMetadata(_ replacements: [String: LibrarySongItem]) {
        let updated = songs.map { replacements[$0.id] ?? $0 }
        if songs != updated { songs = updated }
    }

    func applyBatch(localMetadata: [String: LibrarySongItem]? = nil,
                    externalSongs externalValues: [LibrarySongItem]? = nil,
                    externalSource: String = "home",
                    forceCatalogRefresh: Bool = false) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let wasBatching = isBatching
            isBatching = true
            var needsRebuild = forceCatalogRefresh
            if let localMetadata {
                let updated = songs.map { localMetadata[$0.id] ?? $0 }
                if songs != updated {
                    songs = updated
                    needsRebuild = true
                }
            }
            if let externalValues, externalSources[externalSource] != externalValues {
                externalSources[externalSource] = externalValues
                var seen = Set<String>()
                let updated = externalSources.keys.sorted().flatMap { externalSources[$0] ?? [] }
                    .filter { $0.isOnline && seen.insert($0.id).inserted }
                if externalSongs != updated {
                    externalSongs = updated
                    needsRebuild = true
                }
            }
            isBatching = wasBatching
            if !isBatching && needsRebuild { rebuildCatalog() }
        }
    }

    func song(id: String) -> LibrarySongItem? { songsByID[id] }

    func visibleSong(id: String) -> LibrarySongItem? {
        _ = allSongs
        return visibleSongIDs.contains(id) ? songsByID[id] : nil
    }

    private func rebuildCatalog() {
        guard !isBatching else { return }
        var existing = Set<String>()
        existing.reserveCapacity(songs.count + onlineSongs.count)
        for song in songs { existing.insert(song.id) }
        for song in onlineSongs { existing.insert(song.id) }

        var candidates: [LibrarySongItem] = []
        candidates.reserveCapacity(songs.count + onlineSongs.count + externalSongs.count)
        candidates.append(contentsOf: songs)
        candidates.append(contentsOf: onlineSongs)
        for song in externalSongs where !existing.contains(song.id) {
            candidates.append(song)
        }

        var visibleFileIDs = Set<String>()
        visibleFileIDs.reserveCapacity(songs.count)
        for song in songs { visibleFileIDs.insert(song.id) }

        var updated: [LibrarySongItem] = []
        updated.reserveCapacity(candidates.count)
        for song in candidates {
            if song.isOnline, let localID = downloadedFileID?(song.id) {
                guard visibleFileIDs.insert(localID).inserted else { continue }
            }
            updated.append(song)
        }
        if allSongs != updated {
            catalogRevision &+= 1
            visibleSongIDs = Set(updated.map(\.id))
            allSongs = updated
            let updatedFavorites = Self.orderedFavorites(updated)
            if favoriteSongs != updatedFavorites { favoriteSongs = updatedFavorites }
        }
        var byID: [String: LibrarySongItem] = [:]
        byID.reserveCapacity(candidates.count)
        for candidate in candidates where byID[candidate.id] == nil {
            byID[candidate.id] = candidate
        }
        songsByID = byID
    }
    func replaceExternalSongs(_ values: [LibrarySongItem], source: String = "home") {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            guard externalSources[source] != values else { return }
            externalSources[source] = values
            var seen = Set<String>()
            let updated = externalSources.keys.sorted().flatMap { externalSources[$0] ?? [] }.filter { $0.isOnline && seen.insert($0.id).inserted }
            if externalSongs != updated { externalSongs = updated }
        }
    }
    @ObservationIgnored var onlineFavoriteAction: (@MainActor (String, Bool, Bool) -> Void)?
    private let defaults: UserDefaults
    init(songs: [LibrarySongItem], defaults: UserDefaults = .standard) {
        self.songs = []
        self.defaults = defaults
        replace(songs)
    }

    func replace(_ songs: [LibrarySongItem]) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let dates = defaults.dictionary(forKey: AppDefaultsKey.favoriteSongDates) as? [String: Double] ?? [:]
            let updated = songs.map { song in
                var song = song
                if song.isFavorite { song.favoriteAddedAt = dates[song.id].map(Date.init(timeIntervalSince1970:)) }
                return song
            }
            if self.songs != updated { self.songs = updated }
        }
    }

    @discardableResult
    func replaceOnline(_ songs: [LibrarySongItem]) -> Bool {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        return withTransaction(transaction) {
            var seen: Set<String> = []
            let updated = songs.filter { $0.isOnline && seen.insert($0.id).inserted }
            guard onlineSongs != updated else { return false }
            onlineSongs = updated
            return true
        }
    }

    func updateOnlineFavorites(_ replacements: [String: LibrarySongItem], order: [String]) {
        guard !onlineSongs.isEmpty || !replacements.isEmpty else { return }
        let existingIDs = Set(onlineSongs.map(\.id))
        var changed: [LibrarySongItem] = []
        changed.reserveCapacity(onlineSongs.count + replacements.count)
        for song in onlineSongs { changed.append(replacements[song.id] ?? song) }
        for song in replacements.values where song.isOnline && !existingIDs.contains(song.id) {
            changed.append(song)
        }
        let positions = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let updated = changed.sorted { lhs, rhs in
            let a = positions[lhs.id], b = positions[rhs.id]
            if let a, let b { return a < b }
            if a != nil { return true }
            if b != nil { return false }
            return (lhs.onlineSongID ?? 0) < (rhs.onlineSongID ?? 0)
        }
        if onlineSongs != updated { onlineSongs = updated }
    }

    func updateOnlineArtwork(_ replacements: [String: LibrarySongItem], source: String? = nil) {
        guard !replacements.isEmpty else { return }
        if let source {
            for item in externalSources[source] ?? [] {
                if let replacement = replacements[item.id] { item.publishArtwork(from: replacement) }
            }
            return
        }
        for (id, replacement) in replacements {
            onlineSongsByID[id]?.publishArtwork(from: replacement)
        }
    }

    static func orderedFavorites(_ songs: [LibrarySongItem]) -> [LibrarySongItem] {
        songs.enumerated().filter { $0.element.isFavorite }.sorted { lhs, rhs in
            switch (lhs.element.favoriteAddedAt, rhs.element.favoriteAddedAt) {
            case let (a?, b?) where a != b: return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    func setFavorite(_ id: String, _ value: Bool, playsSuccessHaptic: Bool = true) {
        if let song = song(id: id), downloadedFavoriteAction?(song, value, playsSuccessHaptic) == true { return }
        if OnlineSongIdentity.parse(id) != nil {
            if song(id: id)?.isFavorite != value { onlineFavoriteAction?(id, value, playsSuccessHaptic) }
            return
        }
        guard let index = songs.firstIndex(where: { $0.id == id }), songs[index].isFavorite != value else { return }
        var updated = songs[index]
        updated.isFavorite = value
        var ids = Set(defaults.stringArray(forKey: AppDefaultsKey.favoriteSongs) ?? [])
        if value { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: AppDefaultsKey.favoriteSongs)
        var dates = defaults.dictionary(forKey: AppDefaultsKey.favoriteSongDates) as? [String: Double] ?? [:]
        let date = value ? Date() : nil
        dates[id] = date?.timeIntervalSince1970
        defaults.set(dates, forKey: AppDefaultsKey.favoriteSongDates)
        updated.favoriteAddedAt = date
        songs[index] = updated
    }

    func toggleFavorite(_ id: String) {
        guard let song = song(id: id) else { return }
        setFavorite(id, !song.isFavorite)
    }

    func togglePin(_ id: String) {
        guard let index = songs.firstIndex(where: { $0.id == id }) else { return }
        songs[index].isPinned.toggle()
        LocalLibraryRuntime.setFlag(id, value: songs[index].isPinned, key: AppDefaultsKey.pinnedSongs, defaults: defaults)
    }

    func delete(_ id: String) { LocalLibraryRuntime.setFlag(id, value: true, key: AppDefaultsKey.hiddenSongs, defaults: defaults); songs.removeAll { $0.id == id } }
}
