import CryptoKit
import Foundation
import Nuke

/// Shared original artwork files; Nuke owns network coalescing and subscriber cancellation.
@MainActor
final class NeteaseArtworkCache {
    static let shared = NeteaseArtworkCache(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NeteaseArtwork", isDirectory: true))
    /// Posted synchronously on MainActor, after cachedURL has stopped returning evicted files.
    /// Observe this cache as the object; use evictedURLs(in:scope:) for the account-owned resources.
    static let didEvictArtwork = Notification.Name("NeoMusic.NeteaseArtworkCache.didEvictArtwork")

    nonisolated static func eviction(in notification: Notification) -> (scope: String, urls: Set<URL>)? {
        guard let scope = notification.userInfo?["scope"] as? String,
              let urls = notification.userInfo?["urls"] as? Set<URL> else { return nil }
        return (scope, urls)
    }

    nonisolated static func evictedURLs(in notification: Notification, scope: String) -> Set<URL> {
        guard let event = eviction(in: notification), event.scope == scope else { return [] }
        return event.urls
    }

    private struct LoadingScope {
        let pipeline: ImagePipeline
        var consumers: Int
    }
    private struct Resource {
        let scope: String
        let remote: URL
    }
    private let dataLoader: DataLoader
    private let storage: NeteaseArtworkFiles
    private let keys: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1_024
        return cache
    }()
    private var files: [String: URL] = [:]
    private var resources: [String: Resource] = [:]
    private var revision = -1
    private var restored = false
    private var loading: [String: LoadingScope] = [:]

