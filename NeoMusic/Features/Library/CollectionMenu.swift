import SwiftUI
import UIKit

// MARK: - 菜单项

/// 长按菜单与“…”菜单共用的一项。同一份分组既生成系统长按菜单，也生成 SwiftUI 菜单内容，
/// 所有入口显示一致。第一组是横向并排的快捷操作。
struct LibraryMenuItem: Identifiable {
    let title: String
    var subtitle: String?
    let systemImage: String
    /// 没有合适系统符号时自绘的模板图标，优先于 `systemImage`。
    var customImage: UIImage?
    var isDisabled = false
    var isDestructive = false
    /// 当前所在位置等已选中状态，显示勾号。
    var isSelected = false
    /// 非空时为子菜单，点按展开这些项。
    var children: [LibraryMenuItem] = []
    var perform: () -> Void = {}
    var id: String { title }
}

typealias LibraryMenuSections = [[LibraryMenuItem]]

/// 所有资料库入口共用队列顺序、图标与名称；是否显示提示由入口保持原有策略。
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
    /// 系统长按菜单：首组为中号横排，其余为大号分组。
    @MainActor var nativeMenu: UIMenu { nativeMenu(firstSectionIsRow: true) }

    /// `firstSectionIsRow` 为 false 时首组也按普通分组显示（例如文件夹菜单）。
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
            // 首组只剩一项时（例如已下载专辑只剩“喜爱”）按普通行显示。
            group.preferredElementSize = index == 0 && firstSectionIsRow && items.count > 1 ? .medium : .large
            return group
        }
        return UIMenu(children: groups)
    }
}

/// SwiftUI 菜单内容：首组默认用 `ControlGroup` 横排，其余分节。
struct LibraryMenuContents: View {
    let sections: LibraryMenuSections
    /// 详情页“…”菜单没有横排快捷操作，首组也按普通分节显示。
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

    /// 子菜单只有一层，子项不再展开。
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
        // 菜单按钮里依次放标题、副标题与图标，系统会把第二个文本显示为副标题。
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

/// 喜爱的条目在菜单里显示“撤销”，与 Apple Music 一致。长按菜单的横排用实心图标，“…”菜单用空心。
private func favoriteItem(isFavorite: Bool, filled: Bool = true, perform: @escaping () -> Void) -> LibraryMenuItem {
    let image = isFavorite ? "star.slash" : "star"
    // 横排快捷操作空间小，只写“撤销”；普通行写全“撤销喜爱”。
    let undo = filled ? "撤销" : "撤销喜爱"
    return LibraryMenuItem(title: isFavorite ? undo : "喜爱", systemImage: filled ? image + ".fill" : image,
                           perform: perform)
}

/// 本地音乐不需要下载，保留位置但不可用。
private var unavailableDownload: LibraryMenuItem {
    LibraryMenuItem(title: "下载", systemImage: "arrow.down.circle.fill", isDisabled: true)
}

// MARK: - 专辑与播放列表

/// 专辑、播放列表长按菜单里会用到的操作，由持有资料库与播放状态的宿主提供。
struct CollectionMenuActions {
    var play: (LibraryRoute, _ shuffled: Bool) -> Void = { _, _ in }
    var playNext: (LibraryRoute) -> Void = { _ in }
    var playLater: (LibraryRoute) -> Void = { _ in }
    var toggleFavorite: (LibraryRoute) -> Void = { _ in }
    var togglePin: (LibraryRoute) -> Void = { _ in }
    var addToPlaylist: (LibraryRoute) -> Void = { _ in }
    /// “随后播放”下方显示的当前播放来源，例如“喜爱歌曲”；没有来源时菜单改为“添加到队列”。
    var playbackSource: () -> String? = { nil }
    /// 请求把播放列表移到文件夹，由宿主弹出选择页。
    var requestMove: (_ playlistID: String) -> Void = { _ in }
    /// 能否从资料库删除（系统播放列表与专辑不能），以及请求删除（由宿主先确认）。
    var canDelete: (LibraryRoute) -> Bool = { _ in false }
    /// 是否已下载到本地；只有已下载的条目显示“移除下载”。
    var isDownloaded: (LibraryRoute) -> Bool = { _ in false }
    /// 编辑播放列表（系统播放列表不能编辑，与删除使用同一判断）。
    var edit: (LibraryRoute) -> Void = { _ in }
    var requestDelete: (LibraryRoute) -> Void = { _ in }
    /// 确认后直接从资料库删除（卡片自己弹出确认时使用）。
    var delete: (LibraryRoute) -> Void = { _ in }
    /// 显示操作完成的提示，例如“已喜爱”“已置顶”。
    var notify: (LibraryToast) -> Void = { _ in }
    /// 请求移除完整集合的下载；宿主先显示共享文件确认。
    var removeDownload: (LibraryRoute) -> Void = { _ in }
    var download: (LibraryRoute) -> Void = { _ in }
    var canDownload: (LibraryRoute) -> Bool = { _ in false }
    var canRemoveDownload: (LibraryRoute) -> Bool = { _ in false }
    var stopDownload: (LibraryRoute) -> Void = { _ in }
    var downloads: LibraryDownloads? = nil

