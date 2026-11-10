import SwiftUI

enum MusicSearchScope: String, CaseIterable, Identifiable { case online = "网易云音乐", library = "资料库"; var id: Self { self } }
enum MusicSearchKind: Int, CaseIterable, Identifiable {
    case combined = 1018, song = 1, artist = 100, album = 10, playlist = 1000
    var id: Self { self }
    var title: String { switch self { case .combined: "综合"; case .song: "歌曲"; case .artist: "艺人"; case .album: "专辑"; case .playlist: "歌单" } }
}
struct MusicSearchItem: Identifiable, Equatable {
    let id: String
    let kind: MusicSearchKind
    let title: String
    let subtitle: String
    var artwork: Artwork
    var song: LibrarySongItem?
    var route: LibraryRoute?
}
struct MusicSearchGroup: Identifiable, Equatable {
    let kind: MusicSearchKind
    var items: [MusicSearchItem]
    var hasMore = false
    var id: MusicSearchKind { kind }
}
struct MusicSearchCategory: Identifiable, Equatable {
    let id: String
    let title: String
    var colorIndex = 0
    var group: Int? = nil
    var isHot = false
}

struct MusicSearchCategorySection: Identifiable, Equatable {
    let id: String
    let title: String?
    let items: [MusicSearchCategory]

    static func sections(for categories: [MusicSearchCategory]) -> [Self] {
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
}

/// The supplied category palette paired with its higher-contrast opaque foreground.
struct SearchCategoryColor {
    let red: Double
    let green: Double
    let blue: Double

    static let palette: [Self] = [
        .init(red: 221 / 255, green: 170 / 255, blue: 0),
        .init(red: 224 / 255, green: 90 / 255, blue: 126 / 255),
        .init(red: 231 / 255, green: 81 / 255, blue: 52 / 255),
        .init(red: 202 / 255, green: 125 / 255, blue: 47 / 255),
        .init(red: 51 / 255, green: 176 / 255, blue: 112 / 255),
        .init(red: 88 / 255, green: 126 / 255, blue: 236 / 255),
        .init(red: 137 / 255, green: 104 / 255, blue: 218 / 255)
    ]

    var background: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var usesDarkForeground: Bool { blackContrast >= whiteContrast }
    var foreground: Color { usesDarkForeground ? .black : .white }
    var contrast: Double { max(blackContrast, whiteContrast) }
    private var blackContrast: Double { (luminance + 0.05) / 0.05 }
    private var whiteContrast: Double { 1.05 / (luminance + 0.05) }
    private var luminance: Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

/// Presentation state only. Online requests and account ownership are supplied by assembly.
@MainActor @Observable
final class SearchPageModel {
    var query = ""
    var scope = MusicSearchScope.online
    var kind = MusicSearchKind.combined
    var isSearching = false
    var submitted = false
    var categories: [MusicSearchCategory] = []
    var keywords: [String] = []
    var suggestions: [MusicSearchItem] = []
    var groups: [MusicSearchGroup] = []
    var cachedGroups: [MusicSearchKind: [MusicSearchGroup]] = [:]
    var ownerID: String?
    var history: [String] = []
    var isLoading = false
    var isLoadingMore = false
    var hasMore = false
    var error: String?
    var moreError: String?
    var syncStatus: String?
    var syncFailed = false
    var category: String?
    var categoryItems: [MusicSearchItem] = []
    var categoryLoading = false
    var categoryMoreLoading = false
    var categoryHasMore = false
    var categoryError: String?
    var categoryMoreError: String?
    @ObservationIgnored var onCategoryRefresh: (@MainActor () async -> Void)?
    @ObservationIgnored var onCategoryMore: (@MainActor () -> Void)?
    @ObservationIgnored var onPrepareNavigation: (@MainActor (LibraryNavigationPreview) -> Void)?
    @ObservationIgnored var onQuery: (@MainActor () -> Void)?
    @ObservationIgnored var onSubmit: (@MainActor () -> Void)?
    @ObservationIgnored var onScope: (@MainActor () -> Void)?
    @ObservationIgnored var onKind: (@MainActor () -> Void)?
    @ObservationIgnored var onRetry: (@MainActor () -> Void)?
    @ObservationIgnored var onMore: (@MainActor () -> Void)?
    @ObservationIgnored var onRefresh: (@MainActor () async -> Void)?
    @ObservationIgnored var onCategory: (@MainActor (String) -> Void)?
    @ObservationIgnored var onArtwork: (@MainActor (String) -> Void)?
    @ObservationIgnored var onOpen: (@MainActor (MusicSearchItem) -> Void)?
    @ObservationIgnored var onRemoveHistory: (@MainActor (String?) -> Void)?

    func input(_ value: String) {
        guard query != value else { return }
        query = value; cachedGroups = [:]; submitted = false; error = nil; onQuery?()
    }
    func submit(_ value: String? = nil) {
        if let value, value != query { query = value; cachedGroups = [:] }
        query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        submitted = true; onSubmit?()
    }
    func select(_ value: MusicSearchKind) { guard kind != value else { return }; kind = value; onKind?() }
    func selectScope(_ value: MusicSearchScope) { guard scope != value else { return }; scope = value; onScope?() }
    func resumeEditing() {
        guard submitted else { return }
        submitted = false; onQuery?()
    }
    func cancel() { isSearching = false; submitted = false; query = ""; onQuery?() }
}