    init(directory: URL, session: URLSession? = nil,
         byteLimit: Int = 192 * 1_024 * 1_024, countLimit: Int = 512) {
        let configuration = session?.configuration ?? NeteaseAccountClient.sessionConfiguration()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        dataLoader = DataLoader(configuration: configuration, validate: { response in
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return URLError(.badServerResponse) }
            return nil
        })
        storage = NeteaseArtworkFiles(directory: directory, byteLimit: byteLimit, countLimit: countLimit)
    }

    func restore(scope: String) async {
        guard !restored, !Task.isCancelled else { return }
        guard let snapshot = try? await storage.snapshot(), !Task.isCancelled else { return }
        apply(snapshot)
        restored = true
    }

    func cachedURL(for remote: URL, scope: String) -> URL? {
        guard !files.isEmpty else { return nil }
        let key = key(remote, scope: scope)
        guard let file = files[key] else { return nil }
        resources[key] = Resource(scope: scope, remote: remote)
        return file
    }

    /// Resolves one existing file for visible artwork preparation, without networking or restoring the directory.
    func cachedFileURL(for remote: URL, scope: String) async -> URL? {
        guard !Task.isCancelled, remote.scheme == "https" else { return nil }
        if let file = cachedURL(for: remote, scope: scope) { return file }
        let key = key(remote, scope: scope)
        guard let snapshot = try? await storage.cachedFile(key: key), !Task.isCancelled else { return nil }
        apply(snapshot)
        return cachedURL(for: remote, scope: scope)
    }

    func imageURL(for remote: URL, scope: String) async throws -> URL {
        try Task.checkCancellation()
        guard remote.scheme == "https" else { throw URLError(.unsupportedURL) }
        await restore(scope: scope)
        try Task.checkCancellation()
        if let cached = cachedURL(for: remote, scope: scope) { return cached }

        let pipeline: ImagePipeline
        if var existing = loading[scope] {
            existing.consumers += 1
            loading[scope] = existing
            pipeline = existing.pipeline
        } else {
            var settings = ImagePipeline.Configuration(dataLoader: dataLoader)
            settings.imageCache = nil
            settings.dataCache = nil
            settings.isResumableDataEnabled = false
            pipeline = ImagePipeline(configuration: settings)
            loading[scope] = LoadingScope(pipeline: pipeline, consumers: 1)
        }
        defer {
            if var existing = loading[scope] {
                existing.consumers -= 1
                loading[scope] = existing.consumers == 0 ? nil : existing
            }
        }

        let data: Data
        let response: URLResponse?
        do { (data, response) = try await pipeline.data(for: ImageRequest(url: remote)) }
        catch {
            try Task.checkCancellation()
            switch error {
            case .dataLoadingFailed(let underlying): throw underlying
            case .dataIsEmpty: throw URLError(.badServerResponse)
            case .cancelled: throw CancellationError()
            default: throw error
            }
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), !data.isEmpty else { throw URLError(.badServerResponse) }
        let key = key(remote, scope: scope)
        let snapshot = try await storage.store(data, key: key)
        try Task.checkCancellation()
        apply(snapshot)
        guard let url = files[key] else { throw URLError(.cannotWriteToFile) }
        resources[key] = Resource(scope: scope, remote: remote)
        return url
    }

    private func apply(_ snapshot: NeteaseArtworkFiles.Snapshot) {
        guard snapshot.revision >= revision else { return }
        let removed = files.keys.filter { snapshot.files[$0] == nil }
        revision = snapshot.revision
        files = snapshot.files
        var evicted: [String: Set<URL>] = [:]
        for key in removed {
            if let resource = resources.removeValue(forKey: key) {
                evicted[resource.scope, default: []].insert(resource.remote)
            }
        }
        for (scope, urls) in evicted {
            NotificationCenter.default.post(name: Self.didEvictArtwork, object: self,
                userInfo: ["scope": scope, "urls": urls])
        }
    }

    private func key(_ remote: URL, scope: String) -> String {
        let identity = "\(scope):\(remote.absoluteString)" as NSString
        if let cached = keys.object(forKey: identity) { return cached as String }
        func digest(_ value: String) -> String {
            let alphabet = Array("0123456789abcdef".utf8)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(64)
            for byte in SHA256.hash(data: Data(value.utf8)) {
                bytes.append(alphabet[Int(byte >> 4)])
                bytes.append(alphabet[Int(byte & 15)])
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        let filename = digest(scope) + "-" + digest(remote.absoluteString) + ".image"
        keys.setObject(filename as NSString, forKey: identity)
        return filename
    }
}

private actor NeteaseArtworkFiles {
    struct Snapshot: Sendable {
        let revision: Int
        let files: [String: URL]
    }
    private struct File {
        let url: URL
        let bytes: Int
        let updated: Date
    }
    private let directory: URL
    private let byteLimit: Int
    private let countLimit: Int
    private var files: [String: File] = [:]
    private var loaded = false
    private var revision = 0

    init(directory: URL, byteLimit: Int, countLimit: Int) {
        self.directory = directory
        self.byteLimit = max(1, byteLimit)
        self.countLimit = max(1, countLimit)
    }

    func snapshot() throws -> Snapshot {
        try load()
        return currentSnapshot
    }

    func cachedFile(key: String) throws -> Snapshot {
        try Task.checkCancellation()
        guard files[key] == nil, !loaded else { return currentSnapshot }
        let url = directory.appendingPathComponent(key)
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try Task.checkCancellation()
        if let bytes = attributes.fileSize, bytes > 0 {
            files[key] = File(url: url, bytes: bytes, updated: attributes.contentModificationDate ?? .distantPast)
            revision += 1
        }
        return currentSnapshot
    }

    func store(_ data: Data, key: String) throws -> Snapshot {
        try load()
        try Task.checkCancellation()
        if files[key] != nil { return currentSnapshot }
        guard data.count <= byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        let url = directory.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        do { try Task.checkCancellation() }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        files[key] = File(url: url, bytes: data.count, updated: Date())
        revision += 1
        try trim(keeping: key)
        return currentSnapshot
    }

    private var currentSnapshot: Snapshot {
        Snapshot(revision: revision, files: files.mapValues(\.url))
    }

    private func load() throws {
        try Task.checkCancellation()
        guard !loaded else { return }
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let urls = try manager.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
            for url in urls where url.pathExtension == "image" {
                try Task.checkCancellation()
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                if let bytes = attributes.fileSize, bytes > 0 {
                    files[url.lastPathComponent] = File(url: url, bytes: bytes, updated: attributes.contentModificationDate ?? .distantPast)
                }
            }
            try trim()
        }
        // A complete index supersedes any earlier single-file lookup snapshots.
        revision += 1
        loaded = true
    }

    private func trim(keeping key: String? = nil) throws {
        var bytes = files.values.reduce(0) { $0 + $1.bytes }
        let oldest = files.filter { $0.key != key }.sorted {
            $0.value.updated == $1.value.updated ? $0.key < $1.key : $0.value.updated < $1.value.updated
        }
        for (name, file) in oldest where files.count > countLimit || bytes > byteLimit {
            try FileManager.default.removeItem(at: file.url)
            files[name] = nil
            bytes -= file.bytes
            revision += 1
        }
    }
}
