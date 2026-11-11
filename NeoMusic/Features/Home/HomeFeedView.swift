import SwiftUI
import UIKit

enum HomeMetrics {
    static let margin: CGFloat = 20
    static let cardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 32
    static let headingHeight: CGFloat = 24
    static let headingSpacing: CGFloat = 14
    static let artworkSize: CGFloat = 161
    static let heroWidth: CGFloat = 248
    static let heroHeight: CGFloat = 330
}

struct HomeFeedView: View {
    let model: HomeContentModel
    @Environment(\.openLibraryRoute) private var openRoute
    @State private var quickActionScrollID: HomeQuickAction?
    @State private var quickActionSource: (() -> UIView?)?
    @State private var artworkSources = LibraryArtworkSources()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: HomeMetrics.sectionSpacing) {
                if model.isGuest {
                    HStack(spacing: 16) {
                        Text("登录，发现为你推荐的音乐").font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("登录", action: model.login).font(.subheadline.weight(.semibold))
                    }.padding(.horizontal, HomeMetrics.margin)
                }
                if !model.quickActions.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: HomeMetrics.cardSpacing) {
                            ForEach(model.quickActions) { item in
                                HomeQuickActionCard(item: item, state: model.quickActionStates[item.action] ?? .idle,
                                                    sources: artworkSources, sourceID: "\(model.navigationOwnerID ?? "public"):quick:\(item.id)",
                                                    captureSource: { quickActionSource = $0 }) {
                                    model.performQuickAction(item.action)
                                }
                            }
                        }.scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                    .scrollPosition(id: $quickActionScrollID, anchor: .leading)
                    .accessibilityIdentifier("home.quick-actions")
                }
                ForEach(model.feedIssues.filter { $0.sectionID == nil }) { issue in
                    HomeFeedIssueRow(issue: issue) { await model.retryIssue(issue.id) }
                        .padding(.horizontal, HomeMetrics.margin)
                }
                ForEach(model.sections) { section in
                    let issue = model.feedIssues.first { $0.sectionID == section.id }
                    HomeContentShelf(section: section, issue: issue, ownerID: model.navigationOwnerID, sources: artworkSources,
                                     prepareNavigation: model.prepareNavigation,
                                     retry: { if let issue { await model.retryIssue(issue.id) } }) { item in
                        model.play(section.id, item.id)
                    }
                }
                if model.isLoading && model.sections.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.top, 15)
            .padding(.bottom, 24)
        }
        .refreshable { await model.refresh() }
        .onChange(of: model.quickActionRoute, initial: true) { _, route in
            guard let route else { return }
            let sourceProvider = quickActionSource
            let preview = model.quickActionPreview
            model.quickActionRoute = nil
            model.quickActionPreview = nil
            quickActionSource = nil
            if let preview { openRoute(route, preview: preview, sourceProvider: sourceProvider ?? { nil }) }
            else if let sourceProvider { openRoute(route, sourceProvider: sourceProvider) }
            else { openRoute(route) }
        }
        .accessibilityIdentifier("home.feed")
        .background(Color(.systemBackground))
        .libraryNavigationTitle("主页")
        .libraryHomeNavigation(title: "主页")
        .toolbar { AccountToolbar() }
    }

}

