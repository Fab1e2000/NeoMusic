import Foundation
import FrontAMCore
import FrontAMPages

extension LibrarySongItem {
    init(id: String, title: String, artist: String, album: String, albumArtist: String,
         trackNumber: Int, artwork: Artwork, albumDirectory: String? = nil, discNumber: Int = 1,
         artworkData: Data? = nil, artworkURL: URL? = nil, artworkBackdrop: AlbumArtworkBackdrop? = nil,
         duration: Int = 0, isPinned: Bool = false, addedOrder: Int = 0, isFavorite: Bool = false,
         favoriteAddedAt: Date? = nil, unavailabilityReason: String? = nil,
         onlineAlbumID: Int64? = nil, artistReferences: [LibraryArtistReference] = [], year: Int? = nil) {
        let isOnline = OnlineSongIdentity.parseOwnerAndSong(id) != nil
        self.init(id: id, title: title, artist: artist, album: album,
                  albumArtist: albumArtist, trackNumber: trackNumber, artwork: artwork, albumDirectory: albumDirectory,
                  discNumber: discNumber, artworkData: artworkData, artworkURL: artworkURL, artworkBackdrop: artworkBackdrop,
                  duration: duration, isPinned: isPinned, addedOrder: addedOrder, isFavorite: isFavorite,
                  favoriteAddedAt: favoriteAddedAt, unavailabilityReason: unavailabilityReason, onlineAlbumID: onlineAlbumID, artistReferences: artistReferences,
                  year: year,
                  displaySource: .init(catalogAlbumIDPrefix: CatalogRouteIdentity.albumID(""),
                    isOnline: isOnline,
                    isCatalogGuest: id.hasPrefix("catalog-guest:")))
    }

    var onlineOwnerID: String? {
        OnlineSongIdentity.parseOwnerAndSong(id)?.ownerID
    }
    var onlineSongID: Int64? {
        OnlineSongIdentity.parseOwnerAndSong(id)?.songID
    }
    func retainingArtwork(from previous: Self?) -> Self {
        guard isOnline, let previous, previous.id == id, unavailabilityReason == nil,
              artworkURL == nil else { return self }
        let file: URL?
        if let url = previous.artworkURL { file = url }
        else if case .file(let url) = previous.artwork { file = url }
        else { file = nil }
        let availableFile = file.flatMap { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        guard availableFile != nil || previous.artworkData != nil else { return self }
        var result = self
        result.artworkURL = availableFile
        result.artworkData = previous.artworkData
        result.artworkBackdrop = previous.artworkBackdrop
        if artwork.loadID == nil { result.artwork = availableFile.map(Artwork.file) ?? previous.artwork }
        return result
    }

    static func unavailable(_ id: String) -> Self {
        if id.hasPrefix("netease:") {
            return Self(id: id, title: "在线歌曲", artist: "登录原账号后可用", album: "", albumArtist: "", trackNumber: 0,
                        artwork: .missing, unavailabilityReason: "请登录原网易云账号后重试")
        }
        return Self(id: id, title: URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent,
             artist: "文件不可用", album: "", albumArtist: "", trackNumber: 0, artwork: .missing)
    }

    var isNeteaseCatalogSong: Bool { hasCatalogActions }
}
