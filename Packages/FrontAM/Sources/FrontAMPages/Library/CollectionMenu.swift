import FrontAMCore
import FrontAMNavigation
import SwiftUI
import UIKit


public struct LibraryMenuItem: Identifiable {
    public var identity: String? = nil
    public let title: String
    public var subtitle: String?
    public let systemImage: String
    public var customImage: UIImage?
    public var isDisabled = false
    public var isDestructive = false
    public var isSelected = false
    public var children: [LibraryMenuItem] = []
    public var perform: () -> Void = {}
    public var id: String { identity ?? title }

    public init(identity: String? = nil, title: String, subtitle: String? = nil, systemImage: String,
                customImage: UIImage? = nil, isDisabled: Bool = false, isDestructive: Bool = false,
                isSelected: Bool = false, children: [LibraryMenuItem] = [], perform: @escaping () -> Void = {}) {
        self.identity = identity
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.customImage = customImage
        self.isDisabled = isDisabled
        self.isDestructive = isDestructive
        self.isSelected = isSelected
        self.children = children
        self.perform = perform
    }
}

public typealias LibraryMenuSections = [[LibraryMenuItem]]

public func libraryQueueMenuItems(playbackSource: String?, isDisabled: Bool = false,
                           playNext: @escaping () -> Void, playLater: @escaping () -> Void,
                           notify: @escaping (LibraryToast) -> Void = { _ in }) -> [LibraryMenuItem] {
    [LibraryMenuItem(title: pageText("插播"), systemImage: "text.line.first.and.arrowtriangle.forward", isDisabled: isDisabled) {
        guard !isDisabled else { return }
        playNext()
        notify(.playingNext)
     },
     LibraryMenuItem(title: playbackSource == nil ? pageText("添加到队列") : pageText("随后播放"), subtitle: playbackSource,
                     systemImage: "text.line.last.and.arrowtriangle.forward", isDisabled: isDisabled) {
        guard !isDisabled else { return }
        playLater()
        notify(.addedToQueue)
     }]
}

extension Array where Element == [LibraryMenuItem] {
    @MainActor public var nativeMenu: UIMenu { nativeMenu(firstSectionIsRow: true) }

