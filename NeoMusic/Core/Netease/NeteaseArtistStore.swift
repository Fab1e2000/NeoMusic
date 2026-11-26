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
    @ObservationIgnored var onContentChange: ((Change) -> Void)?
    @ObservationIgnored var onArtworkFailure: ((URL) -> Void)?
    @ObservationIgnored var onArtworkChange: ((Set<URL>) -> Void)?
    var sessionRevision: UUID { revision }
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored let sessionScope = NeteaseSessionScope()
    private var revision: UUID { sessionScope.revision }
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var resolvedSongs: [Int64: NeteaseMusicSong] = [:]
    @ObservationIgnored private var songSources: [String: [Int64: NeteaseMusicSong]] = [:]
    @ObservationIgnored private var songOwners: [Int64: Set<String>] = [:]
    @ObservationIgnored private var biographies: [Int64: String] = [:]
    @ObservationIgnored private var refreshedAt: [String: Date] = [:]
    private(set) var isReady = false
    @ObservationIgnored private let artworkLoader: ScopedArtworkLoader
    @ObservationIgnored private let cacheWriter: KeyedPageCacheWriter
    private var artworkCache: NeteaseArtworkCache { artworkLoader.cache }
    @ObservationIgnored private let pageCache: NeteasePageCache
    @ObservationIgnored private let portraitCache: NeteasePageCache
    private var portraitMetadata: [Int64: PortraitMetadata] = [:]
    private var portraitFiles: [Int64: URL] = [:]
    @ObservationIgnored private var portraitWaiters: [Int64: [UUID: CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored private var portraitQueue: [Int64] = []
    @ObservationIgnored private var portraitTasks: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var portraitRetryAfter: [Int64: Date] = [:]
    @ObservationIgnored private var portraitMetadataRetryAfter: Date?
    @ObservationIgnored private var restoringPages: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var restoredPages: Set<String> = []
    func cachedSong(_ id: Int64) -> NeteaseMusicSong? { resolvedSongs[id] }
    var cachedSongs: [NeteaseMusicSong] { resolvedSongs.values.sorted { $0.id < $1.id } }
    func restoreCachedSongs(ids: Set<Int64>) async -> [NeteaseMusicSong] {
        guard isReady, !ids.isEmpty, !Task.isCancelled else { return [] }
        let token = revision, owner = scope
        var songs = ids.reduce(into: [Int64: NeteaseMusicSong]()) { $0[$1] = resolvedSongs[$1] }
        var missing = ids.subtracting(songs.keys)
        if !missing.isEmpty {
            let artists = (try? await pageCache.entries(ArtistPage.self, scope: owner, prefix: "artist:")) ?? [:]
            guard token == revision, isReady, !Task.isCancelled else { return [] }
            for key in artists.keys.sorted() {
                for song in artists[key]?.detail?.songs ?? [] where missing.remove(song.id) != nil {
                    songs[song.id] = resolvedSongs[song.id] ?? song
                }
                if missing.isEmpty { break }
            }
        }
        if !missing.isEmpty {
            let albums = (try? await pageCache.entries(AlbumPage.self, scope: owner, prefix: "album:")) ?? [:]
            guard token == revision, isReady, !Task.isCancelled else { return [] }
            for key in albums.keys.sorted() {
                for song in albums[key]?.detail.songs ?? [] where missing.remove(song.id) != nil {
                    songs[song.id] = resolvedSongs[song.id] ?? song
                }
                if missing.isEmpty { break }
            }
        }
        return ids.sorted().compactMap { resolvedSongs[$0] ?? songs[$0] }
    }
    init(client: NeteaseMusicClient = NeteaseMusicClient(), directory: URL? = nil,
         artworkSession: URLSession? = nil) {
        self.client = client
        let directory = directory ?? AppStoragePaths.neteaseArtistsCache
        self.directory = directory
        pageCache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        portraitCache = NeteasePageCache(directory: directory.appendingPathComponent("Portraits"))
        let artwork = artworkSession.map { NeteaseArtworkCache(directory: directory.appendingPathComponent("Artwork"), session: $0) } ?? .shared
        artworkLoader = ScopedArtworkLoader(cache: artwork, session: sessionScope)
        cacheWriter = KeyedPageCacheWriter(cache: pageCache, session: sessionScope)
        artworkLoader.scope = { [weak self] in self?.scope }
        artworkLoader.isReady = { [weak self] in self?.isReady == true }
        artworkLoader.onChange = { [weak self] in self?.notifyArtworkChange($0) }
        artworkLoader.onFailure = { [weak self] in self?.onArtworkFailure?($0) }
    }
    private var scope: String { userID.map(String.init) ?? "public" }
    func activate(_ session: NeteaseSavedSession?, refresh: Bool = true) async {
        guard !Task.isCancelled else { return }
        if !isReady || userID != session?.profile.userID || credential != session?.credential {
            let token = await resetSession()
            guard sessionScope.isCurrent(token) else { return }
            userID = session?.profile.userID; credential = session?.credential
            let subscriptions = try? await pageCache.load(Subscriptions.self, scope: scope, key: "subscriptions")
            guard token == revision, !Task.isCancelled else { return }
            if let subscriptions {
                subscribedArtists = subscriptions.artists; subscribedAlbums = subscriptions.albums
                albumAdditions = subscriptions.albumAdditions ?? AlbumLibraryAdditions(baselineRecorded: true)
                refreshedAt.merge(subscriptions.refreshedAt) { _, new in new }
                if subscriptions.albums.contains(where: { $0.artists == nil }) {
                    refreshedAt.removeValue(forKey: "subscriptions:albums")
                }
            }
            isReady = true
            publish(.reset)
        }
        if refresh {
            requestArtwork(subscribedArtists.prefix(6).compactMap(\.artworkURL) + subscribedAlbums.prefix(6).compactMap(\.artworkURL))
            await self.refresh()
        }
    }
    func invalidate() async { _ = await resetSession() }

    private func resetSession() async -> UUID {
        let token = sessionScope.advance()
        credential = nil; userID = nil; isReady = false
        var pending = SessionTaskBag()
        artworkLoader.takePending(into: &pending)
        cacheWriter.takePending(into: &pending)
        let consumers = portraitWaiters
        portraitWaiters.removeAll(); portraitQueue.removeAll(); portraitTasks.removeAll()
        portraitMetadata.removeAll(); portraitFiles.removeAll(); portraitRetryAfter.removeAll()
        portraitMetadataRetryAfter = nil
        for waiters in consumers.values { for waiter in waiters.values { waiter.resume() } }
        tasks.removeAll(); restoringPages.removeAll(); restoredPages.removeAll()
        resolvedSongs = [:]; songSources = [:]; songOwners = [:]; biographies = [:]; refreshedAt = [:]
        details = [:]; releases = [:]; similar = [:]; albums = [:]; subscribedArtists = []; subscribedAlbums = []; albumAdditions = AlbumLibraryAdditions(); errors = [:]
        publish(.reset)
        await sessionScope.cancelAndDrain(pending).value
        return token
    }
    private func publish(_ change: Change) { onContentChange?(change); onChange?() }
    private func fresh(_ key: String) -> Bool {
        errors[key] == nil && refreshedAt[key].map { Date().timeIntervalSince($0) < 300 } == true
    }
    private func run(_ key: String, token: UUID, operation: @escaping @MainActor () async throws -> Change?) async {
        guard token == revision, isReady, !Task.isCancelled else { return }
        if let task = tasks[key] { await task.value; return }
        let task = sessionScope.task { [self] in
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
                sessionScope.report(error, revision: token, signedIn: credential != nil)
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
            if changed { subscribedArtists = value }
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
            if changed { subscribedAlbums = value }
            cacheArtwork(value.prefix(6).compactMap(\.artworkURL), token: token)
            return changed ? .subscribedAlbums(ids) : nil
        }
    }
    private func restoreArtistPage(id: Int64) async {
        let key = "artist:\(id)", token = revision, owner = scope
        guard isReady, !Task.isCancelled, !restoredPages.contains(key) else { return }
        if let task = restoringPages[key] {
            await task.value
            if token == revision, !Task.isCancelled, !restoredPages.contains(key) { await restoreArtistPage(id: id) }
            return
        }
        let task = sessionScope.task { [self] in
            defer { if token == revision { restoringPages[key] = nil } }
            let cached = try? await pageCache.load(ArtistPage.self, scope: owner, key: key)
            guard token == revision, !Task.isCancelled else { return }
            restoredPages.insert(key)
            guard let page = cached else { return }
            details[id] = page.detail; releases[id] = page.releases; similar[id] = page.similar
            biographies[id] = page.biography
            refreshedAt.merge(page.refreshedAt) { _, new in new }
            if let detail = page.detail { mergeSongs(detail.songs, source: key) }
            publish(.artist(id))
            let urls = [page.detail?.artist.artworkURL].compactMap { $0 }
                + (page.detail?.songs.prefix(NeteaseArtworkPrefetch.artistSongs).compactMap(\.artworkURL) ?? [])
                + (page.releases?.prefix(NeteaseArtworkPrefetch.shelfCards).compactMap(\.artworkURL) ?? [])
            requestArtwork(urls)
        }
        restoringPages[key] = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func restoreAlbumPage(id: Int64) async {
        let key = "album:\(id)", token = revision, owner = scope
        guard isReady, !Task.isCancelled, !restoredPages.contains(key) else { return }
        if let task = restoringPages[key] {
            await task.value
            if token == revision, !Task.isCancelled, !restoredPages.contains(key) { await restoreAlbumPage(id: id) }
            return
        }
        let task = sessionScope.task { [self] in
            defer { if token == revision { restoringPages[key] = nil } }
            let cached = try? await pageCache.load(AlbumPage.self, scope: owner, key: key)
            guard token == revision, !Task.isCancelled else { return }
            restoredPages.insert(key)
            guard let page = cached else { return }
            albums[id] = page.detail
            refreshedAt[key] = page.detail.songs.contains { $0.trackNumber == nil || $0.discNumber == nil } ? nil : page.refreshedAt
            mergeSongs(page.detail.songs, source: key)
            publish(.album(id))
            requestArtwork([page.detail.album.artworkURL].compactMap { $0 } + page.detail.songs.prefix(NeteaseArtworkPrefetch.detailSongs).compactMap(\.artworkURL))
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
            cacheArtwork([detail.artist.artworkURL].compactMap { $0 } + detail.songs.prefix(NeteaseArtworkPrefetch.artistSongs).compactMap(\.artworkURL), token: token)
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
            cacheArtwork(value.prefix(NeteaseArtworkPrefetch.shelfCards).compactMap(\.artworkURL), token: token)
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
            cacheArtwork([value.album.artworkURL].compactMap { $0 } + value.songs.prefix(NeteaseArtworkPrefetch.detailSongs).compactMap(\.artworkURL), token: token)
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
            catch {
                sessionScope.report(error, revision: token, signedIn: true)
                failure = error
            }
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
            if !confirmed {
                publish(change)
                throw failure ?? NeteaseAccountError.invalidResponse
            }
            return change
        }
        try check(token)
        if let error = errors[key] { throw NSError(domain: "NeteaseArtist", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
    }
    func cachedArtworkURL(_ remote: URL) -> URL? { artworkLoader.cachedURL(remote) }
    func cachedArtworkFile(_ remote: URL) async -> URL? { await artworkLoader.cachedFile(remote) }
    func requestArtwork(_ urls: [URL]) { artworkLoader.request(urls) }
    private func cacheArtwork(_ urls: [URL], token: UUID) {
        guard sessionScope.isCurrent(token) else { return }
        artworkLoader.request(urls, notifyCached: false)
    }
    private struct PortraitMetadata: Codable, Sendable {
        let url: URL?
        let checkedAt: Date
    }

    func knownPortraitURL(_ id: Int64) -> URL? {
        let subscribed = subscribedArtists.first { $0.id == id }?.artworkURL
        let detail = details[id]?.artist.artworkURL
        let albumCredit = subscribedAlbums.lazy.compactMap { album in
            album.artists?.first { $0.id == id }?.artworkURL
        }.first
        return [subscribed, detail, albumCredit].compactMap { $0 }.first(where: Self.isArtistPortrait)
    }

    private static func isArtistPortrait(_ url: URL) -> Bool {
        url.scheme == "https" && !NeteaseArtworkURL.isDefaultArtistAvatar(url)
    }

    func libraryPortraitFile(_ id: Int64) -> URL? {
        let metadata = portraitMetadata[id]
        if let known = knownPortraitURL(id), metadata?.url != known { return nil }
        return portraitFiles[id]
    }

    func prepareLibraryPortrait(_ id: Int64) async {
        guard id > 0, isReady, !Task.isCancelled, libraryPortraitFile(id) == nil else { return }
        if let remote = knownPortraitURL(id), let file = cachedArtworkURL(remote) {
            portraitMetadata[id] = .init(url: remote, checkedAt: Date())
            portraitFiles[id] = file
            return
        }
        let token = revision, consumer = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard token == revision, !Task.isCancelled else { continuation.resume(); return }
                if portraitWaiters[id] == nil && portraitTasks[id] == nil { portraitQueue.append(id) }
                portraitWaiters[id, default: [:]][consumer] = continuation
                startPortraitRequests()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPortraitConsumer(id, consumer: consumer, token: token) }
        }
    }

    private func cancelPortraitConsumer(_ id: Int64, consumer: UUID, token: UUID) {
        guard token == revision, let continuation = portraitWaiters[id]?.removeValue(forKey: consumer) else { return }
        continuation.resume()
        guard portraitWaiters[id]?.isEmpty == true else { return }
        portraitWaiters[id] = nil
        if portraitTasks[id] == nil { portraitQueue.removeAll { $0 == id } }
    }

    private func startPortraitRequests() {
        while portraitTasks.count < 2 && !portraitQueue.isEmpty {
            let id = portraitQueue.removeFirst(), token = revision
            portraitTasks[id] = sessionScope.task { [self] in
                while true {
                    let previousURL = knownPortraitURL(id)
                    await resolveLibraryPortrait(id, token: token)
                    guard token == revision else { return }
                    guard portraitWaiters[id] != nil, let updatedURL = knownPortraitURL(id),
                          updatedURL != previousURL else { break }
                    portraitRetryAfter[id] = nil
                }
                portraitTasks[id] = nil
                if let waiters = portraitWaiters.removeValue(forKey: id) {
                    for waiter in waiters.values { waiter.resume() }
                }
                startPortraitRequests()
            }
        }
    }

    private func savedPortraitMetadata(_ id: Int64, token: UUID) async throws -> PortraitMetadata? {
        if let saved = portraitMetadata[id] { return saved }
        let saved = try? await portraitCache.load(PortraitMetadata.self, scope: scope, key: String(id))
        try check(token)
        if let saved { return saved }
        let page = try? await pageCache.load(ArtistPage.self, scope: scope, key: "artist:\(id)")
        try check(token)
        guard let artist = page?.detail?.artist, artist.id == id,
              let url = artist.artworkURL, Self.isArtistPortrait(url) else { return nil }
        return .init(url: url, checkedAt: Date())
    }

    func restoreCachedLibraryPortrait(_ id: Int64, session token: UUID) async -> URL? {
        guard isReady, sessionScope.isCurrent(token) else { return nil }
        if let existing = libraryPortraitFile(id) { return existing }
        let known = knownPortraitURL(id)
        let metadata: PortraitMetadata?
        if let known { metadata = .init(url: known, checkedAt: Date()) }
        else { metadata = try? await savedPortraitMetadata(id, token: token) }
        guard let metadata, let remote = metadata.url, sessionScope.isCurrent(token),
              let file = await cachedArtworkFile(remote), sessionScope.isCurrent(token),
              knownPortraitURL(id) == known else { return nil }
        portraitMetadata[id] = metadata
        portraitFiles[id] = file
        return file
    }

    private func resolveLibraryPortrait(_ id: Int64, token: UUID) async {
        let owner = scope, key = String(id)
        do {
            try check(token)
            let known = knownPortraitURL(id)
            if let retry = portraitRetryAfter[id], retry > Date(), known == nil || known == portraitMetadata[id]?.url { return }
            let metadata: PortraitMetadata
            if let url = known {
                metadata = .init(url: url, checkedAt: Date())
            } else {
                let saved = try await savedPortraitMetadata(id, token: token)
                let cached: URL?
                if let remote = saved?.url {
                    cached = await cachedArtworkFile(remote)
                    try check(token)
                } else { cached = nil }
                if let saved, cached != nil || Date().timeIntervalSince(saved.checkedAt) < 86_400 {
                    metadata = saved
                } else {
                    if let retry = portraitMetadataRetryAfter, retry > Date() { return }
                    let url: URL?
                    do {
                        url = try await client.artistPortraitURL(id: id, credential: credential)
                    } catch let error as NeteaseAccountError
                            where error == .server(-460) || error == .server(429) || error == .http(429) {
                        try check(token)
                        portraitMetadataRetryAfter = Date().addingTimeInterval(300)
                        throw error
                    }
                    try check(token)
                    metadata = .init(url: url.flatMap { Self.isArtistPortrait($0) ? $0 : nil }, checkedAt: Date())
                }
            }
            if portraitMetadata[id]?.url != metadata.url { portraitFiles[id] = nil }
            portraitMetadata[id] = metadata
            try? await portraitCache.save(metadata, scope: owner, key: key)
            try check(token)
            if let remote = metadata.url {
                if let existing = artworkLoader.task(for: remote) { await existing.value; try check(token) }
                _ = try await artworkCache.imageURL(for: remote, scope: owner, demand: .foreground)
                try check(token)
                notifyArtworkChange([remote])
            }
        } catch {
            guard token == revision, !Task.isCancelled else { return }
            sessionScope.report(error, revision: token, signedIn: credential != nil)
            portraitRetryAfter[id] = Date().addingTimeInterval(60)
        }
    }

    private func notifyArtworkChange(_ urls: Set<URL>) {
        for (id, metadata) in portraitMetadata {
            guard let remote = metadata.url, urls.contains(remote) else { continue }
            let file = cachedArtworkURL(remote)
            if portraitFiles[id] != file { portraitFiles[id] = file }
        }
        onArtworkChange?(urls)
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
        cacheWriter.save(value, scope: scope, key: key) { [weak self] error in
            self?.errors["cache"] = error.localizedDescription
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
                && $0.artists == $1.artists
        }
    }
}
