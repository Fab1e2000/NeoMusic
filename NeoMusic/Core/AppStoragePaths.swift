import Foundation

enum AppStoragePaths {
    static let music = musicDirectory(in: .documentsDirectory)
    static let library = URL.applicationSupportDirectory.appending(path: "LocalLibrary", directoryHint: .isDirectory)
    static let lyrics = URL.applicationSupportDirectory.appending(path: "Lyrics", directoryHint: .isDirectory)
    static let neteaseDownloads = URL.applicationSupportDirectory.appending(path: "NeteaseDownloads", directoryHint: .isDirectory)
    static let legacyNeteaseHome = URL.applicationSupportDirectory.appending(path: "NeteaseHome", directoryHint: .isDirectory)
    // Daily snapshots are referenced by saved playback and remain in Application Support.
    static let neteaseDailyHistory = dailyHistory(in: legacyNeteaseHome)
    static let navigationDiagnostics = URL.applicationSupportDirectory.appending(path: "NavigationDiagnostics", directoryHint: .isDirectory)

    static let neteaseMusicCache = URL.cachesDirectory.appending(path: "NeteaseMusic", directoryHint: .isDirectory)
    static let neteaseArtistsCache = URL.cachesDirectory.appending(path: "NeteaseArtists", directoryHint: .isDirectory)
    static let neteaseHomeCache = URL.cachesDirectory.appending(path: "NeteaseHome", directoryHint: .isDirectory)
    static let neteaseArtworkCache = URL.cachesDirectory.appending(path: "NeteaseArtwork", directoryHint: .isDirectory)
    static let neteaseAvatarCache = URL.cachesDirectory.appending(path: "NeteaseAvatar", directoryHint: .isDirectory)
    static let neteaseAvatarDisplay = URL.cachesDirectory.appending(path: "NeteaseAvatarDisplay.plist")
    static let artworkBackdrops = URL.cachesDirectory.appending(path: "ArtworkBackdrops.json")

    static func musicDirectory(in documents: URL) -> URL {
        documents.appending(path: "音乐", directoryHint: .isDirectory)
    }

    static func dailyHistory(in directory: URL) -> URL {
        directory.appending(path: "DailyHistory", directoryHint: .isDirectory)
    }

    static func prepareCacheDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        excludeFromBackup(url)
    }

    static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = url
        try? url.setResourceValues(values)
    }
}
