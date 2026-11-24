import SwiftUI
import UIKit


struct LibraryMenuItem: Identifiable {
    var identity: String? = nil
    let title: String
    var subtitle: String?
    let systemImage: String
    var customImage: UIImage?
    var isDisabled = false
    var isDestructive = false
    var isSelected = false
    var children: [LibraryMenuItem] = []
    var perform: () -> Void = {}
    var id: String { identity ?? title }
}

typealias LibraryMenuSections = [[LibraryMenuItem]]

func libraryQueueMenuItems(playbackSource: String?, isDisabled: Bool = false,
                           playNext: @escaping () -> Void, playLater: @escaping () -> Void,
                           notify: @escaping (LibraryToast) -> Void = { _ in }) -> [LibraryMenuItem] {
    [LibraryMenuItem(title: "插播", systemImage: "text.line.first.and.arrowtriangle.forward", isDisabled: isDisabled) {
        guard !isDisabled else { return }
        playNext()
        notify(.playingNext)
     },
     LibraryMenuItem(title: playbackSource == nil ? "添加到队列" : "随后播放", subtitle: playbackSource,
                     systemImage: "text.line.last.and.arrowtriangle.forward", isDisabled: isDisabled) {
        guard !isDisabled else { return }
        playLater()
        notify(.addedToQueue)
     }]
}

extension Array where Element == [LibraryMenuItem] {
    @MainActor var nativeMenu: UIMenu { nativeMenu(firstSectionIsRow: true) }

    @MainActor func nativeMenu(firstSectionIsRow: Bool) -> UIMenu {
        func action(_ item: LibraryMenuItem) -> UIMenuElement {
            let image = item.customImage ?? UIImage(systemName: item.systemImage)
            if !item.children.isEmpty {
                let submenu = UIMenu(title: item.title, image: image, children: item.children.map(action))
                submenu.subtitle = item.subtitle
                return submenu
            }
            var attributes: UIMenuElement.Attributes = []
            if item.isDisabled { attributes.insert(.disabled) }
            if item.isDestructive { attributes.insert(.destructive) }
            let action = UIAction(title: item.title, image: image, attributes: attributes) { _ in item.perform() }
            action.subtitle = item.subtitle
            action.state = item.isSelected ? .on : .off
            return action
        }
        let groups = enumerated().filter { !$0.element.isEmpty }.map { index, items in
            let group = UIMenu(options: .displayInline, children: items.map(action))
            group.preferredElementSize = index == 0 && firstSectionIsRow && items.count > 1 ? .medium : .large
            return group
        }
        return UIMenu(children: groups)
    }
}

struct LibraryMenuContents: View {
    let sections: LibraryMenuSections
    var firstSectionIsRow = true

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, items in
            if index == 0 && firstSectionIsRow && items.count > 1 {
                ControlGroup { ForEach(items) { button($0) } }
            } else {
                Section { ForEach(items) { button($0) } }
            }
        }
    }

    @ViewBuilder private func button(_ item: LibraryMenuItem) -> some View {
        if !item.children.isEmpty {
            Menu(item.title, systemImage: item.systemImage) { ForEach(item.children) { leaf($0) } }
        } else {
            leaf(item)
        }
    }

    @ViewBuilder private func leaf(_ item: LibraryMenuItem) -> some View {
        if item.isSelected {
            Toggle(isOn: .constant(true)) { Label(item.title, systemImage: item.systemImage) }
                .disabled(true)
        } else {
            plainButton(item)
        }
    }

    private func plainButton(_ item: LibraryMenuItem) -> some View {
        Button(role: item.isDestructive ? .destructive : nil, action: item.perform) {
            Text(item.title)
            if let subtitle = item.subtitle { Text(subtitle) }
            if let image = item.customImage {
                Image(uiImage: image)
            } else {
                Image(systemName: item.systemImage)
            }
        }
        .disabled(item.isDisabled)
    }
}

