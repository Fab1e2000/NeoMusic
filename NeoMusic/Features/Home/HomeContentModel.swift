import SwiftUI
import Observation

enum HomeContentStyle: Equatable { case artwork, favorites, daily }

enum HomeQuickAction: String, CaseIterable, Identifiable {
    case dailySongs, hotSongs, heartMode, privateRadar, privateRoaming, similarSongs

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dailySongs: "每日推荐"
        case .hotSongs: "热歌"
        case .heartMode: "心动模式"
        case .privateRadar: "私人雷达"
        case .privateRoaming: "私人漫游"
        case .similarSongs: "相似歌曲"
        }
    }
    var eyebrow: String {
        switch self {
        case .dailySongs: "为你推荐"
        case .hotSongs: "榜单精选"
        case .heartMode: "从喜欢出发"
        case .privateRadar: "你的音乐雷达"
        case .privateRoaming: "探索更多音乐"
        case .similarSongs: "从当前歌曲出发"
        }
    }
    /// 每日推荐、热歌和私人雷达进入独立页面。其余三张直接播放。
    var opensDetail: Bool {
        switch self {
        case .dailySongs, .hotSongs, .privateRadar: true
        case .heartMode, .privateRoaming, .similarSongs: false
        }
    }
}

struct HomeQuickActionItem: Identifiable, Equatable {
    let action: HomeQuickAction
    var artwork: Artwork? = nil
    var subtitle: String
    var id: HomeQuickAction { action }
}

enum HomeQuickActionState: Equatable {
    case idle, loading, failed(String)
}

enum HomeContentAction: Equatable {
    case navigate(LibraryRoute), playSong
}

struct HomeContentItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    var artwork: Artwork
    var style: HomeContentStyle = .artwork
    var eyebrow: String? = nil
    var groupID: String? = nil
    var action: HomeContentAction
}

struct HomeContentSection: Identifiable, Equatable {
    enum Kind: Equatable { case hero, songs, covers }
    let id: String
    let title: String
    let kind: Kind
    var items: [HomeContentItem]
}

@MainActor @Observable final class HomeContentModel {
    var quickActions: [HomeQuickActionItem] = []
    var quickActionStates: [HomeQuickAction: HomeQuickActionState] = [:]
    var quickActionRoute: LibraryRoute?
    var quickActionPreview: LibraryNavigationPreview?
    var navigationOwnerID: String?
    var prepareNavigation: (LibraryNavigationPreview) -> Void = { _ in }
    var performQuickAction: (HomeQuickAction) -> Void = { _ in }
    var sections: [HomeContentSection] = []
    var isLoading = false
    var feedError: String?
    var refresh: () async -> Void = {}
    var play: (String, String) -> Void = { _, _ in }

    var featured: [HomeContentItem] = []
    var recent: [HomeContentItem] = []
    var recommendations: [HomeContentItem] = []
    var isGuest = true
    var featuredError: String?
    var recommendationsError: String?
    var login: () -> Void = {}
    var retryFeatured: () -> Void = {}
    var retryRecommendations: () -> Void = {}
}
