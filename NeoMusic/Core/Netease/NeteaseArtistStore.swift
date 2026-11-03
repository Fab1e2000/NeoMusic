import Foundation
import Observation

@MainActor @Observable
final class NeteaseArtistStore {
    private(set) var userID: Int64?
    private(set) var details: [Int64: NeteaseArtistDetail] = [:]
    private(set) var releases: [Int64: [NeteaseArtistAlbum]] = [:]
    private(set) var similar: [Int64: [NeteaseArtistReference]] = [:]
    private(set) var albums: [Int64: NeteaseArtistAlbumDetail] = [:]
    private(set) var subscribedArtists: [NeteaseArtistReference] = []
    private(set) var subscribedAlbums: [NeteaseArtistAlbum] = []
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var artwork: [String: URL] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var resolvedSongs: [Int64: NeteaseMusicSong] = [:]
    private(set) var isReady = false
    @ObservationIgnored private let artworkSession = URLSession(configuration: NeteaseAccountClient.sessionConfiguration())
    var cachedSongs: [NeteaseMusicSong] {
        var songs: [Int64: NeteaseMusicSong] = resolvedSongs
        for detail in details.values { for song in detail.songs { songs[song.id] = song } }
        for album in albums.values { for song in album.songs { songs[song.id] = song } }
        return songs.values.sorted { $0.id < $1.id }
    }
    init(client: NeteaseMusicClient = NeteaseMusicClient(), directory: URL? = nil) {
        self.client = client
        self.directory = directory ?? URL.cachesDirectory.appendingPathComponent("NeteaseArtists")
    }
    private var cacheURL: URL { directory.appendingPathComponent("\(userID.map(String.init) ?? "public").json") }
    func activate(_ session: NeteaseSavedSession?, refresh: Bool = true) async {
        if !isReady || userID != session?.profile.userID || credential != session?.credential {
            await invalidate()
            isReady = true; userID = session?.profile.userID; credential = session?.credential
            if let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
                details = cache.details; releases = cache.releases; similar = cache.similar; albums = cache.albums
                subscribedArtists = cache.artists; subscribedAlbums = cache.collected; artwork = cache.artwork.mapValues { directory.appendingPathComponent($0.lastPathComponent) }
            }
            onChange?()
        }
        if refresh { await self.refresh() }
    }
    func invalidate() async {
        revision = UUID(); credential = nil; userID = nil; isReady = false
        let pending = Array(tasks.values); tasks.removeAll()
        resolvedSongs = [:]
        details = [:]; releases = [:]; similar = [:]; albums = [:]; subscribedArtists = []; subscribedAlbums = []; errors = [:]; artwork = [:]
        onChange?()
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
    }
    private func run(_ key: String, token: UUID, operation: @escaping @MainActor () async throws -> Void) async {
        guard token == revision, isReady, !Task.isCancelled else { return }
        if let task = tasks[key] { await task.value; return }
        let task = Task { [self] in
            do { try await operation(); try check(token); errors[key] = nil; save(); onChange?() }
            catch is CancellationError { }
            catch { if token == revision { errors[key] = error.localizedDescription; onChange?() } }
        }
        tasks[key] = task; await task.value
        if token == revision { tasks.removeValue(forKey: key) }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        if revision != token { throw CancellationError() }
    }
    func refresh() async {
        let token = revision, credential = credential
        await run("subscriptions", token: token) { [self] in
            guard let credential else { return }
            let artists = try await client.subscribedArtists(credential: credential)
            let collected = try await client.subscribedAlbums(credential: credential)
            try check(token); subscribedArtists = artists; subscribedAlbums = collected
            await cacheArtwork(artists.compactMap(\.artworkURL) + collected.compactMap(\.artworkURL), token: token)
        }
    }
    func loadArtist(id: Int64) async {
        let token = revision, credential = credential
        var fullBiography: String?
        async let profile: Void = run("artist:\(id)", token: token) { [self] in
            let detail = try await client.artistDetail(id: id, credential: credential)
            try check(token); details[id] = detail; onChange?()
            await cacheArtwork([detail.artist.artworkURL].compactMap { $0 } + detail.songs.compactMap(\.artworkURL), token: token)
        }
        async let biography: Void = run("biography:\(id)", token: token) { [self] in
            let text = try await client.artistBiography(id: id, credential: credential)
            try check(token)
            fullBiography = text
        }
        async let works: Void = run("releases:\(id)", token: token) { [self] in
            let value = try await client.artistAlbums(id: id, credential: credential)
            try check(token); releases[id] = value; onChange?()
            await cacheArtwork(value.compactMap(\.artworkURL), token: token)
        }
        async let related: Void = run("similar:\(id)", token: token) { [self] in
            let value = try await client.similarArtists(id: id, credential: credential)
            try check(token); similar[id] = value; onChange?()
            await cacheArtwork(value.compactMap(\.artworkURL), token: token)
        }
        _ = await (profile, biography, works, related)
        if token == revision, let text = fullBiography, let detail = details[id] {
            details[id] = .init(artist: detail.artist, biography: text, songs: detail.songs); save(); onChange?()
        }
    }
    func song(id: Int64) async throws -> NeteaseMusicSong {
        let token = revision, credential = credential
        await run("song:\(id)", token: token) { [self] in
            let value = try await client.songDetail(id: id, credential: credential)
            try check(token); resolvedSongs[id] = value
        }
        try check(token)
        guard let result = resolvedSongs[id] else { throw NeteaseAccountError.invalidResponse }
        return result
    }
    func loadAlbum(id: Int64) async {
        let token = revision, credential = credential
        await run("album:\(id)", token: token) { [self] in
            let value = try await client.albumDetail(id: id, credential: credential)
            try check(token); albums[id] = value; onChange?()
            await cacheArtwork([value.album.artworkURL].compactMap { $0 } + value.songs.compactMap(\.artworkURL), token: token)
        }
    }
    func setArtistSubscribed(id: Int64, subscribed: Bool) async throws {
        try await setSubscription(id: id, subscribed: subscribed, artist: true)
    }
    func setAlbumSubscribed(id: Int64, subscribed: Bool) async throws {
        try await setSubscription(id: id, subscribed: subscribed, artist: false)
    }
    private func setSubscription(id: Int64, subscribed: Bool, artist: Bool) async throws {
        guard let credential else { throw NeteaseAccountError.authenticationRequired }
        let token = revision
        var failure: Error?
        await run("write:\(artist):\(id)", token: token) { [self] in
            do {
                if artist { try await client.setArtistSubscribed(id: id, subscribed: subscribed, credential: credential) }
                else { try await client.setAlbumSubscribed(id: id, subscribed: subscribed, credential: credential) }
            } catch let error as URLError where error.code == .notConnectedToInternet { throw error }
            catch { failure = error }
            try check(token)
            if artist {
                let value = try await client.subscribedArtists(credential: credential)
                try check(token); subscribedArtists = value
                if value.contains(where: { $0.id == id }) == subscribed { failure = nil }
                else if failure == nil { failure = NeteaseAccountError.invalidResponse }
            } else {
                let value = try await client.subscribedAlbums(credential: credential)
                try check(token); subscribedAlbums = value
                if value.contains(where: { $0.id == id }) == subscribed { failure = nil }
                else if failure == nil { failure = NeteaseAccountError.invalidResponse }
            }
            if let failure { throw failure }
        }
        try check(token)
        if let error = errors["write:\(artist):\(id)"] { throw NSError(domain: "NeteaseArtist", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }
    func cachedArtworkURL(_ remote: URL) -> URL? { artwork[remote.absoluteString].flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } }
    private func cacheArtwork(_ urls: [URL], token: UUID) async {
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            guard token == revision, !Task.isCancelled else { return }
            if cachedArtworkURL(url) != nil { continue }
            do {
                let (data, response) = try await artworkSession.data(from: url)
                try check(token)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("\(userID.map(String.init) ?? "public")-\(UUID().uuidString).image")
                try data.write(to: file, options: .atomic); artwork[url.absoluteString] = file; onChange?()
            } catch { }
        }
    }
    private struct Cache: Codable {
        let details: [Int64: NeteaseArtistDetail]; let releases: [Int64: [NeteaseArtistAlbum]]
        let similar: [Int64: [NeteaseArtistReference]]; let albums: [Int64: NeteaseArtistAlbumDetail]
        let artists: [NeteaseArtistReference]; let collected: [NeteaseArtistAlbum]; let artwork: [String: URL]
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(details: details, releases: releases, similar: similar, albums: albums, artists: subscribedArtists, collected: subscribedAlbums, artwork: artwork)).write(to: cacheURL, options: .atomic)
        } catch { errors["cache"] = error.localizedDescription }
    }
}
