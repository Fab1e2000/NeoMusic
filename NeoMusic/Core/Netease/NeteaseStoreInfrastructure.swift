import Foundation
import Observation

@MainActor
struct SessionTaskBag {
    private struct Entry {
        let cancel: () -> Void
        let wait: () async -> Void
    }

    private var entries: [UUID: Entry] = [:]

    mutating func insert<Value: Sendable, Failure: Error>(_ task: Task<Value, Failure>, id: UUID = UUID()) {
        entries[id] = Entry(cancel: { task.cancel() }, wait: { _ = await task.result })
    }

    mutating func insert<Value: Sendable, Failure: Error>(contentsOf tasks: some Sequence<Task<Value, Failure>>) {
        for task in tasks { insert(task) }
    }

    mutating func remove(_ id: UUID) { entries.removeValue(forKey: id) }

    func cancelAll() {
        for entry in entries.values { entry.cancel() }
    }

    func waitForAll() async {
        for entry in entries.values { await entry.wait() }
    }
}

@MainActor @Observable
final class NeteaseSessionScope {
    private(set) var revision = UUID()
    @ObservationIgnored var onAuthenticationRequired: (() -> Void)?
    @ObservationIgnored private var draining: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var registered = SessionTaskBag()

    func advance() -> UUID {
        revision = UUID()
        return revision
    }

    func isCurrent(_ revision: UUID) -> Bool {
        self.revision == revision && !Task.isCancelled
    }

    func task<Value: Sendable>(_ operation: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.registered.remove(id) }
            return await operation()
        }
        registered.insert(task, id: id)
        return task
    }

    func throwingTask<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) -> Task<Value, Error> {
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.registered.remove(id) }
            return try await operation()
        }
        registered.insert(task, id: id)
        return task
    }

    func cancelAndDrain(_ pending: SessionTaskBag = SessionTaskBag(),
        afterCancelling: (() async -> Void)? = nil) -> Task<Void, Never> {
        let active = registered
        registered = SessionTaskBag()
        active.cancelAll()
        pending.cancelAll()
        // A second transition must also wait for work already taken by the first.
        let previous = draining?.task
        let id = UUID()
        let work = Task { [weak self] in
            defer { if self?.draining?.id == id { self?.draining = nil } }
            await previous?.value
            await afterCancelling?()
            await active.waitForAll()
            await pending.waitForAll()
        }
        draining = (id, work)
        return work
    }

    func report(_ error: any Error, revision: UUID, signedIn: Bool) {
        guard signedIn, isCurrent(revision), error as? NeteaseAccountError == .authenticationRequired else { return }
        onAuthenticationRequired?()
    }

    func authenticationHandler(signedIn: Bool) -> (@MainActor @Sendable () -> Void)? {
        guard signedIn else { return nil }
        let revision = revision
        return { [weak self] in
            self?.report(NeteaseAccountError.authenticationRequired, revision: revision, signedIn: true)
        }
    }
}

@MainActor
final class KeyedPageCacheWriter {
    private struct Key: Hashable {
        let scope: String
        let name: String
    }

    private struct Write {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let cache: NeteasePageCache
    private let session: NeteaseSessionScope
    private var writes: [Key: Write] = [:]

    init(cache: NeteasePageCache, session: NeteaseSessionScope) {
        self.cache = cache
        self.session = session
    }

    func save<Value: Encodable & Sendable>(_ value: Value, scope: String, key: String,
        onFailure: ((any Error) -> Void)? = nil) {
        let entry = Key(scope: scope, name: key)
        let previous = writes[entry]?.task
        let id = UUID()
        let revision = session.revision
        previous?.cancel()
        let task = Task { [weak self, cache, session] in
            defer {
                if self?.writes[entry]?.id == id { self?.writes[entry] = nil }
            }
            await previous?.value
            guard session.isCurrent(revision) else { return }
            do {
                try await cache.save(value, scope: scope, key: key)
            } catch is CancellationError {
            } catch {
                if session.isCurrent(revision) { onFailure?(error) }
            }
        }
        writes[entry] = Write(id: id, task: task)
    }

    func takePending(into bag: inout SessionTaskBag) {
        bag.insert(contentsOf: writes.values.map(\.task))
        writes.removeAll()
    }

    func flush() async {
        let pending = writes.values.map(\.task)
        for task in pending { await task.value }
    }
}

@MainActor
final class ScopedArtworkLoader {
    let cache: NeteaseArtworkCache
    private let session: NeteaseSessionScope
    private var tasks: [URL: Task<Void, Never>] = [:]
    private var observer: (any NSObjectProtocol)?
    var scope: (() -> String?)?
    var isReady: (() -> Bool)?
    var onChange: ((Set<URL>) -> Void)?
    var onFailure: ((URL) -> Void)?

    init(cache: NeteaseArtworkCache, session: NeteaseSessionScope) {
        self.cache = cache
        self.session = session
        observer = NotificationCenter.default.addObserver(forName: NeteaseArtworkCache.didEvictArtwork,
            object: cache, queue: .main) { [weak self] notification in
                guard let event = NeteaseArtworkCache.eviction(in: notification), !event.urls.isEmpty else { return }
                MainActor.assumeIsolated {
                    guard let self, self.isReady?() == true, event.scope == self.scope?() else { return }
                    self.onChange?(event.urls)
                }
            }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func cachedURL(_ remote: URL) -> URL? {
        guard let owner = scope?() else { return nil }
        return cache.cachedURL(for: remote, scope: owner)
    }

    func cachedFile(_ remote: URL) async -> URL? {
        guard isReady?() == true, let owner = scope?(), !Task.isCancelled else { return nil }
        let revision = session.revision
        let file = await cache.cachedFileURL(for: remote, scope: owner)
        guard isReady?() == true, session.isCurrent(revision), owner == scope?() else { return nil }
        return file
    }

    func request(_ urls: [URL], notifyCached: Bool = true) {
        guard isReady?() == true, let owner = scope?(), !Task.isCancelled else { return }
        let revision = session.revision
        var seen = Set<URL>()
        var cached = Set<URL>()
        for remote in urls where seen.insert(remote).inserted {
            if cachedURL(remote) != nil { cached.insert(remote); continue }
            guard remote.scheme == "https", tasks[remote] == nil else { continue }
            tasks[remote] = Task { [weak self] in
                guard let self else { return }
                defer { if session.revision == revision { tasks[remote] = nil } }
                await load(remote, owner: owner, revision: revision, demand: .standard)
            }
        }
        if notifyCached, !cached.isEmpty { onChange?(cached) }
    }

    func load(_ remote: URL, owner: String, revision: UUID, demand: NeteaseArtworkCache.Demand) async {
        guard session.isCurrent(revision), owner == scope?() else { return }
        do {
            _ = try await cache.imageURL(for: remote, scope: owner, demand: demand)
            guard session.isCurrent(revision), owner == scope?() else { return }
            PerformanceDiagnostics.event("ArtworkReady")
            onChange?([remote])
        } catch {
            guard session.isCurrent(revision), owner == scope?(), cachedURL(remote) == nil else { return }
            onFailure?(remote)
        }
    }

    func task(for remote: URL) -> Task<Void, Never>? { tasks[remote] }

    func takePending(into bag: inout SessionTaskBag) {
        bag.insert(contentsOf: tasks.values)
        tasks.removeAll()
    }
}