struct HomeQuickActionCard: View {
    let item: HomeQuickActionItem
    let state: HomeQuickActionState
    var sources: LibraryArtworkSources? = nil
    var sourceID: String? = nil
    var captureSource: (@escaping () -> UIView?) -> Void = { _ in }
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .caption) private var eyebrowSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var subtitleSize: CGFloat = 13
    @State private var localSources = LibraryArtworkSources()
    private var artworkSources: LibraryArtworkSources { sources ?? localSources }
    private var sourceIdentity: String { sourceID ?? "quick:\(item.id)" }

    private var isLoading: Bool { state == .loading }
    private var accessibilityStatus: String {
        switch state {
        case .idle: item.subtitle
        case .loading: item.action.loadingMessage
        case .failed(let error): "\(error)，轻点重试"
        }
    }
    private var accessibilityHint: String {
        if case .failed = state { return "重新尝试\(item.action.title)" }
        return item.action.accessibilityHint
    }

    var body: some View {
        cardButton
        .disabled(isLoading)
        .accessibilityLabel(item.action.title)
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("home.quick-action.\(item.action.rawValue)")
    }

    @ViewBuilder private var cardButton: some View {
        let button = Button(action: activate) {
            cover
                .clipShape(.rect(cornerRadius: 16))
                .background {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 12)
                }
                .contentShape(.rect(cornerRadius: 16))
        }
        if item.action.opensDetail {
            button.buttonStyle(.plain)
        } else {
            button.buttonStyle(HomePlaybackCardButtonStyle())
        }
    }

    private func activate() {
        if !item.action.opensDetail { LibraryHaptics.impact() }
        captureSource { [sources = artworkSources, id = sourceIdentity] in sources.view(for: id) }
        action()
    }

    private var cover: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: textSize.isAccessibilitySize ? 90 : 0)
            Text(item.action.eyebrow)
                .font(.system(size: eyebrowSize))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(textSize.isAccessibilitySize ? nil : 1)
            Text(item.action.title).font(.title2.bold()).lineLimit(textSize.isAccessibilitySize ? nil : 2)
            switch state {
            case .idle:
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: subtitleSize))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                }
            case .loading:
                Text(item.action.loadingMessage)
                    .font(.system(size: subtitleSize))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(textSize.isAccessibilitySize ? nil : 2)
            case .failed(let error):
                Text(error).font(.system(size: subtitleSize)).lineLimit(textSize.isAccessibilitySize ? nil : 3)
                Text("轻点重试").font(.system(size: subtitleSize, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.leading)
        .padding(16)
        .frame(width: HomeMetrics.heroWidth, alignment: .leading)
        .frame(minHeight: HomeMetrics.heroHeight, alignment: .bottomLeading)
        .background {
            LibraryCardArtwork(content: AnyView(HomeQuickActionArtwork(item: item).id(sourceIdentity)), sources: artworkSources, sourceID: sourceIdentity, cornerRadius: 16)
                .overlay { LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom) }
        }
    }
}

struct HomeFeedIssueRow: View {
    let issue: HomeFeedIssue
    let retry: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(issue.isRetrying ? "正在重新载入\(issue.title)" : issue.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(issue.isRetrying ? "正在重试" : "重试") { Task { await retry() } }
                .font(.subheadline.weight(.semibold))
                .disabled(issue.isRetrying)
                .accessibilityLabel("重试\(issue.title)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.issue.\(issue.id)")
    }
}

/// 直接播放的首页卡不使用按钮按下时的变暗。
private struct HomePlaybackCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

private struct HomeQuickActionArtwork: View {
    let item: HomeQuickActionItem

    var body: some View {
        Group {
            if let artwork = item.artwork {
                HomePlaylistArtwork(artwork: artwork)
            } else {
                Color(.secondarySystemFill)
            }
        }.accessibilityHidden(true)
    }
}

private struct HomeContentShelf: View {
    let section: HomeContentSection
    let issue: HomeFeedIssue?
    let ownerID: String?
    let sources: LibraryArtworkSources
    let prepareNavigation: (LibraryNavigationPreview) -> Void
    let retry: () async -> Void
    let play: (HomeContentItem) -> Void
    @ScaledMetric(relativeTo: .title3) private var headingSize: CGFloat = 20
    private var songGroups: [[HomeContentItem]] {
        var groups: [[HomeContentItem]] = []
        for item in section.items {
            if let last = groups.last, last.count < 3, last.first?.groupID == item.groupID {
                groups[groups.count - 1].append(item)
            } else { groups.append([item]) }
        }
        return groups
    }
    var body: some View {
        VStack(alignment: .leading, spacing: HomeMetrics.headingSpacing) {
            if !section.title.isEmpty {
                Text(section.title).font(.system(size: headingSize, weight: .bold))
                    .padding(.horizontal, HomeMetrics.margin)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("home.heading.\(section.id)")
            }
            if !section.items.isEmpty {
                if section.kind == .songs || section.kind == .hero {
                    scrollContent.scrollTargetBehavior(.viewAligned)
                } else {
                    scrollContent
                }
            }
            if let issue {
                HomeFeedIssueRow(issue: issue, retry: retry)
                    .padding(.horizontal, HomeMetrics.margin)
            }
        }
    }
    private var scrollContent: some View {
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: HomeMetrics.cardSpacing) {
                    if section.kind == .songs {
                        ForEach(songGroups, id: \.first!.id) { group in
                            VStack(spacing: 0) {
                                ForEach(group) { item in
                                    HomeSongRecommendationRow(item: item, ownerID: ownerID, prepareNavigation: prepareNavigation) { play(item) }
                                    if item.id != group.last?.id { Divider().padding(.leading, 60) }
                                }
                            }.containerRelativeFrame(.horizontal, count: 1, spacing: 32)
                                .padding(.trailing, 12)
                        }
                    } else {
                        ForEach(section.items) { item in
                            HomeContentCard(item: item, large: section.kind == .hero, ownerID: ownerID,
                                            sources: sources, sourceID: "\(ownerID ?? "public"):\(section.id):\(item.id)",
                                            prepareNavigation: prepareNavigation) { play(item) }
                        }
                    }
                }.scrollTargetLayout()
            }
            .contentMargins(.horizontal, HomeMetrics.margin, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .accessibilityIdentifier("home.shelf.\(section.id)")
    }

}

