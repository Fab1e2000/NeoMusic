import Foundation

/// Unified parser and formatter for online song identities (`netease:<owner>:<songID>`).
enum OnlineSongIdentity: Equatable, Hashable, Sendable {
    static func parse(_ id: String) -> (owner: Int64, song: Int64)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "netease",
              let owner = Int64(parts[1]), let song = Int64(parts[2]) else { return nil }
        return (owner, song)
    }

    static func parseOwnerAndSong(_ id: String) -> (ownerID: String, songID: Int64)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "netease", !parts[1].isEmpty,
              let song = Int64(parts[2]) else { return nil }
        return (String(parts[1]), song)
    }

    static func format(owner: Int64, song: Int64) -> String {
        "netease:\(owner):\(song)"
    }

    static func format(ownerID: String, song: Int64) -> String {
        "netease:\(ownerID):\(song)"
    }

    static func format(ownerID: String?, guestPrefix: String, song: Int64) -> String {
        if let ownerID { return "netease:\(ownerID):\(song)" }
        return "\(guestPrefix):\(song)"
    }
}

/// Structured representation of playlist route identifiers across local, account, home, and downloaded scopes.
enum PlaylistRouteIdentity: Equatable, Hashable, Sendable {
    case favorites
    case account(ownerID: String, playlistID: Int64)
    case homePlaylist(playlistID: Int64)
    case daily(ownerID: String, date: String)
    case downloaded(playlistID: Int64)
    case local(id: String)

    init(_ rawValue: String) {
        if rawValue == "favorites" {
            self = .favorites
            return
        }
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "netease-playlist", !parts[1].isEmpty, let id = Int64(parts[2]) {
            self = .account(ownerID: String(parts[1]), playlistID: id)
        } else if parts.count == 3, parts[0] == "home", parts[1] == "playlist", let id = Int64(parts[2]) {
            self = .homePlaylist(playlistID: id)
        } else if parts.count == 4, parts[0] == "home", parts[1] == "daily", !parts[2].isEmpty, !parts[3].isEmpty {
            self = .daily(ownerID: String(parts[2]), date: String(parts[3]))
        } else if parts.count == 3, parts[0] == "downloaded", parts[1] == "playlist", let id = Int64(parts[2]) {
            self = .downloaded(playlistID: id)
        } else {
            self = .local(id: rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .favorites: "favorites"
        case .account(let ownerID, let playlistID): "netease-playlist:\(ownerID):\(playlistID)"
        case .homePlaylist(let playlistID): "home:playlist:\(playlistID)"
        case .daily(let ownerID, let date): "home:daily:\(ownerID):\(date)"
        case .downloaded(let playlistID): "downloaded:playlist:\(playlistID)"
        case .local(let id): id
        }
    }

    var onlinePlaylistNumber: Int64? {
        switch self {
        case .account(_, let id), .homePlaylist(let id), .downloaded(let id): id
        case .favorites, .daily, .local: nil
        }
    }

    var isHomeRoute: Bool {
        switch self {
        case .homePlaylist, .daily: true
        default: false
        }
    }

    static func accountID(owner: some CustomStringConvertible, playlistID: some CustomStringConvertible) -> String {
        "netease-playlist:\(owner):\(playlistID)"
    }

    static func homePlaylistID(_ playlistID: some CustomStringConvertible) -> String {
        "home:playlist:\(playlistID)"
    }

    static func dailyID(owner: some CustomStringConvertible, date: String) -> String {
        "home:daily:\(owner):\(date)"
    }

    static func downloadedID(_ playlistID: some CustomStringConvertible) -> String {
        "downloaded:playlist:\(playlistID)"
    }
}

/// Structured representation of online catalog artist and album identifiers (`catalog:artist:<id>`, `catalog:album:<id>`).
enum CatalogRouteIdentity: Equatable, Hashable, Sendable {
    case artist(Int64)
    case album(Int64)

    init?(_ rawValue: String) {
        if rawValue.hasPrefix("catalog:artist:"), let id = Int64(rawValue.dropFirst("catalog:artist:".count)) {
            self = .artist(id)
        } else if rawValue.hasPrefix("catalog:album:"), let id = Int64(rawValue.dropFirst("catalog:album:".count)) {
            self = .album(id)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .artist(let id): Self.artistID(id)
        case .album(let id): Self.albumID(id)
        }
    }

    var itemID: Int64 {
        switch self {
        case .artist(let id), .album(let id): id
        }
    }

    static func isCatalogID(_ id: String) -> Bool {
        id.hasPrefix("catalog:")
    }

    static func artistID(_ id: some CustomStringConvertible) -> String {
        "catalog:artist:\(id)"
    }

    static func albumID(_ id: some CustomStringConvertible) -> String {
        "catalog:album:\(id)"
    }

    static func parseAlbumID(_ id: String) -> Int64? {
        guard case .album(let value) = CatalogRouteIdentity(id) else { return nil }
        return value
    }

    static func parseArtistID(_ id: String) -> Int64? {
        guard case .artist(let value) = CatalogRouteIdentity(id) else { return nil }
        return value
    }
}

/// Structured key for deferred artwork loading (`<domain>:<session>:<payload>`).
struct DeferredArtworkKey: Equatable, Hashable, Sendable {
    enum Domain: String, Equatable, Hashable, Sendable {
        case music
        case home
        case homePlaylist = "home-playlist"
        case artists
        case search = "search-artwork"
    }

    let domain: Domain
    let session: String
    let payload: String

    init(domain: Domain, session: UUID, url: URL) {
        self.domain = domain
        self.session = session.uuidString
        self.payload = url.absoluteString
    }

    init(domain: Domain, session: UUID, playlistID: Int64) {
        self.domain = domain
        self.session = session.uuidString
        self.payload = String(playlistID)
    }

    init(domain: Domain, session: String, payload: String) {
        self.domain = domain
        self.session = session
        self.payload = payload
    }

    init?(rawValue: String) {
        guard let firstColon = rawValue.firstIndex(of: ":") else { return nil }
        let domainPart = String(rawValue[..<firstColon])
        guard let domain = Domain(rawValue: domainPart) else { return nil }
        let remainder = rawValue[rawValue.index(after: firstColon)...]
        guard let secondColon = remainder.firstIndex(of: ":") else { return nil }
        let session = String(remainder[..<secondColon])
        let payload = String(remainder[remainder.index(after: secondColon)...])
        guard !session.isEmpty, !payload.isEmpty else { return nil }
        self.domain = domain
        self.session = session
        self.payload = payload
    }

    var rawValue: String {
        "\(domain.rawValue):\(session):\(payload)"
    }

    var remoteURL: URL? {
        URL(string: payload)
    }

    var playlistID: Int64? {
        Int64(payload)
    }

    func matches(domain expectedDomain: Domain, session expectedSession: UUID) -> Bool {
        domain == expectedDomain && session == expectedSession.uuidString
    }
}
