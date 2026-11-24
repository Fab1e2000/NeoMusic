enum AppDefaultsKey {
    static let pinnedAlbums = "pinnedAlbums"
    static let favoriteAlbums = "favoriteAlbums"
    static let favoriteArtists = "favoriteArtists"
    static let deletedAlbums = "deletedAlbums"
    static let pinnedSongs = "pinnedSongs"
    static let hiddenSongs = "hiddenSongs"
    static let favoriteSongs = "favoriteSongs"
    static let favoriteSongDates = "favoriteSongDates"
    static let pinnedShelfOrder = "pinnedShelfOrder.v1"
    static let libraryArtistPreferences = "libraryArtistPreferences.v1"
    static let appTabOrder = "appTabOrder.v1"
    static let appTabHidden = "appTabHidden.v1"
    static let neteaseWiFiQuality = "netease.quality.wifi"
    static let neteaseCellularQuality = "netease.quality.cellular"
    static let neteaseDownloadQuality = "netease.download.quality"
    static let neteaseDownloadCellular = "netease.download.cellular"

    static func onlineSearchHistory(owner: String) -> String {
        "search.history.\(owner).online"
    }
}
