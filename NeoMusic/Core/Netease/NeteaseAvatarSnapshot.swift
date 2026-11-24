import Foundation

struct NeteaseAvatarSnapshot: Codable, Equatable, Sendable {
    static let maximumPixelSize = 192

    let userID: Int64
    let avatarURL: URL
    let data: Data

    func belongs(to profile: NeteaseProfile) -> Bool {
        userID == profile.userID
    }
}

struct NeteaseAvatarSnapshotStore: Sendable {
    private static let maximumFileSize = 256 * 1024
    private let fileURL: URL

    init(fileURL: URL = AppStoragePaths.neteaseAvatarDisplay) {
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
            guard let thumbnail = ImageSourceThumbnail.image(data, maxPixels: NeteaseAvatarSnapshot.maximumPixelSize),
                  !Task.isCancelled, let png = ImageSourceThumbnail.encodePNG(thumbnail) else { return nil }
            let snapshot = NeteaseAvatarSnapshot(userID: profile.userID, avatarURL: url, data: png)
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
            AppStoragePaths.excludeFromBackup(fileURL)
        } catch {}
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
