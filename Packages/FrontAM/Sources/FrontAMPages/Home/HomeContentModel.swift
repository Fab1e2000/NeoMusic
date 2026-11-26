import FrontAMCore
import SwiftUI
import Observation

public enum HomeContentStyle: Equatable { case artwork, favorites, daily }

public enum HomeQuickAction: String, CaseIterable, Identifiable {
    case dailySongs, hotSongs, heartMode, privateRadar, privateRoaming, similarSongs

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .dailySongs: pageText("每日推荐")
        case .hotSongs: pageText("热歌")
        case .heartMode: pageText("心动模式")
        case .privateRadar: pageText("私人雷达")
        case .privateRoaming: pageText("私人漫游")
        case .similarSongs: pageText("相似歌曲")
        }
    }
    public var eyebrow: String {
        switch self {
        case .dailySongs: pageText("为你推荐")
        case .hotSongs: pageText("榜单精选")
        case .heartMode: pageText("从喜欢出发")
        case .privateRadar: pageText("你的音乐雷达")
        case .privateRoaming: pageText("探索更多音乐")
        case .similarSongs: pageText("从当前歌曲出发")
        }
    }
    public var opensDetail: Bool {
        switch self {
        case .dailySongs, .hotSongs, .privateRadar: true
        case .heartMode, .privateRoaming, .similarSongs: false
        }
    }
    public var loadingMessage: String { opensDetail ? pageText("正在载入内容") : pageText("正在准备播放") }
    public var accessibilityHint: String { opensDetail ? pageText("打开歌曲列表") : pageText("开始播放音乐") }
}

public struct HomeQuickActionItem: Identifiable, Equatable {
    public let action: HomeQuickAction
    @ArtworkResource public var artwork: Artwork? = nil
    public var subtitle: String
    public var id: HomeQuickAction { action }

    public init(action: HomeQuickAction,
                artwork: Artwork? = nil,
                subtitle: String) {
        self.action = action
        self.artwork = artwork
        self.subtitle = subtitle
    }
}

public enum HomeQuickActionState: Equatable {
    case idle, loading, failed(String)
}

public enum HomeContentAction: Equatable {
    case navigate(LibraryRoute), playSong
}

public struct HomeContentItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    @ArtworkResource public var artwork: Artwork
    public var style: HomeContentStyle = .artwork
    public var eyebrow: String? = nil
    public var groupID: String? = nil
    public var action: HomeContentAction

    public init(id: String,
                title: String,
                subtitle: String,
                artwork: Artwork,
                style: HomeContentStyle = .artwork,
                eyebrow: String? = nil,
                groupID: String? = nil,
                action: HomeContentAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.style = style
        self.eyebrow = eyebrow
        self.groupID = groupID
        self.action = action
    }
}

public struct HomeContentSection: Identifiable, Equatable {
    public enum Kind: Equatable { case hero, songs, covers }
    public let id: String
    public let title: String
    public let kind: Kind
    public var items: [HomeContentItem]

    public init(id: String,
                title: String,
                kind: Kind,
                items: [HomeContentItem]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.items = items
    }
}

public struct HomeFeedIssue: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let message: String
    public let sectionID: String?
    public var isRetrying = false

    public init(id: String,
                title: String,
                message: String,
                sectionID: String? = nil,
                isRetrying: Bool = false) {
        self.id = id
        self.title = title
        self.message = message
        self.sectionID = sectionID
        self.isRetrying = isRetrying
    }
}

@MainActor @Observable public final class HomeContentModel {
    public init() {}
    public var quickActions: [HomeQuickActionItem] = []
    public var quickActionStates: [HomeQuickAction: HomeQuickActionState] = [:]
    public var quickActionRoute: LibraryRoute?
    public var quickActionPreview: LibraryNavigationPreview?
    public var navigationOwnerID: String?
    public var prepareNavigation: (LibraryNavigationPreview) -> Void = { _ in }
    public var performQuickAction: (HomeQuickAction) -> Void = { _ in }
    public var sections: [HomeContentSection] = []
    public var isLoading = false
    public var feedIssues: [HomeFeedIssue] = []
    public var retryIssue: (String) async -> Void = { _ in }
    public var refresh: () async -> Void = {}
    public var play: (String, String) -> Void = { _, _ in }
    public var isGuest = true
    public var login: () -> Void = {}
}