    @MainActor public func nativeMenu(firstSectionIsRow: Bool) -> UIMenu {
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

public struct LibraryMenuContents: View {
    public let sections: LibraryMenuSections
    public var firstSectionIsRow = true

    public var body: some View {
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

    public init(sections: LibraryMenuSections,
                firstSectionIsRow: Bool = true) {
        self.sections = sections
        self.firstSectionIsRow = firstSectionIsRow
    }
}

private func favoriteItem(isFavorite: Bool, filled: Bool = true, perform: @escaping () -> Void) -> LibraryMenuItem {
    let image = isFavorite ? "star.slash" : "star"
    let undo = filled ? pageText("撤销") : pageText("撤销喜爱")
    return LibraryMenuItem(title: isFavorite ? undo : pageText("喜爱"), systemImage: filled ? image + ".fill" : image,
                           perform: perform)
}

private var unavailableDownload: LibraryMenuItem {
    LibraryMenuItem(title: pageText("下载"), systemImage: "arrow.down.circle.fill", isDisabled: true)
}


public struct CollectionMenuActions {
    public var play: (LibraryRoute, _ shuffled: Bool) -> Void = { _, _ in }
    public var playNext: (LibraryRoute) -> Void = { _ in }
    public var playLater: (LibraryRoute) -> Void = { _ in }
    public var toggleFavorite: (LibraryRoute) -> Void = { _ in }
    public var usesManagedCollectionActions: (String) -> Bool = { _ in false }
    public var togglePin: (LibraryRoute) -> Void = { _ in }
    public var addToPlaylist: (LibraryRoute) -> Void = { _ in }
    public var playbackSource: () -> String? = { nil }
    public var requestMove: (_ playlistID: String) -> Void = { _ in }
    public var showsPlaylistEditingActions: (_ playlistID: String) -> Bool = { _ in true }
    public var canDelete: (LibraryRoute) -> Bool = { _ in false }
    public var isDownloaded: (LibraryRoute) -> Bool = { _ in false }
    public var edit: (LibraryRoute) -> Void = { _ in }
    public var requestDelete: (LibraryRoute) -> Void = { _ in }
    public var delete: (LibraryRoute) -> Void = { _ in }
    public var notify: (LibraryToast) -> Void = { _ in }
    public var defersQueueNotice = false
    public var removeDownload: (LibraryRoute) -> Void = { _ in }
    public var download: (LibraryRoute) -> Void = { _ in }
    public var canDownload: (LibraryRoute) -> Bool = { _ in false }
    public var canRemoveDownload: (LibraryRoute) -> Bool = { _ in false }
    public var stopDownload: (LibraryRoute) -> Void = { _ in }
    public var downloads: (any FrontAMDownloadSource)? = nil

    @MainActor private func downloadItem(_ route: LibraryRoute) -> LibraryMenuItem {
        let summary = downloads?.collectionState(of: route)
        if summary?.isActive == true {
            return LibraryMenuItem(title: pageText("停止下载"), systemImage: "stop.circle.fill") {
                stopDownload(route)
            }
        }
        if summary?.isComplete == true {
            return LibraryMenuItem(title: pageText("已下载"), systemImage: "checkmark.circle.fill", isDisabled: true)
        }
        let failed = (summary?.failedCount ?? 0) > 0
        return LibraryMenuItem(title: failed ? pageText("重试下载") : pageText("下载"), systemImage: failed ? "arrow.clockwise" : "arrow.down.circle.fill", isDisabled: !canDownload(route)) {
            download(route)
        }
    }

    private func toggleFavoriteAndNotify(_ item: LibraryShelfItem, _ route: LibraryRoute) {
        let hasImmediateFeedback = switch route {
        case .album(let id), .artist(let id): !usesManagedCollectionActions(id)
        case .libraryArtist: false
        default: !usesManagedCollectionActions(item.id)
        }
        if hasImmediateFeedback { LibraryHaptics.success() }
        toggleFavorite(route)
        if hasImmediateFeedback { notify(item.isFavorite ? .unfavorited : .favorited) }
    }

    private func moveItem(playlistID: String) -> LibraryMenuItem {
        LibraryMenuItem(title: pageText("移到文件夹"), systemImage: "folder") { requestMove(playlistID) }
    }

    @MainActor public func toolbarSections(for item: LibraryShelfItem, route: LibraryRoute) -> LibraryMenuSections {
        if case .album = route {
            var groups = sections(for: item, route: route)
            groups.remove(at: 1)
            return groups
        }
        var sections: LibraryMenuSections = [
            [favoriteItem(isFavorite: item.isFavorite, filled: false) { toggleFavoriteAndNotify(item, route) }],
            [pinItem(item, route: route),
             LibraryMenuItem(title: pageText("添加到播放列表"), systemImage: "text.badge.plus") { addToPlaylist(route) }],
        ]
        if case .playlist(let id) = route { sections.append([moveItem(playlistID: id)]) }
        sections.append(queueItems(route))
        return sections
    }

    private func pinItem(_ item: LibraryShelfItem, route: LibraryRoute) -> LibraryMenuItem {
        let isPlaylist = if case .playlist = route { true } else { false }
        let kind = isPlaylist ? pageText("播放列表") : pageText("专辑")
        return LibraryMenuItem(title: (item.isPinned ? pageText("取消置顶") : pageText("置顶")) + kind,
                               systemImage: item.isPinned ? "pin.slash" : "pin") {
            LibraryHaptics.success()
            withAnimation(.smooth(duration: 0.35)) { togglePin(route) }
            notify(item.isPinned ? .unpinned : .pinned)
        }
    }

    func queueItems(_ route: LibraryRoute, isDisabled: Bool = false) -> [LibraryMenuItem] {
        libraryQueueMenuItems(playbackSource: playbackSource(), isDisabled: isDisabled,
                              playNext: { playNext(route) }, playLater: { playLater(route) },
                              notify: defersQueueNotice ? { _ in } : notify)
    }

    private func playItems(_ route: LibraryRoute) -> [LibraryMenuItem] {
        [LibraryMenuItem(title: pageText("播放"), systemImage: "play") { play(route, false) },
         LibraryMenuItem(title: pageText("随机播放"), systemImage: "shuffle") { play(route, true) }]
    }

    public func pinnedSections(for item: LibraryShelfItem, route: LibraryRoute, tapAction: PinnedTapAction,
                        setTapAction: @escaping (PinnedTapAction) -> Void) -> LibraryMenuSections {
        if case .libraryArtist = route {
            return [[LibraryMenuItem(title: pageText("取消置顶"), systemImage: "pin.slash") {
                LibraryHaptics.success()
                togglePin(route)
            }]]
        }
        let options = PinnedTapAction.allCases.map { option in
            LibraryMenuItem(title: option.title(for: route), systemImage: "",
                            isSelected: option == tapAction) { setTapAction(option) }
        }
        return [
            playItems(route),
            queueItems(route),
            [LibraryMenuItem(title: pageText("轻点操作"), subtitle: tapAction.title(for: route), systemImage: "hand.tap",
                             children: options)],
            [pinItem(item, route: route)],
        ]
    }

    private func removalItems(_ route: LibraryRoute) -> [LibraryMenuItem] {
        var items: [LibraryMenuItem] = []
        if canRemoveDownload(route) {
            items.append(LibraryMenuItem(title: pageText("移除下载"), systemImage: "xmark.circle") { removeDownload(route) })
        }
        if canDelete(route) {
            items.append(LibraryMenuItem(title: pageText("从资料库删除"), systemImage: "trash", isDestructive: true) {
                requestDelete(route)
            })
        }
        return items
    }

    @MainActor public func sections(for item: LibraryShelfItem, route: LibraryRoute) -> LibraryMenuSections {
        let isPlaylist = if case .playlist = route { true } else { false }
        var quick: [LibraryMenuItem]
        if isPlaylist {
            quick = [downloadItem(route), favoriteItem(isFavorite: item.isFavorite) { toggleFavoriteAndNotify(item, route) },
                     LibraryMenuItem(title: pageText("共享"), systemImage: "square.and.arrow.up.fill", isDisabled: true)]
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
             LibraryMenuItem(title: pageText("添加到播放列表"), systemImage: "text.badge.plus") { addToPlaylist(route) }],
        ]
        if case .playlist(let id) = route {
            if showsPlaylistEditingActions(id) {
                sections.append([
                    LibraryMenuItem(title: pageText("编辑"), systemImage: "pencil", isDisabled: !canDelete(route)) { edit(route) },
                    LibraryMenuItem(title: pageText("开始协作"), systemImage: "person.badge.plus", isDisabled: true),
                    moveItem(playlistID: id),
                ])
            } else {
                sections.append([moveItem(playlistID: id)])
            }
        }
        sections.append(queueItems(route))
        sections.append(removalItems(route))
        return sections
    }

    public init(play: @escaping (LibraryRoute, _ shuffled: Bool) -> Void = { _, _ in },
                playNext: @escaping (LibraryRoute) -> Void = { _ in },
                playLater: @escaping (LibraryRoute) -> Void = { _ in },
                toggleFavorite: @escaping (LibraryRoute) -> Void = { _ in },
                usesManagedCollectionActions: @escaping (String) -> Bool = { _ in false },
                togglePin: @escaping (LibraryRoute) -> Void = { _ in },
                addToPlaylist: @escaping (LibraryRoute) -> Void = { _ in },
                playbackSource: @escaping () -> String? = { nil },
                requestMove: @escaping (_ playlistID: String) -> Void = { _ in },
                showsPlaylistEditingActions: @escaping (_ playlistID: String) -> Bool = { _ in true },
                canDelete: @escaping (LibraryRoute) -> Bool = { _ in false },
                isDownloaded: @escaping (LibraryRoute) -> Bool = { _ in false },
                edit: @escaping (LibraryRoute) -> Void = { _ in },
                requestDelete: @escaping (LibraryRoute) -> Void = { _ in },
                delete: @escaping (LibraryRoute) -> Void = { _ in },
                notify: @escaping (LibraryToast) -> Void = { _ in },
                defersQueueNotice: Bool = false,
                removeDownload: @escaping (LibraryRoute) -> Void = { _ in },
                download: @escaping (LibraryRoute) -> Void = { _ in },
                canDownload: @escaping (LibraryRoute) -> Bool = { _ in false },
                canRemoveDownload: @escaping (LibraryRoute) -> Bool = { _ in false },
                stopDownload: @escaping (LibraryRoute) -> Void = { _ in },
                downloads: (any FrontAMDownloadSource)? = nil) {
        self.play = play
        self.playNext = playNext
        self.playLater = playLater
        self.toggleFavorite = toggleFavorite
        self.usesManagedCollectionActions = usesManagedCollectionActions
        self.togglePin = togglePin
        self.addToPlaylist = addToPlaylist
        self.playbackSource = playbackSource
        self.requestMove = requestMove
        self.showsPlaylistEditingActions = showsPlaylistEditingActions
        self.canDelete = canDelete
        self.isDownloaded = isDownloaded
        self.edit = edit
        self.requestDelete = requestDelete
        self.delete = delete
        self.notify = notify
        self.defersQueueNotice = defersQueueNotice
        self.removeDownload = removeDownload
        self.download = download
        self.canDownload = canDownload
        self.canRemoveDownload = canRemoveDownload
        self.stopDownload = stopDownload
        self.downloads = downloads
    }
}

public enum PinnedTapAction: CaseIterable {
    case open, play, shuffle

    public func title(for route: LibraryRoute) -> String {
        switch self {
        case .open: if case .playlist = route { pageText("前往播放列表") } else { pageText("前往专辑") }
        case .play: pageText("播放")
        case .shuffle: pageText("随机播放")
        }
    }
}

extension EnvironmentValues {
    @Entry public var collectionMenuActions = CollectionMenuActions()
}

public struct CollectionCardLink<Label: View>: View {
    public let item: LibraryShelfItem
    public var menuSections: ((CollectionMenuActions) -> LibraryMenuSections)?
    public var firstSectionIsRow = true
    public var tap: (() -> Void)?
    public var drag: NativeMenuDrag?
    public var drop: NativeMenuDrop?
    @ViewBuilder public var label: Label
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.frontAMViewEvent) private var viewEvent
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.libraryZoomNamespace) private var zoomNamespace
    @State private var isConfirmingDeletion = false

