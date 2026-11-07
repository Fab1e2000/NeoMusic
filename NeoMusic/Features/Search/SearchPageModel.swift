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