private struct HomeSongRecommendationRow: View {
    let item: HomeContentItem
    let ownerID: String?
    let prepareNavigation: (LibraryNavigationPreview) -> Void
    let play: () -> Void
    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        Button {
            switch item.action {
            case .navigate(let route):
                let preview = LibraryNavigationPreview(route: route, ownerID: ownerID, title: item.title, subtitle: item.subtitle, artwork: item.artwork)
                prepareNavigation(preview)
                openRoute(route, preview: preview, sourceProvider: { nil })
            case .playSong: play()
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkView(artwork: item.artwork, contentID: "\(ownerID ?? "public"):\(item.id)", cornerRadius: 6).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                }
                Spacer(minLength: 0)
            }.frame(minHeight: 64).fixedSize(horizontal: false, vertical: true).contentShape(.rect)
        }.buttonStyle(.plain)
            .accessibilityIdentifier("home.item.\(item.id)")
    }
}

private struct HomeContentCard: View {
    let item: HomeContentItem
    let large: Bool
    let ownerID: String?
    let sources: LibraryArtworkSources
    let sourceID: String
    let prepareNavigation: (LibraryNavigationPreview) -> Void
    let play: () -> Void
    @Environment(\.openLibraryRoute) private var openRoute
    @Environment(\.displayScale) private var displayScale
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .caption) private var eyebrowSize: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var subtitleSize: CGFloat = 13

    var body: some View {
        Button {
            switch item.action {
            case .navigate(let route):
                let preview = LibraryNavigationPreview(route: route, ownerID: ownerID, title: item.title, subtitle: item.subtitle, artwork: item.artwork)
                prepareNavigation(preview)
                openRoute(route, preview: preview, sourceProvider: { [sources, sourceID] in sources.view(for: sourceID) })
            case .playSong: play()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                cover
                    .frame(width: large ? HomeMetrics.heroWidth : HomeMetrics.artworkSize,
                           height: large ? nil : HomeMetrics.artworkSize)
                    .clipShape(.rect(cornerRadius: large ? 16 : 8))
                    .overlay { if !large { RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.10), lineWidth: 1 / displayScale) } }
                    .background {
                        if large {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemBackground))
                                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 12)
                        }
                    }
                if !large {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.subheadline).foregroundStyle(.primary).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                        if !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                        }
                    }
                }
            }.frame(width: large ? HomeMetrics.heroWidth : HomeMetrics.artworkSize, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title)，\(item.subtitle)")
        .accessibilityIdentifier("home.item.\(item.id)")
    }

    @ViewBuilder private var cover: some View {
        if large {
            VStack(spacing: 0) {
                Spacer(minLength: textSize.isAccessibilitySize ? 90 : 0)
                caption
            }
            .frame(width: HomeMetrics.heroWidth)
            .frame(minHeight: HomeMetrics.heroHeight, alignment: .bottomLeading)
            .background {
                LibraryCardArtwork(content: AnyView(artwork), sources: sources, sourceID: sourceID, cornerRadius: 16)
            }
        } else {
            LibraryCardArtwork(content: AnyView(artwork), sources: sources, sourceID: sourceID, cornerRadius: large ? 16 : 8)
        }
    }

    private var artwork: some View {
        Group {
            switch item.style {
            case .favorites: HomeArtwork(artwork: .favorites)
            case .daily, .artwork:
                if large {
                    HomePlaylistArtwork(artwork: item.artwork).id(sourceID)
                } else {
                    ArtworkView(artwork: item.artwork, contentID: sourceID, cornerRadius: 0)
                        .environment(\.nativeArtworkSurfaceEnabled, false)
                }
            }
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow = item.eyebrow, !eyebrow.isEmpty {
                Text(eyebrow).font(.system(size: eyebrowSize)).foregroundStyle(.white.opacity(0.75)).lineLimit(textSize.isAccessibilitySize ? nil : 1)
            }
            if item.style != .daily { Text(item.title).font(.title2.bold()).lineLimit(textSize.isAccessibilitySize ? nil : 2) }
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: subtitleSize)).foregroundStyle(.white.opacity(0.8)).lineLimit(textSize.isAccessibilitySize ? nil : 1)
            }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(.white)
        .frame(width: HomeMetrics.heroWidth - 32, alignment: .leading)
        .padding(16)
    }
}