    public var body: some View {
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
                                       viewEvent("Card.commit", String(describing: route))
                                       #endif
                                       openLibraryRoute(item, sourceProvider: $0)
                                   }, tap: tap,
                                   drag: drag, drop: drop)
                .padding(-8)
                .alert("", isPresented: $isConfirmingDeletion) {
                    Button(pageText("从资料库删除"), role: .destructive) {
                        withAnimation(reducesMotion ? nil : .default) { actions.delete(route) }
                    }
                    Button(pageText("取消"), role: .cancel) {}
                } message: {
                    Text(route.deletionMessage)
                }
                .libraryZoomSource(route, in: zoomNamespace)
        } else {
            label
        }
    }

    public init(item: LibraryShelfItem,
                menuSections: ((CollectionMenuActions) -> LibraryMenuSections)? = nil,
                firstSectionIsRow: Bool = true,
                tap: (() -> Void)? = nil,
                drag: NativeMenuDrag? = nil,
                drop: NativeMenuDrop? = nil,
                @ViewBuilder label: () -> Label) {
        self.item = item
        self.menuSections = menuSections
        self.firstSectionIsRow = firstSectionIsRow
        self.tap = tap
        self.drag = drag
        self.drop = drop
        self.label = label()
    }
}

extension LibraryRoute {
    public var deletionMessage: String {
        switch self {
        case .album: pageText("确定要从资料库删除这张专辑吗？这也会将歌曲从你喜爱的项目和制作的所有播放列表移除。")
        default: pageText("确定要删除此播放列表吗？这会将播放列表从资料库删除。")
        }
    }
}