private func favoriteItem(isFavorite: Bool, filled: Bool = true, perform: @escaping () -> Void) -> LibraryMenuItem {
    let image = isFavorite ? "star.slash" : "star"
    let undo = filled ? "撤销" : "撤销喜爱"
    return LibraryMenuItem(title: isFavorite ? undo : "喜爱", systemImage: filled ? image + ".fill" : image,
                           perform: perform)
}

private var unavailableDownload: LibraryMenuItem {
    LibraryMenuItem(title: "下载", systemImage: "arrow.down.circle.fill", isDisabled: true)
}


struct CollectionMenuActions {
    var play: (LibraryRoute, _ shuffled: Bool) -> Void = { _, _ in }
    var playNext: (LibraryRoute) -> Void = { _ in }
    var playLater: (LibraryRoute) -> Void = { _ in }
    var toggleFavorite: (LibraryRoute) -> Void = { _ in }
    var togglePin: (LibraryRoute) -> Void = { _ in }
    var addToPlaylist: (LibraryRoute) -> Void = { _ in }
    var playbackSource: () -> String? = { nil }
    var requestMove: (_ playlistID: String) -> Void = { _ in }
    var canDelete: (LibraryRoute) -> Bool = { _ in false }
    var isDownloaded: (LibraryRoute) -> Bool = { _ in false }
    var edit: (LibraryRoute) -> Void = { _ in }
    var requestDelete: (LibraryRoute) -> Void = { _ in }
    var delete: (LibraryRoute) -> Void = { _ in }
    var notify: (LibraryToast) -> Void = { _ in }
    var defersQueueNotice = false
    var removeDownload: (LibraryRoute) -> Void = { _ in }
    var download: (LibraryRoute) -> Void = { _ in }
    var canDownload: (LibraryRoute) -> Bool = { _ in false }
    var canRemoveDownload: (LibraryRoute) -> Bool = { _ in false }
    var stopDownload: (LibraryRoute) -> Void = { _ in }
    var downloads: LibraryDownloads? = nil

    @MainActor private func downloadItem(_ route: LibraryRoute) -> LibraryMenuItem {
        let summary = downloads?.collectionState(of: route)
        if summary?.isActive == true {
            return LibraryMenuItem(title: "停止下载", systemImage: "stop.circle.fill") {
                LibraryHaptics.impact()
                stopDownload(route)
            }
        }
        if summary?.isComplete == true {
            return LibraryMenuItem(title: "已下载", systemImage: "checkmark.circle.fill", isDisabled: true)
        }
        let failed = (summary?.failedCount ?? 0) > 0
        return LibraryMenuItem(title: failed ? "重试下载" : "下载", systemImage: failed ? "arrow.clockwise" : "arrow.down.circle.fill", isDisabled: !canDownload(route)) {
            LibraryHaptics.impact()
            download(route)
        }
    }

    private func toggleFavoriteAndNotify(_ item: LibraryShelfItem, _ route: LibraryRoute) {
        if !item.id.hasPrefix("catalog:") { LibraryHaptics.success() }
        toggleFavorite(route)
        if !item.id.hasPrefix("catalog:") { notify(item.isFavorite ? .unfavorited : .favorited) }
    }

    private func moveItem(playlistID: String) -> LibraryMenuItem {
        LibraryMenuItem(title: "移到文件夹", systemImage: "folder") { requestMove(playlistID) }
    }

    @MainActor func toolbarSections(for item: LibraryShelfItem, route: LibraryRoute) -> LibraryMenuSections {
        if case .album = route {
            var groups = sections(for: item, route: route)
            groups.remove(at: 1)
            return groups
        }
        var sections: LibraryMenuSections = [
            [favoriteItem(isFavorite: item.isFavorite, filled: false) { toggleFavoriteAndNotify(item, route) }],
            [pinItem(item, route: route),
             LibraryMenuItem(title: "添加到播放列表", systemImage: "text.badge.plus") { addToPlaylist(route) }],
        ]
        if case .playlist(let id) = route { sections.append([moveItem(playlistID: id)]) }
        sections.append(queueItems(route))
        return sections
    }

