import CryptoKit
import Foundation
import Nuke

/// 网易云图片地址只在下载时改成固定尺寸。模型里仍保存接口返回的原始地址。
enum NeteaseArtworkURL {
    static let pixelSize = 1_024
    /// 没有头像时网易云给出的 img1v1Url 不是正方形。
    private static let nonSquareAvatar = "5639395138885805.jpg"
    private static let squareAvatar = "https://p1.music.126.net/VnZiScyynLG7atLIZ2YPkw==/18686200114669622.jpg"

    static func artist(img1v1Url: String?, picUrl: String?) -> URL? {
        let square = img1v1Url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosen = square.isEmpty ? picUrl : (square.contains(nonSquareAvatar) ? squareAvatar : square)
        return NeteaseMusicClient.url(chosen)
    }

    /// 清掉已有的 imageView、水印等参数后再请求 1024。直接追加 param 会被图片服务拒绝。
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

/// 详情页在数据到达时提前请求的封面数量，其余等所在行出现。
enum NeteaseArtworkPrefetch {
    /// 专辑和歌单首屏：大封面之外大约十二行歌曲。
    static let detailSongs = 12
    /// 艺人页首屏只列出五首。
    static let artistSongs = 5
    /// 横向作品卡约三张，再准备邻接的一张。
    static let shelfCards = 4
}

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

        let download = NeteaseArtworkURL.downloadURL(for: remote)
        let data: Data
        do {
            data = try await loadArtworkData(from: download, pipeline: pipeline)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard download != remote else { throw error }
            data = try await loadArtworkData(from: remote, pipeline: pipeline)
        }
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

    private func loadArtworkData(from url: URL, pipeline: ImagePipeline) async throws -> Data {
        let data: Data
        let response: URLResponse?
        do { (data, response) = try await pipeline.data(for: ImageRequest(url: url)) }
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
        return data
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