extension LibraryShelfItem {
    public var previewLines: [String] {
        if case .playlist = route { return [title] }
        return [title] + (subtitle.map { [$0] } ?? [])
    }
}


public struct SongMenuActions {
    public var downloads: (any FrontAMDownloadSource)? = nil
    public var play: (_ songs: [LibrarySongItem], _ startAt: Int, _ source: String) -> Void = { _, _, _ in }
    public var playAfterPreparation: (([LibrarySongItem], Int, String) -> Void)?
    public var playNext: (LibrarySongItem) -> Void = { _ in }
    public var toggleFavorite: (LibrarySongItem) -> Void = { _ in }
    public var removeFromFavorites: (LibrarySongItem) -> Void = { _ in }
    public var togglePin: (LibrarySongItem) -> Void = { _ in }
    public var addToPlaylist: (LibrarySongItem) -> Void = { _ in }
    public var playLater: (LibrarySongItem) -> Void = { _ in }
    public var delete: (LibrarySongItem) -> Void = { _ in }
    public var playbackSource: () -> String? = { nil }
    public var albumPreview: (LibrarySongItem, LibraryRoute) -> LibraryNavigationPreview? = { _, _ in nil }
    public var openAlbum: (LibrarySongItem, @escaping (LibraryRoute) -> Void) -> Void = { song, open in open(.album(song.albumID)) }
    public var openArtist: (LibrarySongItem, @escaping (LibraryRoute) -> Void) -> Void = { _, _ in }
    public var notify: (LibraryToast) -> Void = { _ in }
    public var defersQueueNotice = false
    public var isAsynchronousFavorite: (LibrarySongItem) -> Bool = { $0.hasCatalogActions }