    private func pinItem(_ item: LibraryShelfItem, route: LibraryRoute) -> LibraryMenuItem {
        let isPlaylist = if case .playlist = route { true } else { false }
        let kind = isPlaylist ? "播放列表" : "专辑"
        return LibraryMenuItem(title: (item.isPinned ? "取消置顶" : "置顶") + kind,
                               systemImage: item.isPinned ? "pin.slash" : "pin") {
            LibraryHaptics.success()
            withAnimation(.smooth(duration: 0.35)) { togglePin(route) }
            notify(item.isPinned ? .unpinned : .pinned)
        }
    }

    private func queueItems(_ route: LibraryRoute) -> [LibraryMenuItem] {
        libraryQueueMenuItems(playbackSource: playbackSource(),
                              playNext: { playNext(route) }, playLater: { playLater(route) },
                              notify: defersQueueNotice ? { _ in } : notify)
    }

    private func playItems(_ route: LibraryRoute) -> [LibraryMenuItem] {
        [LibraryMenuItem(title: "播放", systemImage: "play") { play(route, false) },
         LibraryMenuItem(title: "随机播放", systemImage: "shuffle") { play(route, true) }]
    }

    func pinnedSections(for item: LibraryShelfItem, route: LibraryRoute, tapAction: PinnedTapAction,
                        setTapAction: @escaping (PinnedTapAction) -> Void) -> LibraryMenuSections {
        if case .libraryArtist = route {
            return [[LibraryMenuItem(title: "取消置顶", systemImage: "pin.slash") { togglePin(route) }]]
        }
        let options = PinnedTapAction.allCases.map { option in
            LibraryMenuItem(title: option.title(for: route), systemImage: "",
                            isSelected: option == tapAction) { setTapAction(option) }
        }
        return [
            playItems(route),
            queueItems(route),
            [LibraryMenuItem(title: "轻点操作", subtitle: tapAction.title(for: route), systemImage: "hand.tap",
                             children: options)],
            [pinItem(item, route: route)],
        ]
    }

    private func removalItems(_ route: LibraryRoute) -> [LibraryMenuItem] {
        var items: [LibraryMenuItem] = []
        if canRemoveDownload(route) {
            items.append(LibraryMenuItem(title: "移除下载", systemImage: "xmark.circle") { removeDownload(route) })
        }
        if canDelete(route) {
            items.append(LibraryMenuItem(title: "从资料库删除", systemImage: "trash", isDestructive: true) {
                requestDelete(route)
            })
        }
        return items
    }

    @MainActor func sections(for item: LibraryShelfItem, route: LibraryRoute) -> LibraryMenuSections {
        let isPlaylist = if case .playlist = route { true } else { false }
        var quick: [LibraryMenuItem]
        if isPlaylist {
            quick = [downloadItem(route), favoriteItem(isFavorite: item.isFavorite) { toggleFavoriteAndNotify(item, route) },
                     LibraryMenuItem(title: "共享", systemImage: "square.and.arrow.up.fill", isDisabled: true)]
        } else if isDownloaded(route) {
            quick = [favoriteItem(isFavorite: item.isFavorite, filled: false) { toggleFavoriteAndNotify(item, route) }]
        } else {
            quick = [downloadItem(route),
                     favoriteItem(isFavorite: item.isFavorite) { toggleFavoriteAndNotify(item, route) }]
        }
        var sections: LibraryMenuSections = [
            quick,
            playItems(route),
            [pinItem(item, route: route),
             LibraryMenuItem(title: "添加到播放列表", systemImage: "text.badge.plus") { addToPlaylist(route) }],
        ]
        if case .playlist(let id) = route {
            if id.hasPrefix("netease-playlist:") {
                sections.append([moveItem(playlistID: id)])
            } else { sections.append([
                LibraryMenuItem(title: "编辑", systemImage: "pencil", isDisabled: !canDelete(route)) { edit(route) },
                LibraryMenuItem(title: "开始协作", systemImage: "person.badge.plus", isDisabled: true),
                moveItem(playlistID: id),
            ]) }
        }
        sections.append(queueItems(route))
        sections.append(removalItems(route))
        return sections
    }
}

