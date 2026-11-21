import SwiftUI

struct PlayShuffleButtons: View {
    let play: () -> Void
    let shuffle: () -> Void
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
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
                Image(systemName: systemImage)
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
}

struct AlbumCard: View {
    let item: LibraryShelfItem
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
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
}

struct LibraryNavigationPreview: Equatable {
    let route: LibraryRoute
    let ownerID: String?
    let title: String
    var subtitle: String? = nil
    let artwork: Artwork
    let albumBackdrop: AlbumArtworkBackdrop?
    var contentID: String { "\(ownerID ?? "public"):\(route)" }

    @MainActor init(route: LibraryRoute, ownerID: String?, title: String, subtitle: String? = nil,
                    artwork: Artwork, albumBackdrop: AlbumArtworkBackdrop? = nil) {
        self.route = route
        self.ownerID = ownerID
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        switch route {
        case .album, .playlist:
            self.albumBackdrop = albumBackdrop ?? LocalArtworkImages.cachedBackdrop(for: artwork)
        default: self.albumBackdrop = nil
        }
    }
}

struct OpenLibraryRouteAction {
    let handler: (LibraryRoute) -> Void
    var sourceHandler: ((LibraryRoute, UIView?) -> Void)?
    var sourceProviderHandler: ((LibraryRoute, @escaping () -> UIView?) -> Void)?
    var previewSourceHandler: ((LibraryRoute, LibraryNavigationPreview, @escaping () -> UIView?) -> Void)?
    func callAsFunction(_ route: LibraryRoute, source: UIView? = nil) {
        if let sourceHandler { sourceHandler(route, source) } else { handler(route) }
    }
    func callAsFunction(_ route: LibraryRoute, sourceProvider: @escaping () -> UIView?) {
        if let sourceProviderHandler { sourceProviderHandler(route, sourceProvider) }
        else { callAsFunction(route, source: sourceProvider()) }
    }
    func callAsFunction(_ route: LibraryRoute, preview: LibraryNavigationPreview, sourceProvider: @escaping () -> UIView?) {
        if let previewSourceHandler { previewSourceHandler(route, preview, sourceProvider) }
        else { callAsFunction(route, sourceProvider: sourceProvider) }
    }
    @MainActor func callAsFunction(_ item: LibraryShelfItem, sourceProvider: @escaping () -> UIView?) {
        guard let route = item.route else { return }
        var artwork = item.artwork
        if case .file(let url) = artwork, let image = LocalArtworkImages.cached(url, pixels: 0) {
            artwork = .image(Image(uiImage: image))
        }
        let preview = LibraryNavigationPreview(route: route, ownerID: item.sourceOwnerID,
            title: item.title, subtitle: item.subtitle, artwork: artwork,
            albumBackdrop: item.albumBackdrop ?? LocalArtworkImages.cachedBackdrop(for: item.artwork))
        callAsFunction(route, preview: preview, sourceProvider: sourceProvider)
    }
}

extension EnvironmentValues {
    @Entry var openLibraryRoute = OpenLibraryRouteAction { _ in }
    @Entry var libraryNavigationPreview: LibraryNavigationPreview?
}

struct FavoriteMark: View {
    let isFavorite: Bool
    var color: Color = .secondary
    var leadingOffset: CGFloat = -15

    var body: some View {
        if isFavorite {
            Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 10, height: 12)
                .offset(x: leadingOffset)
                .accessibilityHidden(true)
        }
    }
}

struct TitleSection<Item>: Identifiable {
    let letter: String
    let items: [Item]
    var id: String { letter }

    static func sortKey(_ title: String) -> String {
        LibraryTitleSortKeys.key(for: title)
    }

    static func group(_ items: [Item], by title: (Item) -> String) -> [TitleSection] {
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

struct CloseLibraryDetailAction {
    var handler: (() -> Void)?
}

extension EnvironmentValues {
    @Entry var closeLibraryDetail = CloseLibraryDetailAction()
}