    @MainActor public func albumTrackSections(for song: LibrarySongItem, isDownloaded: Bool,
                                       download: @escaping () -> Void, removeDownload: @escaping () -> Void,
                                       notify: @escaping (LibraryToast) -> Void,
                                       open: @escaping (LibraryRoute) -> Void = { _ in }) -> LibraryMenuSections {
        rowMenuSections(for: song, inAlbum: true, explicitNotify: notify, open: open)
    }

    @MainActor private func downloadItem(for song: LibrarySongItem) -> LibraryMenuItem? {
        guard let downloads else { return song.hasCatalogActions ? unavailableDownload : nil }
        let state = downloads.state(of: song.id)
        if state == .downloaded { return nil }
        if state?.isActive == true {
            return LibraryMenuItem(title: pageText("停止下载"), systemImage: "stop.circle.fill") {
                downloads.stop([song])
            }
        }
        if case .failed(let message) = state {
            guard downloads.isDownloadable(song) else { return nil }
            return LibraryMenuItem(title: pageText("重试下载"), subtitle: message, systemImage: "arrow.clockwise") {
                downloads.download([song])
            }
        }
        guard downloads.isDownloadable(song) else { return nil }
        return LibraryMenuItem(title: pageText("下载"), systemImage: "arrow.down.circle.fill") {
            downloads.download([song])
        }
    }