enum PinnedTapAction: CaseIterable {
    case open, play, shuffle

    func title(for route: LibraryRoute) -> String {
        switch self {
        case .open: if case .playlist = route { "前往播放列表" } else { "前往专辑" }
        case .play: "播放"
        case .shuffle: "随机播放"
        }
    }
}

extension EnvironmentValues {
    @Entry var collectionMenuActions = CollectionMenuActions()
}

struct CollectionCardLink<Label: View>: View {
    let item: LibraryShelfItem
    var menuSections: ((CollectionMenuActions) -> LibraryMenuSections)?
    var firstSectionIsRow = true
    var tap: (() -> Void)?
    var drag: NativeMenuDrag?
    var drop: NativeMenuDrop?
    @ViewBuilder var label: Label
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.libraryZoomNamespace) private var zoomNamespace
    @State private var isConfirmingDeletion = false

    var body: some View {
        if let route = item.route {
            label
                .padding(8)
                .contentShape(.rect)
                .nativeContextMenu(identity: item.id,
                                   menu: {
                                       var local = actions
                                       local.requestDelete = { _ in isConfirmingDeletion = true }
                                       return (menuSections?(local) ?? local.sections(for: item, route: route))
                                           .nativeMenu(firstSectionIsRow: firstSectionIsRow)
                                   },
                                   preview: { AnyView(MenuPreviewCard(artwork: item.artwork, lines: item.previewLines)) },
                                   previewSize: { MenuPreviewCard.size(for: item.previewLines, compatibleWith: $0) },
                                   commit: {
                                       #if DEBUG
                                       NavigationDiagnostics.event("Card.commit", page: route.diagnosticPage)
                                       #endif
                                       openLibraryRoute(item, sourceProvider: $0)
                                   }, tap: tap,
                                   drag: drag, drop: drop)
                .padding(-8)
                .alert("", isPresented: $isConfirmingDeletion) {
                    Button("从资料库删除", role: .destructive) {
                        LibraryHaptics.mediumImpact()
                        withAnimation(reducesMotion ? nil : .default) { actions.delete(route) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(route.deletionMessage)
                }
                .modifier(ZoomSource(route: route, namespace: zoomNamespace))
        } else {
            label
        }
    }
}

private struct ZoomSource: ViewModifier {
    let route: LibraryRoute
    let namespace: Namespace.ID?

    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.matchedTransitionSource(id: route, in: namespace) } else { content }
    }
}

extension View {
    func libraryZoomTransition(_ route: LibraryRoute, in namespace: Namespace.ID?) -> some View {
        modifier(ZoomDestination(route: route, namespace: namespace))
    }
}

private struct ZoomDestination: ViewModifier {
    let route: LibraryRoute
    let namespace: Namespace.ID?

    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.navigationTransition(.zoom(sourceID: route, in: namespace)) } else { content }
    }
}

extension EnvironmentValues {
    @Entry var libraryZoomNamespace: Namespace.ID?
}

extension LibraryRoute {
    var deletionMessage: String {
        switch self {
        case .album: "确定要从资料库删除这张专辑吗？这也会将歌曲从你喜爱的项目和制作的所有播放列表移除。"
        default: "确定要删除此播放列表吗？这会将播放列表从资料库删除。"
        }
    }
}

extension LibraryShelfItem {
    var previewLines: [String] {
        if case .playlist = route { return [title] }
        return [title] + (subtitle.map { [$0] } ?? [])
    }
}


