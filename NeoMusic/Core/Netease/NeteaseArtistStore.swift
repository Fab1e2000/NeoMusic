import Foundation
import Observation

@MainActor @Observable
final class NeteaseArtistStore {
    enum Change {
        case reset, artist(Int64), album(Int64), song(Int64)
        case subscribedArtists(Set<Int64>), subscribedAlbums(Set<Int64>), error(String)
    }
    private(set) var userID: Int64?
    private(set) var details: [Int64: NeteaseArtistDetail] = [:]
    private(set) var releases: [Int64: [NeteaseArtistAlbum]] = [:]
    private(set) var similar: [Int64: [NeteaseArtistReference]] = [:]
    private(set) var albums: [Int64: NeteaseArtistAlbumDetail] = [:]
    private(set) var subscribedArtists: [NeteaseArtistReference] = []
    private(set) var subscribedAlbums: [NeteaseArtistAlbum] = []
    private var albumAdditions = AlbumLibraryAdditions()
    private(set) var errors: [String: String] = [:]
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onLibraryChange: (() -> Void)?
    @ObservationIgnored var onContentChange: ((Change) -> Void)?
    @ObservationIgnored var onArtworkChange: ((Set<URL>) -> Void)?
    var sessionRevision: UUID { revision }
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var resolvedSongs: [Int64: NeteaseMusicSong] = [:]
    @ObservationIgnored private var legacyArtwork: [String: URL] = [:]
    @ObservationIgnored private var songSources: [String: [Int64: NeteaseMusicSong]] = [:]
    @ObservationIgnored private var songOwners: [Int64: Set<String>] = [:]
    @ObservationIgnored nonisolated(unsafe) private var artworkObserver: NSObjectProtocol?
    @ObservationIgnored private var biographies: [Int64: String] = [:]
    @ObservationIgnored private var refreshedAt: [String: Date] = [:]
    private(set) var isReady = false
    @ObservationIgnored private let artworkCache: NeteaseArtworkCache
    @ObservationIgnored private let cacheIO = NeteaseCacheIO()
    @ObservationIgnored private let pageCache: NeteasePageCache
    @ObservationIgnored private var artworkTasks: [URL: Task<Void, Never>] = [:]
    @ObservationIgnored private let legacyReader = ArtistLegacyReader()
    @ObservationIgnored private var restoringPages: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var restoredPages: Set<String> = []
    @ObservationIgnored private var saveTasks: [String: Task<Void, Never>] = [:]
    func cachedSong(_ id: Int64) -> NeteaseMusicSong? { resolvedSongs[id] }
    var cachedSongs: [NeteaseMusicSong] { resolvedSongs.values.sorted { $0.id < $1.id } }
    func restoreCachedSongs(ids: Set<Int64>) async -> [NeteaseMusicSong] {
        guard isReady, !ids.isEmpty, !Task.isCancelled else { return [] }
        let token = revision, owner = scope, legacyURL = cacheURL
        var songs = ids.reduce(into: [Int64: NeteaseMusicSong]()) { $0[$1] = resolvedSongs[$1] }
        let missing = ids.subtracting(songs.keys)
        if !missing.isEmpty {
            let restored = await legacyReader.songs(ids: missing, pageCache: pageCache, scope: owner, legacyURL: legacyURL)
            guard token == revision, isReady, !Task.isCancelled else { return [] }
            for song in restored { songs[song.id] = resolvedSongs[song.id] ?? song }
        }
        return ids.sorted().compactMap { resolvedSongs[$0] ?? songs[$0] }
    }
    init(client: NeteaseMusicClient = NeteaseMusicClient(), directory: URL? = nil,
         artworkSession: URLSession? = nil) {
        self.client = client
        let directory = directory ?? URL.cachesDirectory.appendingPathComponent("NeteaseArtists")
        self.directory = directory
        pageCache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        artworkCache = artworkSession.map { NeteaseArtworkCache(directory: directory.appendingPathComponent("Artwork"), session: $0) } ?? .shared
    }
    private var scope: String { userID.map(String.init) ?? "public" }
    private var cacheURL: URL { directory.appendingPathComponent("\(scope).json") }
    func activate(_ session: NeteaseSavedSession?, refresh: Bool = true) async {
        guard !Task.isCancelled else { return }
        if !isReady || userID != session?.profile.userID || credential != session?.credential {
            await invalidate()
            guard !Task.isCancelled else { return }
            let token = revision
            userID = session?.profile.userID; credential = session?.credential
            observeArtworkEvictions(token: token)
            let subscriptions = try? await pageCache.load(Subscriptions.self, scope: scope, key: "subscriptions")
            let legacy = subscriptions == nil ? await cacheIO.load(LegacySubscriptions.self, from: cacheURL) : nil
            guard token == revision, !Task.isCancelled else { return }
            if let subscriptions {
                subscribedArtists = subscriptions.artists; subscribedAlbums = subscriptions.albums
                albumAdditions = subscriptions.albumAdditions ?? AlbumLibraryAdditions(baselineRecorded: true)
                refreshedAt.merge(subscriptions.refreshedAt) { _, new in new }
            } else if let legacy {
                subscribedArtists = legacy.artists; subscribedAlbums = legacy.collected
                albumAdditions = AlbumLibraryAdditions(baselineRecorded: !subscribedAlbums.isEmpty)
            }
            isReady = true
            publish(.reset)
            if legacy != nil { save("subscriptions") }
            requestArtwork(subscribedArtists.prefix(6).compactMap(\.artworkURL) + subscribedAlbums.prefix(6).compactMap(\.artworkURL))
        }
        if refresh { await self.refresh() }
    }
    deinit { if let artworkObserver { NotificationCenter.default.removeObserver(artworkObserver) } }
    private func observeArtworkEvictions(token: UUID) {
        if let artworkObserver { NotificationCenter.default.removeObserver(artworkObserver) }
        artworkObserver = NotificationCenter.default.addObserver(forName: NeteaseArtworkCache.didEvictArtwork, object: artworkCache, queue: .main) { [weak self] notification in
            guard let payload = NeteaseArtworkCache.eviction(in: notification) else { return }
            MainActor.assumeIsolated {
                guard let self, self.isReady, self.revision == token, self.scope == payload.scope else { return }
                if !payload.urls.isEmpty { self.onArtworkChange?(payload.urls) }
            }
        }
    }
    func invalidate() async {
        if let artworkObserver { NotificationCenter.default.removeObserver(artworkObserver) }
        artworkObserver = nil
        revision = UUID(); credential = nil; userID = nil; isReady = false
        let pending = Array(tasks.values) + Array(artworkTasks.values) + Array(saveTasks.values) + Array(restoringPages.values)
        tasks.removeAll(); artworkTasks.removeAll(); saveTasks.removeAll(); restoringPages.removeAll(); restoredPages.removeAll()
        resolvedSongs = [:]; songSources = [:]; songOwners = [:]; biographies = [:]; refreshedAt = [:]; legacyArtwork = [:]
        details = [:]; releases = [:]; similar = [:]; albums = [:]; subscribedArtists = []; subscribedAlbums = []; albumAdditions = AlbumLibraryAdditions(); errors = [:]
        publish(.reset)
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
    }
    private func publish(_ change: Change) { onContentChange?(change); onChange?() }
    private func fresh(_ key: String) -> Bool {
        errors[key] == nil && refreshedAt[key].map { Date().timeIntervalSince($0) < 300 } == true
    }
    private func run(_ key: String, token: UUID, operation: @escaping @MainActor () async throws -> Change?) async {
        guard token == revision, isReady, !Task.isCancelled else { return }
        if let task = tasks[key] { await task.value; return }
        let task = Task { [self] in
            do {
                let change = try await operation()
                try check(token)
                let hadError = errors.removeValue(forKey: key) != nil
                refreshedAt[key] = Date()
                save(key)
                PerformanceDiagnostics.event("NetworkContentReady")
                if let change { publish(change) }
                else if hadError { publish(.error(key)) }
            } catch is CancellationError { }
            catch {
                guard token == revision else { return }
                let message = error.localizedDescription
                if errors[key] != message { errors[key] = message; publish(.error(key)) }
            }
        }
        tasks[key] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if token == revision { tasks.removeValue(forKey: key) }
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        if revision != token { throw CancellationError() }
    }
    private func mergeSongs(_ songs: [NeteaseMusicSong], source: String) {
        let previous = Set(songSources[source]?.keys.map { $0 } ?? [])
        let values = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        songSources[source] = values
        for id in previous.subtracting(values.keys) {
            songOwners[id]?.remove(source)
            if let remaining = songOwners[id]?.sorted().first { resolvedSongs[id] = songSources[remaining]?[id] }
            else { songOwners[id] = nil; resolvedSongs[id] = nil }
        }
        for song in songs { songOwners[song.id, default: []].insert(source); resolvedSongs[song.id] = song }
    }
    func refresh(force: Bool = false) async {
        guard let credential else { return }
        let token = revision
        async let artists: Void = refreshArtists(credential, token: token, force: force)
        async let albums: Void = refreshAlbums(credential, token: token, force: force)
        _ = await (artists, albums)
    }
    private func refreshArtists(_ credential: NeteaseCredential, token: UUID, force: Bool) async {
        guard force || !fresh("subscriptions:artists") else { return }
        await run("subscriptions:artists", token: token) { [self] in
            let value = try await client.subscribedArtists(credential: credential)
            try check(token)
            let ids = Self.changedArtistIDs(subscribedArtists, value)
            let changed = subscribedArtists != value
            if changed { subscribedArtists = value; onLibraryChange?() }
            cacheArtwork(value.prefix(6).compactMap(\.artworkURL), token: token)
            return changed ? .subscribedArtists(ids) : nil
        }
    }
    private func refreshAlbums(_ credential: NeteaseCredential, token: UUID, force: Bool) async {
        guard force || !fresh("subscriptions:albums") else { return }
        await run("subscriptions:albums", token: token) { [self] in
            let value = try await client.subscribedAlbums(credential: credential)
            try check(token)
            let ids = Self.changedAlbumIDs(subscribedAlbums, value)
            let previous = subscribedAlbums.map(\.id)
            albumAdditions.observe(previous: previous, current: value.map(\.id), now: Date())
            let changed = !Self.sameAlbums(subscribedAlbums, value)
            if changed { subscribedAlbums = value; onLibraryChange?() }
            cacheArtwork(value.prefix(6).compactMap(\.artworkURL), token: token)
            return changed ? .subscribedAlbums(ids) : nil
        }
    }
    private func restoreArtistPage(id: Int64) async {
        let key = "artist:\(id)", token = revision, owner = scope, legacyURL = cacheURL
        guard isReady, !Task.isCancelled, !restoredPages.contains(key) else { return }
        if let task = restoringPages[key] {
            await task.value
            if token == revision, !Task.isCancelled, !restoredPages.contains(key) { await restoreArtistPage(id: id) }
            return
        }
        let task = Task { [self] in
            defer { if token == revision { restoringPages[key] = nil } }
            let cached = try? await pageCache.load(ArtistPage.self, scope: owner, key: key)
            let legacy = cached == nil ? await legacyReader.artist(id: id, from: legacyURL) : nil
            guard token == revision, !Task.isCancelled else { return }
            restoredPages.insert(key)
            guard let page = cached ?? legacy?.0 else { return }
            details[id] = page.detail; releases[id] = page.releases; similar[id] = page.similar
            biographies[id] = page.biography
            refreshedAt.merge(page.refreshedAt) { _, new in new }
            if let detail = page.detail { mergeSongs(detail.songs, source: key) }
            if let artwork = legacy?.1 { legacyArtwork.merge(artwork) { _, new in new } }
            publish(.artist(id))
            let urls = [page.detail?.artist.artworkURL].compactMap { $0 }
                + (page.detail?.songs.prefix(8).compactMap(\.artworkURL) ?? [])
                + (page.releases?.prefix(6).compactMap(\.artworkURL) ?? [])
                + (page.similar?.prefix(6).compactMap(\.artworkURL) ?? [])
            requestArtwork(urls)
        }
        restoringPages[key] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func restoreAlbumPage(id: Int64) async {
        let key = "album:\(id)", token = revision, owner = scope, legacyURL = cacheURL
        guard isReady, !Task.isCancelled, !restoredPages.contains(key) else { return }
        if let task = restoringPages[key] {
            await task.value
            if token == revision, !Task.isCancelled, !restoredPages.contains(key) { await restoreAlbumPage(id: id) }
            return
        }
        let task = Task { [self] in
            defer { if token == revision { restoringPages[key] = nil } }
            let cached = try? await pageCache.load(AlbumPage.self, scope: owner, key: key)
            let legacy = cached == nil ? await legacyReader.album(id: id, from: legacyURL) : nil
            guard token == revision, !Task.isCancelled else { return }
            restoredPages.insert(key)
            guard let page = cached ?? legacy?.0 else { return }
            albums[id] = page.detail; refreshedAt[key] = page.refreshedAt
            mergeSongs(page.detail.songs, source: key)
            if let artwork = legacy?.1 { legacyArtwork.merge(artwork) { _, new in new } }
            publish(.album(id))
            requestArtwork([page.detail.album.artworkURL].compactMap { $0 } + page.detail.songs.prefix(8).compactMap(\.artworkURL))
        }
        restoringPages[key] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    func prepareArtistPlayback(id: Int64) async -> Bool {
        let token = revision
        await restoreArtistPage(id: id)
        guard token == revision, isReady, !Task.isCancelled else { return false }
        if details[id] == nil { await loadArtistSongs(id: id) }
        return token == revision && !Task.isCancelled && details[id] != nil
    }
    func prepareAlbumPlayback(id: Int64) async -> Bool {
        let token = revision
        await restoreAlbumPage(id: id)
        guard token == revision, isReady, !Task.isCancelled else { return false }
        if albums[id] == nil { await loadAlbum(id: id) }
        return token == revision && !Task.isCancelled && albums[id] != nil
    }
    func loadArtistSongs(id: Int64, force: Bool = false) async {
        let requestedSession = revision
        await restoreArtistPage(id: id)
        guard requestedSession == revision, !Task.isCancelled else { return }
        guard force || !fresh("artist:\(id)") else { return }
        let token = revision, credential = credential
        await run("artist:\(id)", token: token) { [self] in
            let value = try await client.artistDetail(id: id, credential: credential)
            try check(token)
            let detail = NeteaseArtistDetail(artist: value.artist, biography: biographies[id] ?? value.biography, songs: value.songs)
            let previous = details[id]
            let changed = previous?.artist != detail.artist || previous?.biography != detail.biography || previous?.songs != detail.songs
            if changed { details[id] = detail; mergeSongs(detail.songs, source: "artist:\(id)") }
            cacheArtwork([detail.artist.artworkURL].compactMap { $0 } + detail.songs.prefix(8).compactMap(\.artworkURL), token: token)
            return changed ? .artist(id) : nil
        }
    }
    func loadArtist(id: Int64, force: Bool = false) async {
        let requestedSession = revision
        await restoreArtistPage(id: id)
        guard requestedSession == revision, !Task.isCancelled else { return }
        async let profile: Void = loadArtistSongs(id: id, force: force)
        async let biography: Void = loadBiography(id: id, force: force)
        async let works: Void = loadReleases(id: id, force: force)
        async let related: Void = loadSimilar(id: id, force: force)
        _ = await (profile, biography, works, related)
    }
    private func loadBiography(id: Int64, force: Bool) async {
        let key = "biography:\(id)"
        guard force || !fresh(key) else { return }
        let token = revision, credential = credential
        await run(key, token: token) { [self] in
            let text = try await client.artistBiography(id: id, credential: credential)
            try check(token); biographies[id] = text
            guard let detail = details[id], detail.biography != text else { return nil }
            details[id] = .init(artist: detail.artist, biography: text, songs: detail.songs)
            return .artist(id)
        }
    }
    private func loadReleases(id: Int64, force: Bool) async {
        let key = "releases:\(id)"
        guard force || !fresh(key) else { return }
        let token = revision, credential = credential
        await run(key, token: token) { [self] in
            let value = try await client.artistAlbums(id: id, credential: credential)
            try check(token)
            let changed = releases[id].map { !Self.sameAlbums($0, value) } ?? true
            if changed { releases[id] = value }
            cacheArtwork(value.prefix(6).compactMap(\.artworkURL), token: token)
            return changed ? .artist(id) : nil
        }
    }
    private func loadSimilar(id: Int64, force: Bool) async {
        let key = "similar:\(id)"
        guard force || !fresh(key) else { return }
        let token = revision, credential = credential
        await run(key, token: token) { [self] in
            let value = try await client.similarArtists(id: id, credential: credential)
            try check(token)
            let changed = similar[id] != value
            if changed { similar[id] = value }
            cacheArtwork(value.prefix(6).compactMap(\.artworkURL), token: token)
            return changed ? .artist(id) : nil
        }
    }
    func song(id: Int64) async throws -> NeteaseMusicSong {
        if let song = resolvedSongs[id], song.albumID != nil, song.artists?.isEmpty == false { return song }
        let token = revision, credential = credential
        await run("song:\(id)", token: token) { [self] in
            let value = try await client.songDetail(id: id, credential: credential)
            try check(token); mergeSongs([value], source: "song:\(id)")
            return .song(id)
        }
        try check(token)
        guard let result = resolvedSongs[id] else { throw NeteaseAccountError.invalidResponse }
        return result
    }
    func loadAlbum(id: Int64, force: Bool = false) async {
        let requestedSession = revision
        await restoreAlbumPage(id: id)
        guard requestedSession == revision, !Task.isCancelled else { return }
        guard force || !fresh("album:\(id)") else { return }
        let token = revision, credential = credential
        await run("album:\(id)", token: token) { [self] in
            let value = try await client.albumDetail(id: id, credential: credential)
            try check(token)
            let previous = albums[id]
            let changed = previous.map { !Self.sameAlbums([$0.album], [value.album]) || $0.songs != value.songs } ?? true
            if changed { albums[id] = value; mergeSongs(value.songs, source: "album:\(id)") }
            cacheArtwork([value.album.artworkURL].compactMap { $0 } + value.songs.prefix(8).compactMap(\.artworkURL), token: token)
            return changed ? .album(id) : nil
        }
    }
    func setArtistSubscribed(id: Int64, subscribed: Bool) async throws { try await setSubscription(id: id, subscribed: subscribed, artist: true) }
    func setAlbumSubscribed(id: Int64, subscribed: Bool) async throws { try await setSubscription(id: id, subscribed: subscribed, artist: false) }
    private func setSubscription(id: Int64, subscribed: Bool, artist: Bool) async throws {
        guard let credential else { throw NeteaseAccountError.authenticationRequired }
        let token = revision, key = "write:\(artist):\(id)"
        await run(key, token: token) { [self] in
            var failure: Error?
            do {
                if artist { try await client.setArtistSubscribed(id: id, subscribed: subscribed, credential: credential) }
                else { try await client.setAlbumSubscribed(id: id, subscribed: subscribed, credential: credential) }
            } catch let error as URLError where error.code == .notConnectedToInternet { throw error }
            catch { failure = error }
            try check(token)
            let change: Change
            let confirmed: Bool
            if artist {
                let value = try await client.subscribedArtists(credential: credential)
                try check(token)
                let ids = Self.changedArtistIDs(subscribedArtists, value)
                subscribedArtists = value; confirmed = value.contains { $0.id == id } == subscribed
                change = .subscribedArtists(ids)
            } else {
                let previous = subscribedAlbums.map(\.id)
                if subscribed { albumAdditions.stamp(id, at: Date()) }
                let value = try await client.subscribedAlbums(credential: credential)
                try check(token)
                albumAdditions.observe(previous: previous, current: value.map(\.id), now: Date())
                let ids = Self.changedAlbumIDs(subscribedAlbums, value)
                subscribedAlbums = value; confirmed = value.contains { $0.id == id } == subscribed
                change = .subscribedAlbums(ids)
            }
            save("subscriptions")
            onLibraryChange?()
            if !confirmed {
                publish(change)
                throw failure ?? NeteaseAccountError.invalidResponse
            }
            return change
        }
        try check(token)
        if let error = errors[key] { throw NSError(domain: "NeteaseArtist", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }
    func cachedArtworkURL(_ remote: URL) -> URL? { artworkCache.cachedURL(for: remote, scope: scope) ?? legacyArtwork[remote.absoluteString] }
    func cachedArtworkFile(_ remote: URL) async -> URL? {
        guard isReady, !Task.isCancelled else { return nil }
        if let cached = cachedArtworkURL(remote) { return cached }
        let token = revision, owner = scope
        let file = await artworkCache.cachedFileURL(for: remote, scope: owner)
        guard isReady, revision == token, scope == owner, !Task.isCancelled else { return nil }
        return file
    }
    func requestArtwork(_ urls: [URL]) {
        guard isReady, !Task.isCancelled else { return }
        let cached = Set(urls.filter { cachedArtworkURL($0) != nil })
        if !cached.isEmpty { onArtworkChange?(cached) }
        cacheArtwork(urls, token: revision)
    }
    private func cacheArtwork(_ urls: [URL], token: UUID) {
        guard token == revision, !Task.isCancelled else { return }
        let owner = scope
        for remote in Set(urls) where remote.scheme == "https" && cachedArtworkURL(remote) == nil && artworkTasks[remote] == nil {
            artworkTasks[remote] = Task { [self] in
                defer { if token == revision { artworkTasks[remote] = nil } }
                do {
                    _ = try await artworkCache.imageURL(for: remote, scope: owner)
                    try check(token)
                    PerformanceDiagnostics.event("ArtworkReady")
                    onArtworkChange?([remote])
                } catch { }
            }
        }
    }
    private struct LegacySubscriptions: Decodable, Sendable {
        let artists: [NeteaseArtistReference]
        let collected: [NeteaseArtistAlbum]
    }
    fileprivate struct ArtistPage: Codable, Sendable {
        let detail: NeteaseArtistDetail?
        let biography: String?
        let releases: [NeteaseArtistAlbum]?
        let similar: [NeteaseArtistReference]?
        let refreshedAt: [String: Date]
    }
    fileprivate struct AlbumPage: Codable, Sendable { let detail: NeteaseArtistAlbumDetail; let refreshedAt: Date? }
    func albumAddedDate(_ id: Int64) -> Date? { albumAdditions.date(id) }

    private struct Subscriptions: Codable, Sendable {
        let artists: [NeteaseArtistReference]; let albums: [NeteaseArtistAlbum]; let refreshedAt: [String: Date]
        var albumAdditions: AlbumLibraryAdditions? = nil
    }
    private func save(_ resource: String) {
        let parts = resource.split(separator: ":")
        if ["artist", "biography", "releases", "similar"].contains(parts.first.map(String.init) ?? ""), let id = parts.last.flatMap({ Int64($0) }) {
            let keys = ["artist:\(id)", "biography:\(id)", "releases:\(id)", "similar:\(id)"]
            save(ArtistPage(detail: details[id], biography: biographies[id], releases: releases[id], similar: similar[id],
                            refreshedAt: keys.reduce(into: [:]) { result, key in result[key] = refreshedAt[key] }), key: "artist:\(id)")
        } else if resource.hasPrefix("album:"), let id = parts.last.flatMap({ Int64($0) }), let detail = albums[id] {
            save(AlbumPage(detail: detail, refreshedAt: refreshedAt[resource]), key: resource)
        } else if resource.hasPrefix("subscriptions") || resource.hasPrefix("write:") {
            save(Subscriptions(artists: subscribedArtists, albums: subscribedAlbums,
                               refreshedAt: refreshedAt.filter { $0.key.hasPrefix("subscriptions:") }, albumAdditions: albumAdditions), key: "subscriptions")
        }
    }
    private func save<Value: Encodable & Sendable>(_ value: Value, key: String) {
        let owner = scope, token = revision, previous = saveTasks[key]
        previous?.cancel()
        saveTasks[key] = Task { [pageCache] in
            await previous?.value
            guard !Task.isCancelled, token == revision else { return }
            do { try await pageCache.save(value, scope: owner, key: key) }
            catch is CancellationError { }
            catch { if token == revision { errors["cache"] = error.localizedDescription } }
        }
    }
    private static func changedArtistIDs(_ old: [NeteaseArtistReference], _ new: [NeteaseArtistReference]) -> Set<Int64> {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(previous.keys).union(current.keys).filter { previous[$0] != current[$0] }
    }
    private static func changedAlbumIDs(_ old: [NeteaseArtistAlbum], _ new: [NeteaseArtistAlbum]) -> Set<Int64> {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let current = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(previous.keys).union(current.keys).filter { id in
            guard let old = previous[id], let new = current[id] else { return true }
            return !sameAlbums([old], [new])
        }
    }
    private static func sameAlbums(_ lhs: [NeteaseArtistAlbum], _ rhs: [NeteaseArtistAlbum]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.id == $1.id && $0.title == $1.title && $0.artist == $1.artist && $0.artworkURL == $1.artworkURL
                && $0.publishTime == $1.publishTime && $0.type == $1.type && $0.trackCount == $1.trackCount
        }
    }
}

/// Cache reads keep unopened routes out of the observable store and preserve legacy snapshots.
private actor ArtistLegacyReader {
    func songs(ids: Set<Int64>, pageCache: NeteasePageCache, scope: String, legacyURL: URL) async -> [NeteaseMusicSong] {
        guard !ids.isEmpty, !Task.isCancelled else { return [] }
        var missing = ids
        var result: [NeteaseMusicSong] = []
        let artists = (try? await pageCache.entries(NeteaseArtistStore.ArtistPage.self, scope: scope, prefix: "artist:")) ?? [:]
        guard !Task.isCancelled else { return [] }
        for key in artists.keys.sorted() {
            for song in artists[key]?.detail?.songs ?? [] where missing.remove(song.id) != nil { result.append(song) }
            if missing.isEmpty { return result }
        }
        let albums = (try? await pageCache.entries(NeteaseArtistStore.AlbumPage.self, scope: scope, prefix: "album:")) ?? [:]
        guard !Task.isCancelled else { return [] }
        for key in albums.keys.sorted() {
            for song in albums[key]?.detail.songs ?? [] where missing.remove(song.id) != nil { result.append(song) }
            if missing.isEmpty { return result }
        }
        guard let object = object(at: legacyURL), !Task.isCancelled else { return result }
        for field in ["details", "albums"] {
            let values: [Any]
            if let keyed = object[field] as? [String: Any] { values = keyed.keys.sorted().compactMap { keyed[$0] } }
            else if let pairs = object[field] as? [Any] { values = stride(from: 1, to: pairs.count, by: 2).map { pairs[$0] } }
            else { continue }
            for value in values {
                guard let songs = (value as? [String: Any])?["songs"] as? [[String: Any]] else { continue }
                for raw in songs {
                    guard !Task.isCancelled else { return [] }
                    guard let id = (raw["id"] as? NSNumber)?.int64Value, missing.contains(id),
                          let song = decode(NeteaseMusicSong.self, value: raw) else { continue }
                    missing.remove(id); result.append(song)
                    if missing.isEmpty { return result }
                }
            }
        }
        return result
    }
    func artist(id: Int64, from url: URL) -> (NeteaseArtistStore.ArtistPage, [String: URL])? {
        guard let object = object(at: url), !Task.isCancelled else { return nil }
        let detail = decode(NeteaseArtistDetail.self, value: value(in: object, field: "details", id: id))
        let releases = decode([NeteaseArtistAlbum].self, value: value(in: object, field: "releases", id: id))
        let similar = decode([NeteaseArtistReference].self, value: value(in: object, field: "similar", id: id))
        guard detail != nil || releases != nil || similar != nil else { return nil }
        let page = NeteaseArtistStore.ArtistPage(detail: detail, biography: detail?.biography, releases: releases, similar: similar, refreshedAt: [:])
        let urls = [detail?.artist.artworkURL].compactMap { $0 } + (detail?.songs.compactMap(\.artworkURL) ?? [])
            + (releases?.compactMap(\.artworkURL) ?? []) + (similar?.compactMap(\.artworkURL) ?? [])
        return (page, artwork(in: object, urls: urls, directory: url.deletingLastPathComponent()))
    }
    func album(id: Int64, from url: URL) -> (NeteaseArtistStore.AlbumPage, [String: URL])? {
        guard let object = object(at: url), !Task.isCancelled,
              let detail = decode(NeteaseArtistAlbumDetail.self, value: value(in: object, field: "albums", id: id)) else { return nil }
        let urls = [detail.album.artworkURL].compactMap { $0 } + detail.songs.compactMap(\.artworkURL)
        return (.init(detail: detail, refreshedAt: nil), artwork(in: object, urls: urls, directory: url.deletingLastPathComponent()))
    }
    private func object(at url: URL) -> [String: Any]? {
        guard !Task.isCancelled, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private func value(in object: [String: Any], field: String, id: Int64) -> Any? {
        if let values = object[field] as? [String: Any] { return values[String(id)] }
        guard let pairs = object[field] as? [Any] else { return nil }
        for index in stride(from: 0, to: pairs.count - 1, by: 2) where (pairs[index] as? NSNumber)?.int64Value == id {
            return pairs[index + 1]
        }
        return nil
    }
    private func decode<Value: Decodable>(_ type: Value.Type, value: Any?) -> Value? {
        guard let value, let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private func artwork(in object: [String: Any], urls: [URL], directory: URL) -> [String: URL] {
        guard let files = object["artwork"] as? [String: String] else { return [:] }
        var result: [String: URL] = [:]
        for remote in urls {
            guard let stored = files[remote.absoluteString], let oldURL = URL(string: stored) else { continue }
            let file = directory.appendingPathComponent(oldURL.lastPathComponent)
            if FileManager.default.fileExists(atPath: file.path) { result[remote.absoluteString] = file }
        }
        return result
    }
}