    @MainActor private func downloadItem(_ route: LibraryRoute) -> LibraryMenuItem {
        let summary = downloads?.collectionState(of: route)
        if summary?.isActive == true {
            return LibraryMenuItem(title: "停止下载", systemImage: "stop.circle.fill") { stopDownload(route) }
        }
        if summary?.isComplete == true {
            return LibraryMenuItem(title: "已下载", systemImage: "checkmark.circle.fill", isDisabled: true)
        }
        let failed = (summary?.failedCount ?? 0) > 0
        return LibraryMenuItem(title: failed ? "重试下载" : "下载", systemImage: failed ? "arrow.clockwise" : "arrow.down.circle.fill", isDisabled: !canDownload(route)) { download(route) }
    }

    private func toggleFavoriteAndNotify(_ item: LibraryShelfItem, _ route: LibraryRoute) {
        toggleFavorite(route)
        if !item.id.hasPrefix("catalog:") { notify(item.isFavorite ? .unfavorited : .favorited) }
    }

    /// “移到文件夹”：与 Apple Music 一样弹出选择页，而不是子菜单。
    private func moveItem(playlistID: String) -> LibraryMenuItem {
        LibraryMenuItem(title: "移到文件夹", systemImage: "folder") { requestMove(playlistID) }
    }

