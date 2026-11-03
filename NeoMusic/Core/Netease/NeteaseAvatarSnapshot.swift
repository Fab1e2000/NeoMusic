import Foundation
import ImageIO

struct NeteaseAvatarSnapshot: Codable, Equatable, Sendable {
    let userID: Int64
    let avatarURL: URL
    let data: Data

    func belongs(to profile: NeteaseProfile) -> Bool {
        userID == profile.userID
    }
}

/// A small, derived image for the first frame; credentials remain in Keychain.
struct NeteaseAvatarSnapshotStore: Sendable {
    private static let maximumFileSize = 256 * 1024
    private let fileURL: URL

    init(fileURL: URL = URL.cachesDirectory.appending(path: "NeteaseAvatarDisplay.plist")) {
        self.fileURL = fileURL
    }

    func load() -> NeteaseAvatarSnapshot? {
        guard let file = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: Self.maximumFileSize + 1),
              data.count <= Self.maximumFileSize,
              let snapshot = try? PropertyListDecoder().decode(NeteaseAvatarSnapshot.self, from: data),
              !snapshot.data.isEmpty else { return nil }
        return snapshot
    }

    @concurrent
    func save(_ data: Data, for profile: NeteaseProfile) async {
        guard !Task.isCancelled, let url = profile.avatarURL else { return }
        let encoded: Data? = autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                    [kCGImageSourceShouldCache: false] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: 192
                  ] as CFDictionary), !Task.isCancelled else { return nil }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else {
                return nil
            }
            CGImageDestinationAddImage(destination, thumbnail, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            let snapshot = NeteaseAvatarSnapshot(userID: profile.userID, avatarURL: url, data: png as Data)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try? encoder.encode(snapshot)
        }
        guard let encoded, encoded.count <= Self.maximumFileSize, !Task.isCancelled else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            guard !Task.isCancelled else { return }
            try encoded.write(to: fileURL, options: .atomic)
        } catch { /* A derived image can be rebuilt after the next successful avatar load. */ }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
