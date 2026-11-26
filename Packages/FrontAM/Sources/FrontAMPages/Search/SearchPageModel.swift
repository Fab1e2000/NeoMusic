import FrontAMCore
import SwiftUI

public enum MusicSearchKind: Int, CaseIterable, Identifiable {
    case combined = 1018, song = 1, artist = 100, album = 10, playlist = 1000
    public var id: Self { self }
    public var title: String { switch self { case .combined: "综合"; case .song: "歌曲"; case .artist: "艺人"; case .album: "专辑"; case .playlist: "歌单" } }
}
public struct MusicSearchItem: Identifiable, Equatable {
    public let id: String
    public let kind: MusicSearchKind
    public let title: String
    public let subtitle: String
    @ArtworkResource public var artwork: Artwork
    public var song: LibrarySongItem?
    public var route: LibraryRoute?

    public init(id: String,
                kind: MusicSearchKind,
                title: String,
                subtitle: String,
                artwork: Artwork,
                song: LibrarySongItem? = nil,
                route: LibraryRoute? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.song = song
        self.route = route
    }
}
public struct MusicSearchGroup: Identifiable, Equatable {
    public let kind: MusicSearchKind
    public var items: [MusicSearchItem]
    public var hasMore = false
    public var id: MusicSearchKind { kind }

    public init(kind: MusicSearchKind,
                items: [MusicSearchItem],
                hasMore: Bool = false) {
        self.kind = kind
        self.items = items
        self.hasMore = hasMore
    }
}
public struct MusicSearchCategory: Identifiable, Equatable {
    public let id: String
    public let title: String
    public var colorIndex = 0
    public var group: Int? = nil
    public var isHot = false

    public init(id: String,
                title: String,
                colorIndex: Int = 0,
                group: Int? = nil,
                isHot: Bool = false) {
        self.id = id
        self.title = title
        self.colorIndex = colorIndex
        self.group = group
        self.isHot = isHot
    }
}

public struct MusicSearchCategorySection: Identifiable, Equatable {
    public let id: String
    public let title: String?
    public let items: [MusicSearchCategory]

    public static func sections(for categories: [MusicSearchCategory]) -> [Self] {
        guard categories.contains(where: { $0.group != nil || $0.isHot }) else {
            return categories.isEmpty ? [] : [.init(id: "all", title: nil, items: categories)]
        }
        var sections: [Self] = []
        let hot = categories.filter(\.isHot)
        if !hot.isEmpty { sections.append(.init(id: "hot", title: "热门", items: hot)) }
        let titles = ["语种", "风格", "场景", "情感", "主题"]
        for (group, title) in titles.enumerated() {
            let items = categories.filter { $0.group == group }
            if !items.isEmpty { sections.append(.init(id: "group:\(group)", title: title, items: items)) }
        }
        let others = categories.filter { item in
            guard let group = item.group else { return true }
            return !titles.indices.contains(group)
        }
        if !others.isEmpty { sections.append(.init(id: "other", title: "其他", items: others)) }
        return sections
    }

    public init(id: String,
                title: String? = nil,
                items: [MusicSearchCategory]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct SearchCategoryColor: Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public static let palette: [Self] = [
        .init(red: 221 / 255, green: 170 / 255, blue: 0),
        .init(red: 224 / 255, green: 90 / 255, blue: 126 / 255),
        .init(red: 231 / 255, green: 81 / 255, blue: 52 / 255),
        .init(red: 202 / 255, green: 125 / 255, blue: 47 / 255),
        .init(red: 51 / 255, green: 176 / 255, blue: 112 / 255),
        .init(red: 88 / 255, green: 126 / 255, blue: 236 / 255),
        .init(red: 137 / 255, green: 104 / 255, blue: 218 / 255)
    ]

    public var background: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    public var usesDarkForeground: Bool { blackContrast >= whiteContrast }
    public var foreground: Color { usesDarkForeground ? .black : .white }
    public var contrast: Double { max(blackContrast, whiteContrast) }
    private var blackContrast: Double { (luminance + 0.05) / 0.05 }
    private var whiteContrast: Double { 1.05 / (luminance + 0.05) }
    private var luminance: Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    public init(red: Double,
                green: Double,
                blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

@MainActor @Observable
public final class SearchPageModel {
    public let searchPrompt: String

    public init(searchPrompt: String = "歌曲、艺人、专辑及歌单") {
        self.searchPrompt = searchPrompt
    }

    public var query = ""
    public var kind = MusicSearchKind.combined
    public var isSearching = false
    public var submitted = false
    public var categories: [MusicSearchCategory] = []
    public var keywords: [String] = []
    public var suggestions: [MusicSearchItem] = []
    public var groups: [MusicSearchGroup] = []
    public var cachedGroups: [MusicSearchKind: [MusicSearchGroup]] = [:]
    public var ownerID: String?
    public var history: [String] = []
    public var isLoading = false
    public var isLoadingMore = false
    public var hasMore = false
    public var error: String?
    public var moreError: String?
    public var category: String?
    public var categoryItems: [MusicSearchItem] = []
    public var categoryLoading = false
    public var categoryMoreLoading = false
    public var categoryHasMore = false
    public var categoryError: String?
    public var categoryMoreError: String?
    @ObservationIgnored public var onCategoryRefresh: (@MainActor () async -> Void)?
    @ObservationIgnored public var onCategoryMore: (@MainActor () -> Void)?
    @ObservationIgnored public var onPrepareNavigation: (@MainActor (LibraryNavigationPreview) -> Void)?
    @ObservationIgnored public var onQuery: (@MainActor () -> Void)?
    @ObservationIgnored public var onSubmit: (@MainActor () -> Void)?
    @ObservationIgnored public var onKind: (@MainActor () -> Void)?
    @ObservationIgnored public var onRetry: (@MainActor () -> Void)?
    @ObservationIgnored public var onMore: (@MainActor () -> Void)?
    @ObservationIgnored public var onRefresh: (@MainActor () async -> Void)?
    @ObservationIgnored public var onCategory: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onOpen: (@MainActor (MusicSearchItem) -> Void)?
    @ObservationIgnored public var onRemoveHistory: (@MainActor (String?) -> Void)?

    public func input(_ value: String) {
        guard query != value else { return }
        query = value; cachedGroups = [:]; submitted = false; error = nil; onQuery?()
    }
    public func submit(_ value: String? = nil) {
        if let value, value != query { query = value; cachedGroups = [:] }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        submitted = true; onSubmit?()
    }
    public func select(_ value: MusicSearchKind) { guard kind != value else { return }; kind = value; onKind?() }
    public func resumeEditing() {
        guard submitted else { return }
        submitted = false; onQuery?()
    }
    public func cancel() { isSearching = false; submitted = false; query = ""; onQuery?() }
}