struct SongMenuActions {
    var downloads: LibraryDownloads? = nil
    var play: (_ songs: [LibrarySongItem], _ startAt: Int, _ source: String) -> Void = { _, _, _ in }
    var playNext: (LibrarySongItem) -> Void = { _ in }
    var toggleFavorite: (LibrarySongItem) -> Void = { _ in }
    var removeFromFavorites: (LibrarySongItem) -> Void = { _ in }
    var togglePin: (LibrarySongItem) -> Void = { _ in }
    var addToPlaylist: (LibrarySongItem) -> Void = { _ in }
    var playLater: (LibrarySongItem) -> Void = { _ in }
    var delete: (LibrarySongItem) -> Void = { _ in }
    var playbackSource: () -> String? = { nil }
    var albumPreview: (LibrarySongItem, LibraryRoute) -> LibraryNavigationPreview? = { _, _ in nil }
    var openAlbum: (LibrarySongItem, @escaping (LibraryRoute) -> Void) -> Void = { song, open in open(.album(song.albumID)) }
    var openArtist: (LibrarySongItem, @escaping (LibraryRoute) -> Void) -> Void = { _, _ in }
    var notify: (LibraryToast) -> Void = { _ in }
    var defersQueueNotice = false
    var isAsynchronousFavorite: (LibrarySongItem) -> Bool = { $0.isNeteaseCatalogSong }

    @MainActor func albumTrackSections(for song: LibrarySongItem, isDownloaded: Bool,
                                       download: @escaping () -> Void, removeDownload: @escaping () -> Void,
                                       notify: @escaping (LibraryToast) -> Void,
                                       open: @escaping (LibraryRoute) -> Void = { _ in }) -> LibraryMenuSections {
        rowMenuSections(for: song, inAlbum: true, explicitNotify: notify, open: open)
    }

    @MainActor private func downloadItem(for song: LibrarySongItem) -> LibraryMenuItem? {
        guard let downloads else { return song.isNeteaseCatalogSong ? unavailableDownload : nil }
        let state = downloads.state(of: song.id)
        if state == .downloaded { return nil }
        if state?.isActive == true {
            return LibraryMenuItem(title: "停止下载", systemImage: "stop.circle.fill") {
                LibraryHaptics.impact()
                downloads.stop([song])
            }
        }
        if case .failed(let message) = state {
            guard downloads.isDownloadable(song) else { return nil }
            return LibraryMenuItem(title: "重试下载", subtitle: message, systemImage: "arrow.clockwise") {
                LibraryHaptics.impact()
                downloads.download([song])
            }
        }
        guard downloads.isDownloadable(song) else { return nil }
        return LibraryMenuItem(title: "下载", systemImage: "arrow.down.circle.fill") {
            LibraryHaptics.impact()
            downloads.download([song])
        }
    }

    @MainActor func sections(for song: LibrarySongItem, notify explicitNotify: ((LibraryToast) -> Void)? = nil,
                            removeFromPlaylist: (() -> Void)? = nil,
                            goToAlbum: @escaping () -> Void) -> LibraryMenuSections {
        let notify = explicitNotify ?? self.notify
        let asyncFavorite = isAsynchronousFavorite(song)
        var quick = [favoriteItem(isFavorite: song.isFavorite) {
            if song.isFavorite {
                CenteredActionSheet.confirmRemoveFromLiked {
                    removeFromFavorites(song)
                    if !asyncFavorite { notify(.unfavorited) }
                }
            } else {
                if !asyncFavorite { LibraryHaptics.success() }
                toggleFavorite(song)
                if !asyncFavorite { notify(.favorited) }
            }
        }]
        if let item = downloadItem(for: song) { quick.insert(item, at: 0) }
        var additions = [LibraryMenuItem(title: "添加到播放列表", systemImage: "text.badge.plus") { addToPlaylist(song) }]
        if let removeFromPlaylist {
            additions.append(LibraryMenuItem(title: "从歌单移除", systemImage: "minus.circle", isDestructive: true) {
                CenteredActionSheet.confirmRemoveFromPlaylist(removeFromPlaylist)
            })
        }
        var groups: LibraryMenuSections = [quick, additions,
            libraryQueueMenuItems(playbackSource: playbackSource(), playNext: { playNext(song) }, playLater: { playLater(song) }, notify: defersQueueNotice ? { _ in } : notify)]
        if let downloads, downloads.canRemove(song) {
            groups.append([LibraryMenuItem(title: "移除下载", systemImage: "xmark.circle") { downloads.requestRemoval([song]) }])
        }
        return groups
    }

