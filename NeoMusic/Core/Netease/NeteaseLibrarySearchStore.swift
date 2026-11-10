import Foundation
import Observation

@MainActor @Observable
final class NeteaseLibrarySearchStore {
    private(set) var isSyncing = false
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var failedCollections: Set<String> = []
    private(set) var error: String?
    private(set) var revision = 0
    @ObservationIgnored private let client: NeteaseMusicClient
    @ObservationIgnored let index: NeteaseLibrarySearchIndex
    @ObservationIgnored private var session: NeteaseLibrarySearchIndex.Session?
    @ObservationIgnored private var credential: NeteaseCredential?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var lastSync: Date?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var needsAnotherSync = false
    @ObservationIgnored private var forceRequested = false

    init(client: NeteaseMusicClient = .init(), directory: URL? = nil) {
        self.client = client
        index = NeteaseLibrarySearchIndex(directory: directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeteaseSearch"))
    }
    func setSession(owner: Int64?, credential: NeteaseCredential?) async {
        guard !Task.isCancelled else { return }
        guard sessionTask != nil || session?.owner != owner.map(String.init) || self.credential != credential else { return }
        let generation = UUID(); self.generation = generation
        let previousSession = sessionTask
        previousSession?.cancel()
        let previous = task, previousScheduled = scheduled
        previous?.cancel(); previousScheduled?.cancel(); task = nil; scheduled = nil; needsAnotherSync = false; forceRequested = false
        session = nil; self.credential = nil
        let work = Task { [self] in
            defer {
                if self.generation == generation {
                    sessionTask = nil
                    isSyncing = false; completed = 0; total = 0; failedCollections = []; error = nil
                    lastSync = nil; revision &+= 1
                }
            }
            await previousSession?.value
            await previous?.value
            await previousScheduled?.value
            guard self.generation == generation, !Task.isCancelled else { return }
            let next = owner.map { NeteaseLibrarySearchIndex.Session(owner: String($0), revision: generation) }
            await index.activate(next)
            guard self.generation == generation, !Task.isCancelled else { return }
            session = next; self.credential = credential
        }
        sessionTask = work
        await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    /// Started by the account lifecycle; collection mutations request one bounded follow-up.
    func scheduleSynchronization(changed: Bool = false) {
        guard sessionTask == nil, session != nil else { return }
        if changed { lastSync = nil; needsAnotherSync = true }
        guard scheduled == nil else { return }
        let generation = generation
        scheduled = Task {
            repeat {
                needsAnotherSync = false
                await synchronize()
                if needsAnotherSync { lastSync = nil }
            } while !Task.isCancelled && self.generation == generation && needsAnotherSync
            if self.generation == generation { scheduled = nil }
        }
    }
    func search(_ query: String, kind: NeteaseSearchKind = .combined) async throws -> [NeteaseSearchResource] {
        try Task.checkCancellation()
        let generation = generation
        await sessionTask?.value
        try Task.checkCancellation()
        guard self.generation == generation, sessionTask == nil else { throw CancellationError() }
        guard let session else { return [] }
        let result = try await index.search(query, kind: kind, session: session)
        guard self.session == session else { throw CancellationError() }
        return result
    }
    func synchronize(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        let generation = generation
        await sessionTask?.value
        guard self.generation == generation, sessionTask == nil, !Task.isCancelled else { return }
        if force { forceRequested = true }
        if let task { await task.value; return }
        guard let session, let credential, let owner = Int64(session.owner) else { return }
        if !force, let lastSync, Date().timeIntervalSince(lastSync) < 300 { return }
        let work = Task {
            repeat {
                let forced = forceRequested; forceRequested = false
                await performSync(owner: owner, credential: credential, session: session, force: forced)
            } while !Task.isCancelled && self.session == session && forceRequested
        }
        task = work
        await work.value
        if self.session == session { task = nil }
    }

    private func performSync(owner: Int64, credential: NeteaseCredential, session: NeteaseLibrarySearchIndex.Session, force: Bool) async {
        isSyncing = true; completed = 0; total = 0; failedCollections = []; error = nil
        defer { if self.session == session { isSyncing = false; revision &+= 1 } }
        do {
            var known = try await index.songs(session: session)
            let versions = try await index.versions(session: session)
            // Each directory commits independently; a failed directory never removes old membership.
            do {
                let playlists = try await client.playlists(userID: owner, credential: credential)
                try check(session)
                total += playlists.count
                try await index.reconcile(prefix: "playlist:", keeping: Set(playlists.map { "playlist:\($0.id)" }), session: session)
                for playlist in playlists {
                    try check(session)
                    let key = "playlist:\(playlist.id)"
                    let version = "\(playlist.updateTime?.timeIntervalSince1970 ?? 0):\(playlist.trackCount)"
                    if !force, playlist.updateTime != nil, versions[key] == version { completed += 1; continue }
                    do {
                        let summary = try await client.detail(id: playlist.id, credential: credential, trackLimit: 0)
                        let songs = try await resolve(summary.orderedTrackIDs, known: &known, credential: credential, session: session)
                        let item = NeteaseSearchResource(kind: .playlist, resourceID: playlist.id, title: playlist.title, subtitle: playlist.creator, artworkURL: playlist.artworkURL)
                        try await index.replace(collection: key, version: version, resources: [item] + songs.map(NeteaseSearchClient.resource), session: session)
                        revision &+= 1
                    } catch is CancellationError { throw CancellationError() }
                    catch { failedCollections.insert(key) }
                    completed += 1
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failedCollections.insert("playlist:directory") }

            do {
                let albums = try await client.subscribedAlbums(credential: credential)
                try check(session); total += albums.count
                try await index.reconcile(prefix: "album:", keeping: Set(albums.map { "album:\($0.id)" }), session: session)
                for album in albums {
                    try check(session)
                    let key = "album:\(album.id)"
                    let version = "\(album.trackCount):\(album.title)"
                    if !force, versions[key] == version { completed += 1; continue }
                    do {
                        let detail = try await client.albumDetail(id: album.id, credential: credential)
                        try check(session)
                        let item = NeteaseSearchResource(kind: .album, resourceID: album.id, title: album.title, subtitle: album.artist, artworkURL: album.artworkURL)
                        try await index.replace(collection: key, version: version, resources: [item] + detail.songs.map(NeteaseSearchClient.resource), session: session)
                        for song in detail.songs { known[song.id] = song }
                        revision &+= 1
                    } catch is CancellationError { throw CancellationError() }
                    catch { failedCollections.insert(key) }
                    completed += 1
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failedCollections.insert("album:directory") }

            do {
                total += 1
                let artists = try await client.subscribedArtists(credential: credential)
                try check(session)
                try await index.replace(collection: "artists", version: "", resources: artists.map {
                    .init(kind: .artist, resourceID: $0.id, title: $0.name, subtitle: "艺人", artworkURL: $0.artworkURL)
                }, session: session)
                revision &+= 1
            } catch is CancellationError { throw CancellationError() }
            catch { failedCollections.insert("artists") }
            completed += 1
            do {
                total += 1
                let ids = try await client.likedIDs(userID: owner, credential: credential).sorted()
                let songs = try await resolve(ids, known: &known, credential: credential, session: session)
                try await index.replace(collection: "liked", version: "", resources: songs.map(NeteaseSearchClient.resource), session: session)
                revision &+= 1
            } catch is CancellationError { throw CancellationError() }
            catch { failedCollections.insert("liked") }
            completed += 1
            try check(session)
            if failedCollections.isEmpty { lastSync = Date() }
        } catch is CancellationError { }
        catch { if self.session == session { self.error = error.localizedDescription } }
    }

    private func resolve(_ ids: [Int64], known: inout [Int64: NeteaseMusicSong], credential: NeteaseCredential,
                         session: NeteaseLibrarySearchIndex.Session) async throws -> [NeteaseMusicSong] {
        var seen = Set<Int64>()
        let unique = ids.filter { seen.insert($0).inserted }
        let missing = unique.filter { known[$0] == nil }
        for start in stride(from: 0, to: missing.count, by: 100) {
            try check(session)
            let songs = try await client.songs(ids: Array(missing[start..<min(start + 100, missing.count)]), credential: credential)
            try check(session)
            for song in songs { known[song.id] = song }
        }
        guard unique.allSatisfy({ known[$0] != nil }) else { throw NeteaseAccountError.invalidResponse }
        return unique.compactMap { known[$0] }
    }
    private func check(_ session: NeteaseLibrarySearchIndex.Session) throws {
        try Task.checkCancellation()
        guard self.session == session else { throw CancellationError() }
    }
}
