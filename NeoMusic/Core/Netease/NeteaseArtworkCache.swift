import CryptoKit
import Foundation
import Nuke

enum NeteaseArtworkURL {
    static let pixelSize = 1_024
    private static let nonSquareAvatar = "5639395138885805.jpg"
    private static let squareAvatar = "https://p1.music.126.net/VnZiScyynLG7atLIZ2YPkw==/18686200114669622.jpg"

    static func artist(img1v1Url: String?, picUrl: String?) -> URL? {
        let square = img1v1Url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosen = square.isEmpty ? picUrl : (square.contains(nonSquareAvatar) ? squareAvatar : square)
        return NeteaseMusicClient.url(chosen)
    }

    static func downloadURL(for canonical: URL) -> URL {
        guard storesSizedVariant(canonical),
              var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else { return canonical }
        components.query = nil
        components.percentEncodedQuery = nil
        components.queryItems = [URLQueryItem(name: "param", value: "\(pixelSize)y\(pixelSize)")]
        return components.url ?? canonical
    }

    static func storesSizedVariant(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "music.126.net" || host.hasSuffix(".music.126.net")
    }
}

enum NeteaseArtworkPrefetch {
    static let detailSongs = 12
    static let artistSongs = 5
    static let shelfCards = 4
}

@MainActor
final class NeteaseArtworkCache {
    enum Demand: Equatable {
        case standard, prefetch, foreground

        var priority: ImageRequest.Priority {
            switch self {
            case .standard: .normal
            case .prefetch: .low
            case .foreground: .high
            }
        }
    }