    /// 专辑详情复用卡片分组，省略已在页面显示的播放按钮；播放列表保留自己的菜单。
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
            // 资料库首页的置顶区据此以动画增删卡片。
            withAnimation(.smooth(duration: 0.35)) { togglePin(route) }
            notify(item.isPinned ? .unpinned : .pinned)
        }
    }

    private func queueItems(_ route: LibraryRoute) -> [LibraryMenuItem] {
        libraryQueueMenuItems(playbackSource: playbackSource(),
                              playNext: { playNext(route) }, playLater: { playLater(route) },
                              notify: notify)
    }

    private func playItems(_ route: LibraryRoute) -> [LibraryMenuItem] {
        [LibraryMenuItem(title: "播放", systemImage: "play") { play(route, false) },
         LibraryMenuItem(title: "随机播放", systemImage: "shuffle") { play(route, true) }]
    }

    /// 资料库首页置顶项的长按菜单，对照 Apple Music：播放；插播、随后播放；轻点操作；取消置顶。
    func pinnedSections(for item: LibraryShelfItem, route: LibraryRoute, tapAction: PinnedTapAction,
                        setTapAction: @escaping (PinnedTapAction) -> Void) -> LibraryMenuSections {
        let options = PinnedTapAction.allCases.map { option in
            // 选项不带图标，与 Apple Music 一致。
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

    /// 菜单最后一组：已下载时“移除下载”（只删本地文件），以及资料库里的条目都有的“从资料库删除”。
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

    /// 专辑与播放列表的长按菜单分组，对照 Apple Music。共享本阶段不可用。
    /// 专辑未下载时首组为“下载、喜爱”横排；已下载时没有“下载”，“喜爱”单独成行，末尾多出“移除下载”。
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
            // 对照 Apple Music：编辑、开始协作、移到文件夹同组。协作本阶段不可用。
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

/// 点按资料库首页置顶项时的操作，在长按菜单的“轻点操作”里切换。
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

/// 专辑、播放列表卡片：点按进入详情，长按弹出系统菜单与横向预览卡片。
struct CollectionCardLink<Label: View>: View {
    let item: LibraryShelfItem
    /// 给定时替换默认的专辑、播放列表菜单（例如文件夹卡片）。传入的操作里“从资料库删除”由卡片自己确认。
    var menuSections: ((CollectionMenuActions) -> LibraryMenuSections)?
    /// 菜单首组是否为横排快捷操作。
    var firstSectionIsRow = true
    /// 点按卡片本身时执行；为空时进入详情。
    var tap: (() -> Void)?
    var drag: NativeMenuDrag?
    var drop: NativeMenuDrop?
    @ViewBuilder var label: Label
    @Environment(\.openLibraryRoute) private var openLibraryRoute
    @Environment(\.collectionMenuActions) private var actions
    @Environment(\.libraryZoomNamespace) private var zoomNamespace
    @State private var isConfirmingDeletion = false

    var body: some View {
        if let route = item.route {
            label
                // Include the lift's margin in its source view without changing the grid spacing.
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
                                   previewSize: MenuPreviewCard.size(for: item.previewLines),
                                   commit: { NavigationDiagnostics.event("Card.commit", page: route.diagnosticPage); openLibraryRoute(item, sourceProvider: $0) }, tap: tap,
                                   drag: drag, drop: drop)
                .padding(-8)
                .alert("", isPresented: $isConfirmingDeletion) {
                    Button("从资料库删除", role: .destructive) { withAnimation { actions.delete(route) } }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(route.deletionMessage)
                }
                // 专辑与播放列表共用 SwiftUI 原生卡片 zoom 转场。
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
    /// 详情页从对应卡片放大展开；没有共享命名空间时保持默认推入。
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
    /// 资料库卡片与详情页之间缩放转场共用的命名空间。
    @Entry var libraryZoomNamespace: Namespace.ID?
}

extension LibraryRoute {
    /// 从资料库删除前的说明。专辑的文字取自 Apple Music；播放列表沿用原有说明。
    var deletionMessage: String {
        switch self {
        case .album: "确定要从资料库删除这张专辑吗？这也会将歌曲从你喜爱的项目和制作的所有播放列表移除。"
        default: "确定要删除此播放列表吗？这会将播放列表从资料库删除。"
        }
    }
}

extension LibraryShelfItem {
    /// 播放列表的预览卡片只显示名称，不显示作者，与 Apple Music 一致。
    var previewLines: [String] {
        if case .playlist = route { return [title] }
        return [title] + (subtitle.map { [$0] } ?? [])
    }
}

// MARK: - 歌曲

/// 歌曲长按菜单与点按播放用到的操作。
struct SongMenuActions {
    var downloads: LibraryDownloads? = nil
    /// 从一组歌曲中的某一首开始播放。
    var play: (_ songs: [LibrarySongItem], _ startAt: Int, _ source: String) -> Void = { _, _, _ in }
    var playNext: (LibrarySongItem) -> Void = { _ in }
    var toggleFavorite: (LibrarySongItem) -> Void = { _ in }
    var removeFromFavorites: (LibrarySongItem) -> Void = { _ in }
    var togglePin: (LibrarySongItem) -> Void = { _ in }
    var addToPlaylist: (LibrarySongItem) -> Void = { _ in }
    var playLater: (LibrarySongItem) -> Void = { _ in }
    /// 确认后从资料库删除歌曲（也从制作的播放列表移除）。
    var delete: (LibrarySongItem) -> Void = { _ in }
    /// “随后播放”下方的当前播放来源；没有来源时菜单写“添加到队列”。
    var playbackSource: () -> String? = { nil }

    /// 专辑详情页曲目的菜单：未下载时首组为“下载 · 喜爱”横排，已下载时“喜爱”单独成行。
    /// 已在专辑页，不再提供“前往专辑”。本地歌曲随文件夹保留，不从资料库删除。
    @MainActor func albumTrackSections(for song: LibrarySongItem, isDownloaded: Bool,
                                       download: @escaping () -> Void, removeDownload: @escaping () -> Void,
                                       notify: @escaping (LibraryToast) -> Void) -> LibraryMenuSections {
        let feedback: (LibraryToast) -> Void = song.isOnline ? { _ in } : notify
        var groups = sections(for: song, notify: feedback, goToAlbum: {})
        if !song.isOnline {
            groups.removeAll { group in group.contains { $0.title == "前往专辑" } }
        }
        return groups
    }

    @MainActor private func downloadItem(for song: LibrarySongItem) -> LibraryMenuItem? {
        guard let downloads else { return unavailableDownload }
        let state = downloads.state(of: song.id)
        if state == .downloaded { return nil }
        if state?.isActive == true {
            return LibraryMenuItem(title: "停止下载", systemImage: "stop.circle.fill") { downloads.stop([song]) }
        }
        if case .failed(let message) = state {
            return LibraryMenuItem(title: "重试下载", subtitle: message, systemImage: "arrow.clockwise", isDisabled: !downloads.isDownloadable(song)) { downloads.download([song]) }
        }
        return LibraryMenuItem(title: "下载", systemImage: "arrow.down.circle.fill", isDisabled: !downloads.isDownloadable(song)) { downloads.download([song]) }
    }

    @MainActor func sections(for song: LibrarySongItem, notify: @escaping (LibraryToast) -> Void = { _ in },
                            goToAlbum: @escaping () -> Void) -> LibraryMenuSections {
        var quick = [favoriteItem(isFavorite: song.isFavorite) {
            toggleFavorite(song)
            notify(song.isFavorite ? .unfavorited : .favorited)
        }]
        if let item = downloadItem(for: song) { quick.insert(item, at: 0) }
        var additions = [LibraryMenuItem(title: "添加到播放列表", systemImage: "text.badge.plus") { addToPlaylist(song) }]
        if !song.isOnline {
            additions.insert(LibraryMenuItem(title: song.isPinned ? "取消置顶" : "置顶歌曲", systemImage: song.isPinned ? "pin.slash" : "pin") {
                togglePin(song)
                notify(song.isPinned ? .unpinned : .pinned)
            }, at: 0)
        }
        var groups: LibraryMenuSections = [quick, additions,
            libraryQueueMenuItems(playbackSource: playbackSource(), playNext: { playNext(song) }, playLater: { playLater(song) }, notify: notify)]
        if !song.isOnline {
            groups.append([LibraryMenuItem(title: "前往专辑", subtitle: song.album, systemImage: "square", customImage: MenuIcons.album, perform: goToAlbum)])
        }
        if let downloads, downloads.canRemove(song) {
            groups.append([LibraryMenuItem(title: "移除下载", systemImage: "xmark.circle") { downloads.requestRemoval([song]) }])
        }
        return groups
    }

    /// 歌曲行省略号与长按共用的完整菜单，包含在线歌曲的专辑和艺人入口。
    @MainActor func rowMenuSections(for song: LibrarySongItem, open: @escaping (LibraryRoute) -> Void) -> LibraryMenuSections {
        var groups = sections(for: song) { open(.album(song.albumID)) }
        guard song.isOnline else { return groups }
        var links: [LibraryMenuItem] = []
        if song.onlineAlbumID != nil {
            links.append(LibraryMenuItem(title: "前往专辑", systemImage: "music.note.square.stack") { open(.album(song.albumID)) })
        }
        links += song.artistReferences.map { artist in
            LibraryMenuItem(title: artist.name, systemImage: "music.microphone") { open(.artist(artist.id)) }
        }
        if !links.isEmpty { groups.append(links) }
        return groups
    }

}

extension EnvironmentValues {
    @Entry var songMenuActions = SongMenuActions()
}

extension View {
    /// 给歌曲行加上长按菜单与预览卡片；行本身的点按与“…”按钮不受影响。
    func songContextMenu(_ song: LibrarySongItem) -> some View {
        modifier(SongContextMenu(song: song))
    }
}

private struct SongContextMenu: ViewModifier {
    let song: LibrarySongItem
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    func body(content: Content) -> some View {
        let lines = [song.title, song.artist, song.album]
        content.contextMenu {
            SongNavigationMenu(song: song)
        } preview: {
            MenuPreviewCard(artwork: song.artwork, lines: lines)
                .frame(width: MenuPreviewCard.size(for: lines).width, height: MenuPreviewCard.size(for: lines).height)
        }
    }
}

/// 歌曲行与“…”按钮共用的菜单内容。
struct SongMenuContents: View {
    let song: LibrarySongItem
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var openLibraryRoute

    var body: some View {
        SongNavigationMenu(song: song)
    }
}

/// 系统符号里没有的菜单图标。
@MainActor enum MenuIcons {
    /// “前往专辑”：圆角方框里一个 ♫，与 Apple Music 一致。
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

// MARK: - 预览卡片

/// 长按时浮在菜单上方的横向卡片：封面、最多三行文字与箭头。
/// Apple Music 实测：高 123pt、封面 92pt；宽度至少 249pt，文字更长时加宽到放得下最长一行。
struct MenuPreviewCard: View {
    let artwork: Artwork
    /// 第一行为标题，其余为次要信息（艺人、专辑）。
    let lines: [String]

    private static let minWidth: CGFloat = 250
    private static let maxWidth: CGFloat = 340
    /// 文字以外的宽度：封面、各段间距、箭头与两侧内边距。
    private static let chromeWidth: CGFloat = 16 + 92 + 16 + 8 + 10 + 12
    /// 测量不含中西文之间系统自动加的间距，留一点余量以免最长一行被截断。
    private static let textSlack: CGFloat = 6

    static func size(for lines: [String]) -> CGSize {
        let fonts = [UIFont.preferredFont(forTextStyle: .headline)]
            + Array(repeating: UIFont.preferredFont(forTextStyle: .subheadline), count: max(lines.count - 1, 0))
        let textWidth = zip(lines, fonts).map { line, font in
            ceil((line as NSString).size(withAttributes: [.font: font]).width)
        }.max() ?? 0
        return CGSize(width: min(max(chromeWidth + textWidth + textSlack, minWidth), maxWidth), height: 123)
    }

    var body: some View {
        HStack(spacing: 16) {
            ArtworkView(artwork: artwork, cornerRadius: 16)
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
    @Environment(\.songMenuActions) private var actions
    @Environment(\.openLibraryRoute) private var open
    var body: some View {
        LibraryMenuContents(sections: actions.rowMenuSections(for: song) { open($0) })
    }
}