    @MainActor func rowMenuSections(for song: LibrarySongItem, inAlbum: Bool = false,
                                    removeFromPlaylist: (() -> Void)? = nil,
                                    explicitNotify: ((LibraryToast) -> Void)? = nil,
                                    open: @escaping (LibraryRoute) -> Void) -> LibraryMenuSections {
        var groups = sections(for: song, notify: explicitNotify, removeFromPlaylist: removeFromPlaylist, goToAlbum: { openAlbum(song, open) })
        var links: [LibraryMenuItem] = []
        let isNetease = song.isNeteaseCatalogSong || downloads?.canRemove(song) == true
        if !inAlbum {
            if isNetease {
                if song.onlineAlbumID != nil || downloads?.canRemove(song) == true {
                    links.append(LibraryMenuItem(title: "前往专辑", subtitle: song.album.isEmpty ? nil : song.album,
                                                 systemImage: "music.note.square.stack") { openAlbum(song, open) })
                }
            } else {
                links.append(LibraryMenuItem(title: "前往专辑", subtitle: song.album.isEmpty ? nil : song.album,
                                             systemImage: "square", customImage: MenuIcons.album) { open(.album(song.albumID)) })
            }
        }
        if !song.artistReferences.isEmpty {
            links += song.artistReferences.map { artist in
                LibraryMenuItem(identity: "artist:" + artist.id, title: artist.name, systemImage: "music.microphone") { open(.artist(artist.id)) }
            }
        } else if isNetease {
            links.append(LibraryMenuItem(title: "前往艺人", subtitle: song.artist, systemImage: "music.microphone") {
                openArtist(song, open)
            })
        }
        if !links.isEmpty { groups.append(links) }
        return groups
    }

}

enum OnlineSongTrailingSwipe: Equatable {
    case like
    case download
    case stopDownload
    case removeFromLiked

    static func actions(isFavorite: Bool, downloadState: LibraryDownloads.SongState?, canDownload: Bool) -> [OnlineSongTrailingSwipe] {
        guard isFavorite else { return [.like] }
        if downloadState?.isActive == true { return [.stopDownload, .removeFromLiked] }
        if canDownload, downloadState != .downloaded { return [.download, .removeFromLiked] }
        return [.removeFromLiked]
    }
}

extension EnvironmentValues {
    @Entry var songMenuActions = SongMenuActions()
}

extension View {
    func songContextMenu(_ song: LibrarySongItem, onRemoveFromPlaylist: (() -> Void)? = nil) -> some View {
        modifier(SongContextMenu(song: song, onRemoveFromPlaylist: onRemoveFromPlaylist))
    }
}

struct OnlineSongTrailingSwipeButtons: View {
    let song: LibrarySongItem
    let items: [OnlineSongTrailingSwipe]
    var animateRemoval = false
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.libraryDownloads) private var downloads

    var body: some View {
        if let edge = items.first, edge != .removeFromLiked {
            switch edge {
            case .like:
                Button("喜欢", systemImage: "heart.fill") {
                    let asyncFavorite = songActions.isAsynchronousFavorite(song)
                    if !asyncFavorite { LibraryHaptics.success() }
                    songActions.toggleFavorite(song)
                    if !asyncFavorite { songActions.notify(.favorited) }
                }
                .labelStyle(.iconOnly)
                .tint(.pink)
            case .download:
                Button("下载", systemImage: "arrow.down") {
                    LibraryHaptics.impact()
                    downloads?.download([song])
                }
                .labelStyle(.iconOnly)
                .tint(.blue)
            case .stopDownload:
                Button("停止下载", systemImage: "stop.fill") {
                    LibraryHaptics.impact()
                    downloads?.stop([song])
                }
                .labelStyle(.iconOnly)
                .tint(.blue)
            case .removeFromLiked:
                EmptyView()
            }
        }
        if items.contains(.removeFromLiked) {
            Button("从喜欢歌曲移除", systemImage: "trash") {
                let asyncFavorite = songActions.isAsynchronousFavorite(song)
                CenteredActionSheet.confirmRemoveFromLiked {
                    if animateRemoval {
                        withAnimation { songActions.removeFromFavorites(song) }
                    } else {
                        songActions.removeFromFavorites(song)
                    }
                    if !asyncFavorite { songActions.notify(.unfavorited) }
                }
            }
            .labelStyle(.iconOnly)
            .tint(.red)
        }
    }
}

