import FrontAMNavigation
import SwiftUI

enum AppTab: Hashable, Identifiable, RawRepresentable, Sendable {
    case home, library, favorites, playlists, albums, artists, songs, search
    case playlist(String)

    var id: String { rawValue }
    var rawValue: String {
        switch self {
        case .home: "home"
        case .library: "library"
        case .favorites: "favorites"
        case .playlists: "playlists"
        case .albums: "albums"
        case .artists: "artists"
        case .songs: "songs"
        case .search: "search"
        case .playlist(let id): "playlist:\(id)"
        }
    }
    init?(rawValue: String) {
        switch rawValue {
        case "home": self = .home
        case "library": self = .library
        case "favorites": self = .favorites
        case "playlists": self = .playlists
        case "albums": self = .albums
        case "artists": self = .artists
        case "songs": self = .songs
        case "search": self = .search
        default:
            guard rawValue.hasPrefix("playlist:") else { return nil }
            let id = String(rawValue.dropFirst("playlist:".count))
            guard !id.isEmpty, !id.contains(",") else { return nil }
            self = .playlist(id)
        }
    }
    var title: String {
        switch self {
        case .home: "主页"
        case .library: "资料库"
        case .favorites: "喜爱歌曲"
        case .playlists: "播放列表"
        case .albums: "专辑"
        case .artists: "艺人"
        case .songs: "歌曲"
        case .search: "搜索"
        case .playlist: "播放列表"
        }
    }
    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .library: "music.note.square.stack.fill"
        case .favorites: "star.fill"
        case .playlists, .playlist: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.microphone"
        case .songs: "music.note"
        case .search: "magnifyingglass"
        }
    }
    var rootRoute: LibraryRoute? {
        switch self {
        case .favorites: .playlist("favorites")
        case .playlists: .category(.playlists)
        case .albums: .category(.albums)
        case .artists: .category(.artists)
        case .songs: .category(.songs)
        case .playlist(let id): .playlist(id)
        case .home, .library, .search: nil
        }
    }
    static let defaultOrder: [AppTab] = [.home, .library, .search]
    static let reorderable: [AppTab] = [.home, .library, .favorites, .playlists, .albums, .artists, .songs]
}

@MainActor
final class AppTabNavigationRegistry {
    private let registry: FrontAMTabNavigations<AppTab, LibraryRoute, LibraryNavigationPreview>

    init(initialTabs: [AppTab] = AppTab.reorderable + [.search]) {
        registry = FrontAMTabNavigations(initialTabs: initialTabs, makeNavigation: { LibraryDetailNavigation() })
    }

    var items: [String: LibraryDetailNavigation] {
        Dictionary(uniqueKeysWithValues: registry.navigations.compactMap { key, navigation in
            guard case .playlist(let id) = key else { return nil }
            return (id, navigation)
        })
    }

    func navigation(for tab: AppTab) -> LibraryDetailNavigation { registry.navigation(for: tab) }
    func bridge(for id: String) -> LibraryDetailNavigation { navigation(for: .playlist(id)) }
    func colorScheme(for tab: AppTab) -> ColorScheme? { registry.colorScheme(for: tab) }
    func prunePlaylists(keeping liveIDs: Set<String>) {
        registry.removeTabs {
            guard case .playlist(let id) = $0 else { return false }
            return !liveIDs.contains(id)
        }
    }
}

struct AppTabPlaylist: Equatable, Identifiable {
    let id: String
    var title: String
}

enum AppTabOrder {
    static let storageKey = AppDefaultsKey.appTabOrder
    static let hiddenKey = AppDefaultsKey.appTabHidden
    static var storage: FrontAMTabStorage { FrontAMTabStorage(orderKey: storageKey, hiddenKey: hiddenKey) }
    static let maxVisible = 4
    static let defaultHidden: Set<AppTab> = [.favorites, .playlists, .albums, .artists, .songs]
    static var defaultRaw: String { raw([.home, .library]) }

    private static let policy = FrontAMTabOrder(fixed: [.search], reorderable: AppTab.reorderable,
        fallback: .library, maxVisible: maxVisible, defaultHidden: defaultHidden,
        decode: AppTab.init(rawValue:), encode: { $0.rawValue })

    private static func additional(_ playlists: [String]) -> [AppTab] {
        playlists.filter { !$0.isEmpty && !$0.contains(",") }.map(AppTab.playlist)
    }

    static func resolve(_ raw: String, playlists: [String] = []) -> [AppTab] {
        policy.resolve(raw, additional: additional(playlists))
    }

    static func effectiveHidden(order: String, hidden: String?, playlists: [String] = []) -> Set<AppTab> {
        policy.effectiveHidden(order: order, hidden: hidden, additional: additional(playlists))
    }

    static func visible(order: String, hidden: String?, playlists: [String] = []) -> [AppTab] {
        policy.visible(order: order, hidden: hidden, additional: additional(playlists))
    }

    static func displayed(order: String, hidden: String? = nil, playlists: [String] = []) -> [AppTab] {
        policy.displayed(order: order, hidden: hidden, additional: additional(playlists))
    }

    static func raw(_ tabs: some Sequence<AppTab>) -> String { policy.raw(tabs) }
}
