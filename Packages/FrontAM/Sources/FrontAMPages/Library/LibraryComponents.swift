import FrontAMCore
import SwiftUI

public struct LibraryCollectionGrid<Content: View>: View {
    public let rowSpacing: CGFloat
    public var columnAlignment: Alignment? = .top
    public var alignment: HorizontalAlignment = .leading
    @ViewBuilder public var content: Content
    @Environment(\.dynamicTypeSize) private var textSize

    public var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: columnAlignment),
                                 count: textSize.isAccessibilitySize ? 1 : 2),
                  alignment: alignment, spacing: rowSpacing) {
            content
        }
    }
}

public struct PlayShuffleButtons: View {
    public let play: () -> Void
    public let shuffle: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    public var body: some View {
        let layout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 16))
        layout {
            button("播放", systemImage: "play.fill", action: play)
            button("随机播放", systemImage: "shuffle", action: shuffle)
        }
    }

    private func button(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).accessibilityHidden(true)
                Text(title)
            }
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.vertical, textSize.isAccessibilitySize ? 10 : 0)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color(.tertiarySystemFill), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }

    public init(play: @escaping () -> Void,
                shuffle: @escaping () -> Void) {
        self.play = play
        self.shuffle = shuffle
    }
}

public struct AlbumCard: View {
    public let item: LibraryShelfItem
    @Environment(\.dynamicTypeSize) private var textSize

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(artwork: item.artwork, contentID: item.id, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.title).lineLimit(textSize.isAccessibilitySize ? nil : 1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("已喜爱")
                    }
                }
                .font(.footnote.weight(.medium))
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    public init(item: LibraryShelfItem) {
        self.item = item
    }
}

public struct LibraryNavigationPreview: Equatable {
    public let route: LibraryRoute
    public let ownerID: String?
    public let title: String
    public var subtitle: String? = nil
    public let artwork: Artwork
    public let albumBackdrop: AlbumArtworkBackdrop?
    public var backdropFile: URL?
    public var requiresMatchingAccount = false

    public func matches(owner: String?) -> Bool {
        ownerID == owner || (ownerID == nil && !requiresMatchingAccount)
    }

    public var contentID: String { "\(ownerID ?? "public"):\(route)" }

    @MainActor public init(route: LibraryRoute, ownerID: String?, title: String, subtitle: String? = nil,
                    artwork: Artwork, albumBackdrop: AlbumArtworkBackdrop? = nil, originalArtwork: Artwork? = nil) {
        self.route = route
        self.ownerID = ownerID
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        switch route {
        case .album, .libraryArtistAlbum, .playlist:
            let source = originalArtwork ?? artwork
            self.albumBackdrop = albumBackdrop ?? FrontAMLocalArtworkProvider.shared.cachedBackdrop(for: source)
            self.backdropFile = source.resolvedFileURL
        default: self.albumBackdrop = nil
        }
    }
}

public struct OpenLibraryRouteAction {
    public let handler: (LibraryRoute) -> Void
    public var previewHandler: ((LibraryRoute, LibraryNavigationPreview) -> Void)?
    public func callAsFunction(_ route: LibraryRoute, preview: LibraryNavigationPreview?) {
        if let preview, let previewHandler { previewHandler(route, preview) }
        else { handler(route) }
    }
    public var sourceHandler: ((LibraryRoute, UIView?) -> Void)?
    public var sourceProviderHandler: ((LibraryRoute, @escaping () -> UIView?) -> Void)?
    public var previewSourceHandler: ((LibraryRoute, LibraryNavigationPreview, @escaping () -> UIView?) -> Void)?
    public func callAsFunction(_ route: LibraryRoute, source: UIView? = nil) {
        if let sourceHandler { sourceHandler(route, source) } else { handler(route) }
    }
    public func callAsFunction(_ route: LibraryRoute, sourceProvider: @escaping () -> UIView?) {
        if let sourceProviderHandler { sourceProviderHandler(route, sourceProvider) }
        else { callAsFunction(route, source: sourceProvider()) }
    }
    public func callAsFunction(_ route: LibraryRoute, preview: LibraryNavigationPreview, sourceProvider: @escaping () -> UIView?) {
        if let previewSourceHandler { previewSourceHandler(route, preview, sourceProvider) }
        else { callAsFunction(route, sourceProvider: sourceProvider) }
    }
    @MainActor public func callAsFunction(_ item: LibraryShelfItem, sourceProvider: @escaping () -> UIView?) {
        guard let route = item.route else { return }
        var artwork = item.artwork
        if case .file(let url) = artwork, let image = FrontAMLocalArtworkProvider.shared.cached(url, pixels: 0) {
            artwork = .image(Image(uiImage: image))
        }
        let preview = LibraryNavigationPreview(route: route, ownerID: item.sourceOwnerID,
            title: item.title, subtitle: item.albumArtist ?? item.subtitle, artwork: artwork,
            albumBackdrop: item.albumBackdrop, originalArtwork: item.artwork)
        callAsFunction(route, preview: preview, sourceProvider: sourceProvider)
    }