    @MainActor public func sections(for song: LibrarySongItem, notify explicitNotify: ((LibraryToast) -> Void)? = nil,
                            removeFromPlaylist: (() -> Void)? = nil,
                            goToAlbum: @escaping () -> Void) -> LibraryMenuSections {
        let notify = explicitNotify ?? self.notify
        let asyncFavorite = isAsynchronousFavorite(song)
        var quick = [favoriteItem(isFavorite: song.isFavorite) {
            if song.isFavorite {
                CenteredActionSheet.confirmRemoveFromLiked {
                    if !asyncFavorite { LibraryHaptics.success() }
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
        var additions = [LibraryMenuItem(title: pageText("添加到播放列表"), systemImage: "text.badge.plus") { addToPlaylist(song) }]
        if let removeFromPlaylist {
            additions.append(LibraryMenuItem(title: pageText("从歌单移除"), systemImage: "minus.circle", isDestructive: true) {
                CenteredActionSheet.confirmRemoveFromPlaylist(removeFromPlaylist)
            })
        }
        var groups: LibraryMenuSections = [quick, additions,
            libraryQueueMenuItems(playbackSource: playbackSource(), playNext: { playNext(song) }, playLater: { playLater(song) }, notify: defersQueueNotice ? { _ in } : notify)]
        if let downloads, downloads.canRemove(song) {
            groups.append([LibraryMenuItem(title: pageText("移除下载"), systemImage: "xmark.circle") { downloads.requestRemoval([song]) }])
        }
        return groups
    }

    @MainActor public func rowMenuSections(for song: LibrarySongItem, inAlbum: Bool = false,
                                    removeFromPlaylist: (() -> Void)? = nil,
                                    explicitNotify: ((LibraryToast) -> Void)? = nil,
                                    open: @escaping (LibraryRoute) -> Void) -> LibraryMenuSections {
        var groups = sections(for: song, notify: explicitNotify, removeFromPlaylist: removeFromPlaylist, goToAlbum: { openAlbum(song, open) })
        var links: [LibraryMenuItem] = []
        let usesCatalog = song.hasCatalogActions || downloads?.canRemove(song) == true
        if !inAlbum {
            if usesCatalog {
                if song.onlineAlbumID != nil || downloads?.canRemove(song) == true {
                    links.append(LibraryMenuItem(title: pageText("前往专辑"), subtitle: song.album.isEmpty ? nil : song.album,
                                                 systemImage: "music.note.square.stack") { openAlbum(song, open) })
                }
            } else {
                links.append(LibraryMenuItem(title: pageText("前往专辑"), subtitle: song.album.isEmpty ? nil : song.album,
                                             systemImage: "square", customImage: MenuIcons.album) { open(.album(song.albumID)) })
            }
        }
        if !song.artistReferences.isEmpty {
            links += song.artistReferences.map { artist in
                LibraryMenuItem(identity: "artist:" + artist.id, title: artist.name, systemImage: "music.microphone") { open(.artist(artist.id)) }
            }
        } else if usesCatalog {
            links.append(LibraryMenuItem(title: pageText("前往艺人"), subtitle: song.artist, systemImage: "music.microphone") {
                openArtist(song, open)
            })
        }
        if !links.isEmpty { groups.append(links) }
        return groups
    }

    public init(downloads: (any FrontAMDownloadSource)? = nil,
                play: @escaping (_ songs: [LibrarySongItem], _ startAt: Int, _ source: String) -> Void = { _, _, _ in },
                playNext: @escaping (LibrarySongItem) -> Void = { _ in },
                toggleFavorite: @escaping (LibrarySongItem) -> Void = { _ in },
                removeFromFavorites: @escaping (LibrarySongItem) -> Void = { _ in },
                togglePin: @escaping (LibrarySongItem) -> Void = { _ in },
                addToPlaylist: @escaping (LibrarySongItem) -> Void = { _ in },
                playLater: @escaping (LibrarySongItem) -> Void = { _ in },
                delete: @escaping (LibrarySongItem) -> Void = { _ in },
                playbackSource: @escaping () -> String? = { nil },
                albumPreview: @escaping (LibrarySongItem, LibraryRoute) -> LibraryNavigationPreview? = { _, _ in nil },
                openAlbum: @escaping (LibrarySongItem, @escaping (LibraryRoute) -> Void) -> Void = { song, open in open(.album(song.albumID)) },
                openArtist: @escaping (LibrarySongItem, @escaping (LibraryRoute) -> Void) -> Void = { _, _ in },
                notify: @escaping (LibraryToast) -> Void = { _ in },
                defersQueueNotice: Bool = false,
                isAsynchronousFavorite: @escaping (LibrarySongItem) -> Bool = { $0.hasCatalogActions }) {
        self.downloads = downloads
        self.play = play
        self.playNext = playNext
        self.toggleFavorite = toggleFavorite
        self.removeFromFavorites = removeFromFavorites
        self.togglePin = togglePin
        self.addToPlaylist = addToPlaylist
        self.playLater = playLater
        self.delete = delete
        self.playbackSource = playbackSource
        self.albumPreview = albumPreview
        self.openAlbum = openAlbum
        self.openArtist = openArtist
        self.notify = notify
        self.defersQueueNotice = defersQueueNotice
        self.isAsynchronousFavorite = isAsynchronousFavorite
    }

}

public enum OnlineSongTrailingSwipe: Equatable {
    case like
    case download
    case stopDownload
    case removeFromLiked

    public static func actions(isFavorite: Bool, downloadState: FrontAMDownloadState?, canDownload: Bool) -> [OnlineSongTrailingSwipe] {
        guard isFavorite else { return [.like] }
        if downloadState?.isActive == true { return [.stopDownload, .removeFromLiked] }
        if canDownload, downloadState != .downloaded { return [.download, .removeFromLiked] }
        return [.removeFromLiked]
    }
}

extension EnvironmentValues {
    @Entry public var songMenuActions = SongMenuActions()
}

extension View {
    public func songContextMenu(_ song: LibrarySongItem, onRemoveFromPlaylist: (() -> Void)? = nil) -> some View {
        modifier(SongContextMenu(song: song, onRemoveFromPlaylist: onRemoveFromPlaylist))
    }
}

public struct OnlineSongTrailingSwipeButtons: View {
    public let song: LibrarySongItem
    public let items: [OnlineSongTrailingSwipe]
    public var animateRemoval = false
    @Environment(\.songMenuActions) private var songActions
    @Environment(\.libraryDownloads) private var downloads

    public var body: some View {
        if let edge = items.first, edge != .removeFromLiked {
            switch edge {
            case .like:
                Button(pageText("喜欢"), systemImage: "heart.fill") {
                    let asyncFavorite = songActions.isAsynchronousFavorite(song)
                    if !asyncFavorite { LibraryHaptics.success() }
                    songActions.toggleFavorite(song)
                    if !asyncFavorite { songActions.notify(.favorited) }
                }
                .labelStyle(.iconOnly)
                .tint(.pink)
            case .download:
                Button(pageText("下载"), systemImage: "arrow.down") {
                    downloads?.download([song])
                }
                .labelStyle(.iconOnly)
                .tint(.blue)
            case .stopDownload:
                Button(pageText("停止下载"), systemImage: "stop.fill") {
                    downloads?.stop([song])
                }
                .labelStyle(.iconOnly)
                .tint(.blue)
            case .removeFromLiked:
                EmptyView()
            }
        }
        if items.contains(.removeFromLiked) {
            Button(pageText("从喜欢歌曲移除"), systemImage: "trash") {
                let asyncFavorite = songActions.isAsynchronousFavorite(song)
                CenteredActionSheet.confirmRemoveFromLiked {
                    if !asyncFavorite { LibraryHaptics.success() }
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
    @Environment(\.frontAMViewEvent) private var viewEvent
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

public struct SongMenuContents: View {
    public let song: LibrarySongItem
    public var onRemoveFromPlaylist: (() -> Void)? = nil
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.frontAMViewEvent) private var viewEvent

    public var body: some View {
        SongNavigationMenu(song: song, onRemoveFromPlaylist: onRemoveFromPlaylist)
    }
}

@MainActor public enum MenuIcons {
    public static let album: UIImage = {
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


public struct MenuPreviewCard: View {
    public let artwork: Artwork
    public let lines: [String]
    public var artistAvatar: ArtistAvatarArtwork?
    public var artistIdentity: LibraryArtistIdentity?

    private static let minWidth: CGFloat = 250
    private static let maxWidth: CGFloat = 340
    private static let chromeWidth: CGFloat = 16 + 92 + 16 + 8 + 10 + 12
    private static let textSlack: CGFloat = 6

    public static func size(for lines: [String], compatibleWith traits: UITraitCollection? = nil) -> CGSize {
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

    public var body: some View {
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

    public init(artwork: Artwork,
                lines: [String],
                artistAvatar: ArtistAvatarArtwork? = nil,
                artistIdentity: LibraryArtistIdentity? = nil) {
        self.artwork = artwork
        self.lines = lines
        self.artistAvatar = artistAvatar
        self.artistIdentity = artistIdentity
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
