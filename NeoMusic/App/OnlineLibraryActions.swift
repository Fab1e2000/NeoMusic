import Foundation

@MainActor
final class ArtworkUpdateBatcher {
    private var session: UUID?
    private var pending: Set<URL> = []
    private(set) var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        pending.removeAll()
        session = nil
    }

    func enqueue(_ urls: Set<URL>, session: UUID, isCurrent: @escaping () -> Bool,
                 publish: @escaping (Set<URL>) -> Void) {
        guard !urls.isEmpty else { return }
        if self.session != session {
            cancel()
            self.session = session
        }
        pending.formUnion(urls)
        guard task == nil else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, !Task.isCancelled, self.session == session else { return }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            task = nil
            if isCurrent() { publish(batch) }
        }
    }
}

@MainActor
enum ReferencedLibrarySongs {
    static func collect(player: NowPlayingModel, playlists: PlaylistLibrary) -> [LibrarySongItem] {
        player.queue + playlists.playlists.filter { !$0.isReadOnly && !$0.isSystem }
            .flatMap { playlists.songs(in: $0.id) }
    }
}

@MainActor
enum OnlineFavoriteAction {
    @discardableResult static func perform(music: NeteaseMusicStore, revision: UUID, songID: Int64, liked: Bool,
                        toasts: LibraryToastCenter,
                        beforeConfirmation: (() async -> Void)? = nil, isCurrent: @escaping () -> Bool) -> Task<Void, Never>? {
        guard LibraryNetworkAccess.allowOnlineAction() else { return nil }
        LibraryHaptics.success()
        return Task {
            guard !Task.isCancelled, revision == music.sessionRevision, isCurrent() else { return }
            do {
                try await music.setLiked(songID: songID, liked: liked)
                await beforeConfirmation?()
                guard revision == music.sessionRevision, isCurrent() else { return }
                toasts.show(liked ? .favorited : .unfavorited)
            } catch is CancellationError {
            } catch {
                guard revision == music.sessionRevision, isCurrent() else { return }
                toasts.show(.error(error.localizedDescription))
            }
        }
    }
}

@MainActor
enum DeferredArtworkRoute {
    static func key(_ id: String, session: UUID, domain: DeferredArtworkKey.Domain? = nil) -> DeferredArtworkKey? {
        guard let key = DeferredArtworkKey(rawValue: id), key.session == session.uuidString,
              domain == nil || key.domain == domain else { return nil }
        return key
    }

    static func remote(_ id: String, session: UUID, domain: DeferredArtworkKey.Domain) -> URL? {
        key(id, session: session, domain: domain)?.remoteURL
    }

    static func cachedFile(_ id: String, session: UUID, domain: DeferredArtworkKey.Domain? = nil,
                           isCurrent: () -> Bool,
                           load: (DeferredArtworkKey) async -> URL?) async -> URL? {
        guard !Task.isCancelled, isCurrent(), let key = key(id, session: session, domain: domain) else { return nil }
        let file = await load(key)
        guard !Task.isCancelled, isCurrent() else { return nil }
        return file
    }
}