    static let shared = NeteaseArtworkCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeteaseArtwork", isDirectory: true),
        countLimit: 4_096)
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
        cache.countLimit = 4_096
        return cache
    }()
    private var files: [String: URL] = [:]
    private var keyRevisions: [String: Int] = [:]
    private var resources: [String: Resource] = [:]
    private var revision = -1
    private var restored = false
    private var loading: [String: LoadingScope] = [:]
    private var prefetches: [String: Int] = [:]

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

    func cachedFileURL(for remote: URL, scope: String) async -> URL? {
        guard !Task.isCancelled, remote.scheme == "https" else { return nil }
        if let file = cachedURL(for: remote, scope: scope) { return file }
        guard !restored else { return nil }
        let key = key(remote, scope: scope)
        guard let snapshot = try? await storage.cachedFile(key: key), !Task.isCancelled else { return nil }
        apply(snapshot)
        return cachedURL(for: remote, scope: scope)
    }

    func imageURL(for remote: URL, scope: String, demand: Demand = .standard) async throws -> URL {
        try Task.checkCancellation()
        guard remote.scheme == "https" else { throw URLError(.unsupportedURL) }
        await restore(scope: scope)
        try Task.checkCancellation()
        if let cached = cachedURL(for: remote, scope: scope) { return cached }

        let key = key(remote, scope: scope)
        let joinedPrefetch = demand == .foreground && prefetches[key] != nil
        if demand == .prefetch { prefetches[key, default: 0] += 1 }
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
            if demand == .prefetch, let count = prefetches[key] {
                prefetches[key] = count == 1 ? nil : count - 1
            }
            if var existing = loading[scope] {
                existing.consumers -= 1
                loading[scope] = existing.consumers == 0 ? nil : existing
            }
        }

        let data: Data
        do {
            data = try await Self.downloadArtwork(remote, pipeline: pipeline, priority: demand.priority)
        } catch {
            try Task.checkCancellation()
            guard joinedPrefetch, !(error is CancellationError) else { throw error }
            // A foreground consumer gets its own attempt if the shared prefetch fails.
            if let cached = cachedURL(for: remote, scope: scope) { return cached }
            data = try await Self.downloadArtwork(remote, pipeline: pipeline, priority: demand.priority)
        }
        try Task.checkCancellation()
        let snapshot = try await storage.store(data, key: key)
        apply(snapshot)
        try Task.checkCancellation()
        guard let url = files[key] else { throw URLError(.cannotWriteToFile) }
        resources[key] = Resource(scope: scope, remote: remote)
        return url
    }

    private func apply(_ snapshot: NeteaseArtworkFiles.Snapshot) {
        var evicted: [String: Set<URL>] = [:]
        switch snapshot {
        case .full(let nextRevision, let nextFiles):
            guard nextRevision >= revision else { return }
            let removed = files.keys.filter { nextFiles[$0] == nil && nextRevision >= (keyRevisions[$0] ?? -1) }
            revision = nextRevision
            for key in removed {
                files.removeValue(forKey: key)
                keyRevisions[key] = nextRevision
                if let resource = resources.removeValue(forKey: key) {
                    evicted[resource.scope, default: []].insert(resource.remote)
                }
            }
            for (key, url) in nextFiles where nextRevision >= (keyRevisions[key] ?? -1) {
                files[key] = url
                keyRevisions[key] = nextRevision
            }
        case .delta(let nextRevision, let added, let removed):
            if nextRevision > revision { revision = nextRevision }
            if let (key, url) = added, nextRevision >= (keyRevisions[key] ?? -1) {
                files[key] = url
                keyRevisions[key] = nextRevision
            }
            for key in removed where nextRevision >= (keyRevisions[key] ?? -1) {
                keyRevisions[key] = nextRevision
                files.removeValue(forKey: key)
                if let resource = resources.removeValue(forKey: key) {
                    evicted[resource.scope, default: []].insert(resource.remote)
                }
            }
        }
        for (scope, urls) in evicted {
            NotificationCenter.default.post(name: Self.didEvictArtwork, object: self,
                userInfo: ["scope": scope, "urls": urls])
        }
    }

    private static func downloadArtwork(_ remote: URL, pipeline: ImagePipeline,
                                        priority: ImageRequest.Priority) async throws -> Data {
        let download = NeteaseArtworkURL.downloadURL(for: remote)
        do {
            return try await loadArtworkData(from: download, pipeline: pipeline, priority: priority)
        } catch {
            try Task.checkCancellation()
            guard download != remote, !(error is CancellationError) else { throw error }
            return try await loadArtworkData(from: remote, pipeline: pipeline, priority: priority)
        }
    }

    private static func loadArtworkData(from url: URL, pipeline: ImagePipeline,
                                        priority: ImageRequest.Priority) async throws -> Data {
        let data: Data
        let response: URLResponse?
        do { (data, response) = try await pipeline.data(for: ImageRequest(url: url, priority: priority)) }
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
        guard await canDecodeArtwork(data) else {
            throw URLError(.cannotDecodeContentData)
        }
        return data
    }

    @concurrent private static func canDecodeArtwork(_ data: Data) async -> Bool {
        ImageRequest.ThumbnailOptions(maxPixelSize: 64).makeThumbnail(with: data) != nil
    }

    private func key(_ remote: URL, scope: String) -> String {
        let variant = NeteaseArtworkURL.storesSizedVariant(remote) ? ":\(NeteaseArtworkURL.pixelSize)" : ""
        let identity = "\(scope):\(remote.absoluteString)\(variant)" as NSString
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
    enum Snapshot: Sendable {
        case full(revision: Int, files: [String: URL])
        case delta(revision: Int, added: (String, URL)?, removed: [String])
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
    private var totalBytes = 0
    private var loaded = false
    private var revision = 0

    init(directory: URL, byteLimit: Int, countLimit: Int) {
        self.directory = directory
        self.byteLimit = max(1, byteLimit)
        self.countLimit = max(1, countLimit)
    }

    func snapshot() throws -> Snapshot {
        try load()
        return .full(revision: revision, files: files.mapValues(\.url))
    }

    func cachedFile(key: String) throws -> Snapshot? {
        try Task.checkCancellation()
        guard files[key] == nil, !loaded else { return nil }
        let url = directory.appendingPathComponent(key)
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try Task.checkCancellation()
        guard let bytes = attributes.fileSize, bytes > 0 else { return nil }
        files[key] = File(url: url, bytes: bytes, updated: attributes.contentModificationDate ?? .distantPast)
        totalBytes += bytes
        revision += 1
        return .delta(revision: revision, added: (key, url), removed: [])
    }

    func store(_ data: Data, key: String) throws -> Snapshot {
        let wasLoaded = loaded
        try load()
        try Task.checkCancellation()
        if let existing = files[key] {
            return wasLoaded
                ? .delta(revision: revision, added: (key, existing.url), removed: [])
                : .full(revision: revision, files: files.mapValues(\.url))
        }
        guard data.count <= byteLimit else { throw URLError(.dataLengthExceedsMaximum) }
        let url = directory.appendingPathComponent(key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        do { try Task.checkCancellation() }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        files[key] = File(url: url, bytes: data.count, updated: Date())
        totalBytes += data.count
        revision += 1
        let removed = try trim(keeping: key)
        return wasLoaded
            ? .delta(revision: revision, added: (key, url), removed: removed)
            : .full(revision: revision, files: files.mapValues(\.url))
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
                    let key = url.lastPathComponent
                    if let previous = files[key] { totalBytes -= previous.bytes }
                    files[key] = File(url: url, bytes: bytes, updated: attributes.contentModificationDate ?? .distantPast)
                    totalBytes += bytes
                }
            }
            _ = try trim()
        }
        revision += 1
        loaded = true
    }

    @discardableResult
    private func trim(keeping key: String? = nil) throws -> [String] {
        guard files.count > countLimit || totalBytes > byteLimit else { return [] }
        let oldest = files.filter { $0.key != key }.sorted {
            $0.value.updated == $1.value.updated ? $0.key < $1.key : $0.value.updated < $1.value.updated
        }
        var removed: [String] = []
        for (name, file) in oldest where files.count > countLimit || totalBytes > byteLimit {
            try FileManager.default.removeItem(at: file.url)
            files[name] = nil
            totalBytes -= file.bytes
            revision += 1
            removed.append(name)
        }
        return removed
    }
}