private struct SongContextMenu: ViewModifier {
    let song: LibrarySongItem
    var onRemoveFromPlaylist: (() -> Void)? = nil
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.dynamicTypeSize) private var textSize

    func body(content: Content) -> some View {
        let lines = [song.title, song.artist, song.album]
        content.contextMenu {
            SongNavigationMenu(song: song, onRemoveFromPlaylist: onRemoveFromPlaylist)
        } preview: {
            let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(textSize))
            let size = MenuPreviewCard.size(for: lines, compatibleWith: traits)
            MenuPreviewCard(artwork: song.artwork, lines: lines)
                .dynamicTypeSize(textSize)
                .frame(width: size.width, height: size.height)
        }
    }
}

struct SongMenuContents: View {
    let song: LibrarySongItem
    var onRemoveFromPlaylist: (() -> Void)? = nil
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    var body: some View {
        SongNavigationMenu(song: song, onRemoveFromPlaylist: onRemoveFromPlaylist)
    }
}

@MainActor enum MenuIcons {
    static let album: UIImage = {
        let size = CGSize(width: 22, height: 22)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            let frame = CGRect(origin: .zero, size: size).insetBy(dx: 2.5, dy: 2.5)
            let box = UIBezierPath(roundedRect: frame, cornerRadius: 4)
            box.lineWidth = 1.6
            UIColor.black.setStroke()
            box.stroke()
            let note = NSAttributedString(string: "♫", attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.black,
            ])
            let noteSize = note.size()
            note.draw(at: CGPoint(x: (size.width - noteSize.width) / 2, y: (size.height - noteSize.height) / 2))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
}


struct MenuPreviewCard: View {
    let artwork: Artwork
    let lines: [String]
    var artistAvatar: ArtistAvatarArtwork?
    var artistIdentity: LibraryArtistIdentity?

    private static let minWidth: CGFloat = 250
    private static let maxWidth: CGFloat = 340
    private static let chromeWidth: CGFloat = 16 + 92 + 16 + 8 + 10 + 12
    private static let textSlack: CGFloat = 6

    static func size(for lines: [String], compatibleWith traits: UITraitCollection? = nil) -> CGSize {
        let fonts = [UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)]
            + Array(repeating: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits),
                    count: max(lines.count - 1, 0))
        let textWidth = zip(lines, fonts).map { line, font in
            ceil((line as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        let textHeight = lines.isEmpty ? 0 : fonts.reduce(0) { $0 + $1.lineHeight }
            + CGFloat(max(lines.count - 1, 0)) * 2
        return CGSize(width: min(max(chromeWidth + textWidth + textSlack, minWidth), maxWidth),
                      height: max(123, ceil(textHeight + 32)))
    }

    var body: some View {
        HStack(spacing: 16) {
            Group {
                if let artistAvatar { ArtistAvatar(source: artistAvatar, identity: artistIdentity) }
                else { ArtworkView(artwork: artwork, cornerRadius: 16) }
            }
            .frame(width: 92, height: 92)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        if index == 0 {
                            Text(line).font(.headline).foregroundStyle(.primary)
                        } else {
                            Text(line).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .clipShape(.rect(cornerRadius: 32))
        .ignoresSafeArea()
    }
}

private struct SongNavigationMenu: View {
    let song: LibrarySongItem
    var onRemoveFromPlaylist: (() -> Void)? = nil
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var open
    var body: some View {
        LibraryMenuContents(sections: actions.rowMenuSections(for: song, removeFromPlaylist: onRemoveFromPlaylist) { open($0, preview: actions.albumPreview(song, $0)) })
    }
}