    public init(handler: @escaping (LibraryRoute) -> Void,
                previewHandler: ((LibraryRoute, LibraryNavigationPreview) -> Void)? = nil,
                sourceHandler: ((LibraryRoute, UIView?) -> Void)? = nil,
                sourceProviderHandler: ((LibraryRoute, @escaping () -> UIView?) -> Void)? = nil,
                previewSourceHandler: ((LibraryRoute, LibraryNavigationPreview, @escaping () -> UIView?) -> Void)? = nil) {
        self.handler = handler
        self.previewHandler = previewHandler
        self.sourceHandler = sourceHandler
        self.sourceProviderHandler = sourceProviderHandler
        self.previewSourceHandler = previewSourceHandler
    }
}

extension EnvironmentValues {
    @Entry public var openLibraryRoute = OpenLibraryRouteAction { _ in }
    @Entry public var libraryNavigationPreview: LibraryNavigationPreview?
}

public struct FavoriteMark: View {
    public let isFavorite: Bool
    public var color: Color = .secondary
    public var leadingOffset: CGFloat = -15

    public var body: some View {
        if isFavorite {
            Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 10, height: 12)
                .offset(x: leadingOffset)
                .accessibilityHidden(true)
        }
    }

    public init(isFavorite: Bool,
                color: Color = .secondary,
                leadingOffset: CGFloat = -15) {
        self.isFavorite = isFavorite
        self.color = color
        self.leadingOffset = leadingOffset
    }
}

public struct TitleSection<Item>: Identifiable {
    public let letter: String
    public let items: [Item]
    public var id: String { letter }

    public static func sortKey(_ title: String) -> String {
        LibraryTitleSortKeys.key(for: title)
    }

    public static func group(_ items: [Item], by title: (Item) -> String) -> [TitleSection] {
        var keyed: [(sortKey: String, item: Item)] = []
        keyed.reserveCapacity(items.count)
        for item in items {
            if Task.isCancelled { return [] }
            keyed.append((sortKey: sortKey(title(item)), item: item))
        }
        keyed.sort { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
        let grouped = Dictionary(grouping: keyed) { entry in
            entry.sortKey.first.map { $0.isASCII && $0.isLetter ? String($0).uppercased() : "#" } ?? "#"
        }
        return grouped.keys
            .sorted { lhs, rhs in lhs == "#" ? false : rhs == "#" ? true : lhs < rhs }
            .map { TitleSection(letter: $0, items: grouped[$0]!.map(\.item)) }
    }
}

private enum LibraryTitleSortKeys {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 2 * 1_024 * 1_024
        return cache
    }()

    static func key(for title: String) -> String {
        if title.utf8.allSatisfy({ $0 < 0x80 }) { return title.lowercased() }
        let source = title as NSString
        if let value = cache.object(forKey: source) { return value as String }
        let key = (title.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? title).lowercased()
        cache.setObject(key as NSString, forKey: source, cost: (title.utf16.count + key.utf16.count) * 2)
        return key
    }
}

public struct CloseLibraryDetailAction {
    public var handler: (() -> Void)?

    public init(handler: (() -> Void)? = nil) {
        self.handler = handler
    }
}

extension EnvironmentValues {
    @Entry public var closeLibraryDetail = CloseLibraryDetailAction()
}
