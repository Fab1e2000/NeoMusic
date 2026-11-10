import SwiftUI

/// A typed identity prevents a playlist and an album with the same ID from colliding.
struct PinnedOrderID: Hashable, Codable {
    enum Kind: String, Codable { case playlist, album }
    let kind: Kind
    let id: String

    init(kind: Kind, id: String) { self.kind = kind; self.id = id }

}

/// Pin flags remain authoritative. The order is independent, so partial loading,
/// a missing file, or a cancelled scan cannot erase a user's saved positions.
@MainActor @Observable
final class PinnedOrderStore {
    private(set) var order: [PinnedOrderID]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String
    @ObservationIgnored private let canWrite: Bool

    init(defaults: UserDefaults = .standard, key: String = "pinnedShelfOrder.v1") {
        self.defaults = defaults
        self.key = key
        if let stored = defaults.object(forKey: key) {
            if let data = stored as? Data, let decoded = try? JSONDecoder().decode([PinnedOrderID].self, from: data) {
                var seen = Set<PinnedOrderID>()
                order = decoded.filter { seen.insert($0).inserted }
                canWrite = true
            } else {
                // A future version or damaged value must never be silently overwritten.
                order = []
                canWrite = false
            }
        } else {
            order = []
            canWrite = true
        }
    }

    /// Unseen pins append in the existing library order; unavailable pins retain their stored positions.
    func ordered<T>(_ items: [T], id: (T) -> PinnedOrderID?) -> [T] {
        let ranks = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated().sorted { lhs, rhs in
            let left = id(lhs.element).flatMap { ranks[$0] } ?? Int.max
            let right = id(rhs.element).flatMap { ranks[$0] } ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    /// Rearrange only a complete permutation of current pins. Hidden/unloaded IDs keep their slots.
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

/// 持久化选择集合。
@MainActor @Observable
final class LibrarySelectionSet {
    private(set) var ids: Set<String> { didSet { if let key { UserDefaults.standard.set(Array(ids), forKey: key) } } }
    private let key: String?
    init(ids: Set<String>, key: String? = nil) {
        self.key = key
        self.ids = key.flatMap { UserDefaults.standard.stringArray(forKey: $0) }.map(Set.init) ?? ids
    }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
    }

    func insert(_ id: String) { ids.insert(id) }
    func remove(_ id: String) { ids.remove(id) }
}

/// Album ordering and cover selection change with local metadata, independently of favorites and pins.
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
                                          addedOrder: members.map(\.addedOrder).max() ?? 0))
            songIDs[id] = members.map(\.id)
            for artist in credits { artistAlbums[artist, default: []].append(id) }
        }
        self.items = items
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        songIDsByAlbum = songIDs
        albumIDsByArtist = artistAlbums
    }

    /// Called on mutation only; reads reuse the prepared index without inspecting the song array.
    static func hasSameMetadata(_ lhs: [LibrarySongItem], _ rhs: [LibrarySongItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            a.id == b.id && a.albumID == b.albumID && a.album == b.album && a.albumArtist == b.albumArtist
                && a.trackNumber == b.trackNumber && a.discNumber == b.discNumber
                && a.artwork == b.artwork && a.addedOrder == b.addedOrder
        }
    }
}

/// 共享歌曲记录与持久化喜爱状态。
@MainActor @Observable
final class SongLibrary {
    private(set) var songs: [LibrarySongItem] {
        didSet {
            rebuildCatalog()
            if !LocalAlbumIndex.hasSameMetadata(oldValue, songs) { albumIndex = LocalAlbumIndex(songs: songs) }
        }
    }
    private(set) var albumIndex = LocalAlbumIndex(songs: [])
    private(set) var onlineSongs: [LibrarySongItem] = [] { didSet { rebuildCatalog() } }
    private(set) var externalSongs: [LibrarySongItem] = [] { didSet { rebuildCatalog() } }
    private var externalSources: [String: [LibrarySongItem]] = [:]
    private(set) var allSongs: [LibrarySongItem] = []
    private var songsByID: [String: LibrarySongItem] = [:]
    @ObservationIgnored var downloadedFileID: (@MainActor (String) -> String?)?
    @ObservationIgnored var downloadedFavoriteAction: (@MainActor (LibrarySongItem, Bool) -> Bool)?

    func refreshDownloadPresentation() { rebuildCatalog() }

    func updateLocalMetadata(_ replacements: [String: LibrarySongItem]) {
        let updated = songs.map { replacements[$0.id] ?? $0 }
        if songs != updated { songs = updated }
    }

    func song(id: String) -> LibrarySongItem? { songsByID[id] }

    private func rebuildCatalog() {
        let existing = Set((songs + onlineSongs).map(\.id))
        let candidates = songs + onlineSongs + externalSongs.filter { !existing.contains($0.id) }
        var visibleFileIDs = Set(songs.map(\.id))
        let updated = candidates.filter { song in
            guard song.isOnline, let localID = downloadedFileID?(song.id) else { return true }
            return visibleFileIDs.insert(localID).inserted
        }
        if allSongs != updated { allSongs = updated }
        // Detail routes and old queue entries keep their original online identity.
        songsByID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
    @ObservationIgnored var onlineFavoriteAction: (@MainActor (String, Bool) -> Void)?
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
            let dates = defaults.dictionary(forKey: "favoriteSongDates") as? [String: Double] ?? [:]
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

    /// Image arrivals update their owning catalog without reloading playback availability.
    func updateOnlineArtwork(_ replacements: [String: LibrarySongItem], source: String? = nil) {
        guard !replacements.isEmpty else { return }
        if let source {
            let existing = externalSources[source] ?? []
            replaceExternalSongs(existing.map { item in replacements[item.id].map { item.replacingArtwork(from: $0) } ?? item }, source: source)
        } else {
            let updated = onlineSongs.map { item in replacements[item.id].map { item.replacingArtwork(from: $0) } ?? item }
            if onlineSongs != updated { onlineSongs = updated }
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

    func setFavorite(_ id: String, _ value: Bool) {
        if let song = song(id: id), downloadedFavoriteAction?(song, value) == true { return }
        let parts = id.split(separator: ":")
        if parts.count == 3, parts[0] == "netease" {
            if song(id: id)?.isFavorite != value { onlineFavoriteAction?(id, value) }
            return
        }
        guard let index = songs.firstIndex(where: { $0.id == id }), songs[index].isFavorite != value else { return }
        var updated = songs[index]
        updated.isFavorite = value
        var ids = Set(defaults.stringArray(forKey: "favoriteSongs") ?? [])
        if value { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: "favoriteSongs")
        var dates = defaults.dictionary(forKey: "favoriteSongDates") as? [String: Double] ?? [:]
        let date = value ? Date() : nil
        dates[id] = date?.timeIntervalSince1970
        defaults.set(dates, forKey: "favoriteSongDates")
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
        LocalLibraryRuntime.setFlag(id, value: songs[index].isPinned, key: "pinnedSongs", defaults: defaults)
    }

    func delete(_ id: String) { LocalLibraryRuntime.setFlag(id, value: true, key: "hiddenSongs", defaults: defaults); songs.removeAll { $0.id == id } }
}
