import XCTest
import SwiftUI
@testable import NeoMusic
@testable import FullScreenPlayer

@MainActor
final class LibraryListAccessibilityTests: XCTestCase {
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func descendants<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        var result: [T] = []
        if let match = view as? T { result.append(match) }
        for subview in view.subviews {
            result.append(contentsOf: descendants(of: type, in: subview))
        }
        return result
    }

    private func song(title: String = "夜曲", artist: String = "周杰伦",
                      reason: String? = nil) -> LibrarySongItem {
        LibrarySongItem(id: "song", title: title, artist: artist, album: "十一月的萧邦",
                        albumArtist: artist, trackNumber: 1, artwork: .missing,
                        unavailabilityReason: reason)
    }

    private func playlistList(deselectsImmediately: Bool,
                              opened: @escaping (PlaylistEntry) -> Void = { _ in }) -> GenericCollectionList<PlaylistEntry> {
        GenericCollectionList<PlaylistEntry>(
            items: [.playlist(.init(id: "playlist", title: "播放列表", artwork: .playlist))],
            menu: { _ in UIMenu() },
            open: { entry, _ in opened(entry) },
            moveItem: nil,
            shelfItem: \.shelfItem,
            route: \.route,
            deselectsImmediately: deselectsImmediately
        )
    }

    func testGenericCollectionListRequiresStringIdentifiers() {
        XCTAssertTrue(PlaylistEntry.ID.self == String.self)
        let list = playlistList(deselectsImmediately: false)
        XCTAssertEqual(list.items.map(\.id), ["playlist"])
    }

    func testActionRowsDeselectImmediatelyWhileNavigationRowsKeepSelection() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }

        var opened: [String] = []
        let host = UIHostingController(rootView: playlistList(deselectsImmediately: true) { opened.append($0.id) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await settle()

        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)
        let path = IndexPath(item: 0, section: 0)
        collection.selectItem(at: path, animated: false, scrollPosition: [])
        XCTAssertEqual(collection.indexPathsForSelectedItems, [path])
        collection.delegate?.collectionView?(collection, didSelectItemAt: path)
        XCTAssertEqual(opened, ["playlist"])
        XCTAssertEqual(collection.indexPathsForSelectedItems ?? [], [],
                       "An action-only row must not keep the system selection fill")

        host.rootView = playlistList(deselectsImmediately: false)
        try await settle()
        let navigating = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)
        navigating.selectItem(at: path, animated: false, scrollPosition: [])
        navigating.delegate?.collectionView?(navigating, didSelectItemAt: path)
        XCTAssertEqual(navigating.indexPathsForSelectedItems, [path],
                       "Navigating rows keep the selection for the push transition to fade")
    }

    func testSongRowLabelIncludesTitleArtistAndUnavailabilityReason() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }

        let unavailable = song(reason: "暂无完整音源")
        let host = UIHostingController(rootView: NativePlaylistTrackList(
            songs: [unavailable],
            title: "播放列表",
            header: AnyView(EmptyView()),
            banner: nil,
            footer: nil,
            showsAddMusicRow: false,
            pageColor: .systemBackground,
            scheme: .light,
            onPlaySong: { _, _ in }
        ))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await settle()

        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)
        let path = try XCTUnwrap(collection.indexPathsForVisibleItems.first { path in
            collection.cellForItem(at: path)?.accessibilityLabel?.contains(unavailable.title) == true
        })
        let cell = try XCTUnwrap(collection.cellForItem(at: path))
        XCTAssertEqual(cell.accessibilityLabel, "夜曲, 周杰伦, 暂无完整音源")

        let more = try XCTUnwrap(descendants(of: UIButton.self, in: cell).first { $0.accessibilityLabel == "更多" })
        XCTAssertFalse(more.isHidden)
        XCTAssertTrue(more.isEnabled)
        XCTAssertTrue(more.showsMenuAsPrimaryAction)
        XCTAssertFalse(cell.isAccessibilityElement,
                       "The row stays a container so its buttons remain reachable")
    }

    func testSongRowLabelOmitsMissingUnavailabilityReason() {
        XCTAssertEqual(CollectionTrackUI.songAccessibilityLabel(for: song()), "夜曲, 周杰伦")
        XCTAssertEqual(CollectionTrackUI.songAccessibilityLabel(for: song(reason: "暂无完整音源")),
                       "夜曲, 周杰伦, 暂无完整音源")
    }

    func testNativeTrackAggregatesPlaybackLabelAndKeepsDownloadAndMenuSeparate() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }

        let title = String(repeating: "很长的歌曲标题", count: 5)
        var track = song(title: title)
        track.isFavorite = true
        let downloads = LibraryDownloads()
        downloads.publish(states: [track.id: .downloading(0.42)], managedSongIDs: [track.id])
        var played: [String] = []
        let host = UIHostingController(rootView: NativePlaylistTrackList(
            songs: [track], title: "歌曲", header: nil, banner: nil, footer: nil,
            showsAddMusicRow: false, pageColor: .systemBackground, scheme: .light,
            onPlaySong: { song, _ in played.append(song.id) }
        ).environment(\.libraryDownloads, downloads).dynamicTypeSize(.accessibility3))
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await settle()

        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)
        let cell = try XCTUnwrap(collection.visibleCells.first)
        let label = try XCTUnwrap(descendants(of: UILabel.self, in: cell).first {
            $0.accessibilityIdentifier == "library.track.song"
        })
        XCTAssertEqual(label.accessibilityLabel, "\(title), 周杰伦, 已喜爱")
        XCTAssertTrue(label.accessibilityTraits.contains(.button))
        XCTAssertEqual(label.numberOfLines, 0)
        XCTAssertGreaterThan(label.bounds.height, label.font.lineHeight)
        XCTAssertTrue(label.accessibilityActivate())
        XCTAssertEqual(played, [track.id])

        let buttons = descendants(of: UIButton.self, in: cell)
        let stop = try XCTUnwrap(buttons.first { $0.accessibilityLabel == "停止下载" })
        XCTAssertEqual(stop.accessibilityValue, "正在下载，42%")
        for button in [stop, try XCTUnwrap(buttons.first { $0.accessibilityLabel == "更多" })] {
            XCTAssertTrue(button.isAccessibilityElement)
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        }
    }

    func testPlayShuffleLayoutStacksOnlyAtAccessibilitySizes() {
        let controls = PlayShuffleButtons(play: {}, shuffle: {})
        let container = CGSize(width: 330, height: 500)
        let regular = UIHostingController(rootView: controls.dynamicTypeSize(.large))
        let accessible = UIHostingController(rootView: controls.dynamicTypeSize(.accessibility3))
        XCTAssertEqual(regular.sizeThatFits(in: container).height, 48, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(accessible.sizeThatFits(in: container).height, 108)
    }

    func testDownloadAccessibilityStatusUsesProgressAndHidesRawFailureDetails() {
        XCTAssertEqual(LibraryDownloads.SongState.queued.accessibilityStatus, "等待下载")
        XCTAssertEqual(LibraryDownloads.SongState.waiting.accessibilityStatus, "等待 Wi-Fi")
        XCTAssertEqual(LibraryDownloads.SongState.finishing.accessibilityStatus, "正在处理")
        XCTAssertEqual(LibraryDownloads.SongState.downloaded.accessibilityStatus, "已下载")
        XCTAssertEqual(LibraryDownloads.SongState.downloading(1.2).accessibilityStatus, "正在下载，100%")
        XCTAssertEqual(LibraryDownloads.SongState.downloading(.nan).accessibilityStatus, "正在下载，0%")
        XCTAssertEqual(LibraryDownloads.SongState.failed("unknown details").accessibilityStatus, "下载失败")
    }

    func testTrackListUsesNativeIndexForGroupsAndPreservesPlaybackOffsets() async throws {
        let first = song(title: "Angelic")
        let last = LibrarySongItem(id: "last", title: "夜曲", artist: "周杰伦", album: "Album",
                                   albumArtist: "周杰伦", trackNumber: 2, artwork: .missing)
        let controller = PlaylistTracksController()
        var selectedOffset: Int?
        var list = NativePlaylistTrackList(songs: [first, last], title: "歌曲", header: AnyView(EmptyView()),
            banner: nil, footer: nil, showsAddMusicRow: false, pageColor: .systemBackground, scheme: .light,
            indexedSections: [.init(title: "A", songIDs: [first.id]), .init(title: "#", songIDs: [last.id])],
            usesLibrarySongAppearance: true, onPlaySong: { _, offset in selectedOffset = offset })
        controller.update(list, environment: EnvironmentValues())
        let collection = try XCTUnwrap(controller.collectionView)
        let dataSource = try XCTUnwrap(collection.dataSource)
        XCTAssertEqual(dataSource.indexTitles?(for: collection), ["A", "#"])
        XCTAssertEqual(dataSource.collectionView?(collection, indexPathForIndexTitle: "#", at: 1),
                       IndexPath(item: 0, section: 2))
        XCTAssertFalse(controller.collectionView(collection, shouldSelectItemAt: IndexPath(item: 0, section: 2)))
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 2))
        XCTAssertEqual(selectedOffset, 1)

        list.indexedSections = nil
        controller.update(list, environment: EnvironmentValues())
        XCTAssertNil(dataSource.indexTitles?(for: collection))
        XCTAssertEqual(collection.numberOfSections, 1)
    }

    func testSwipeActionsCarryTheirOwnVoiceOverLabels() throws {
        let actions = SongMenuActions()
        let leading = CollectionTrackUI.leadingSwipeConfiguration(
            for: song(), songActions: actions, notify: { _ in })
        XCTAssertEqual(leading.actions.map { $0.accessibilityLabel }, ["插播", "添加到队列"])

        let editable = try XCTUnwrap(CollectionTrackUI.trailingSwipeConfiguration(
            for: song(), mode: .editablePlaylist(remove: { _ in }),
            downloads: nil, songActions: actions, notify: { _ in }))
        XCTAssertEqual(editable.actions.map { $0.accessibilityLabel }, ["移除"])

        var favorite = song()
        favorite.isFavorite = true
        let standard = try XCTUnwrap(CollectionTrackUI.trailingSwipeConfiguration(
            for: favorite, mode: .standard(animateFavoriteRemoval: false),
            downloads: nil, songActions: actions, notify: { _ in }))
        XCTAssertEqual(standard.actions.map { $0.accessibilityLabel }, ["从喜欢歌曲移除"])

        let unfavorited = try XCTUnwrap(CollectionTrackUI.trailingSwipeConfiguration(
            for: song(), mode: .standard(animateFavoriteRemoval: false),
            downloads: nil, songActions: actions, notify: { _ in }))
        XCTAssertEqual(unfavorited.actions.map { $0.accessibilityLabel }, ["喜欢"])
    }

    func testQueueRemovalSwipeActionCarriesItsOwnLabel() async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }

        let entry = PlayerQueueEntry(
            id: UUID(), queueIndex: 1,
            song: PlayerTrack(id: "track", title: "夜曲", artists: "周杰伦",
                              albumTitle: "十一月的萧邦", coverURL: nil, duration: 60))
        let host = UIHostingController(rootView: QueueLabelTestView(entries: [entry]))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await settle()

        let collection = try XCTUnwrap(descendants(of: UICollectionView.self, in: host.view).first)
        let coordinator = try XCTUnwrap(collection.delegate as? NowPlayingQueueList.Coordinator)
        let actions = try XCTUnwrap(coordinator.trailingActions(at: IndexPath(item: 0, section: 1)))
        XCTAssertEqual(actions.actions.map { $0.accessibilityLabel }, ["从继续播放列表删除"])
        XCTAssertEqual(actions.actions.first?.image?.accessibilityLabel, "从继续播放列表删除")
    }
}

@MainActor
private struct QueueLabelTestView: View {
    @Namespace private var artworkNamespace
    let entries: [PlayerQueueEntry]
    private let actions = PlayerTestFixtures.actions()
    private let player = PlayerTestFixtures.state(tracks: [])
    private let library = PlayerTestFixtures.library()

    var body: some View {
        NowPlayingQueueList(entries: entries,
                            version: PlayerQueueVersion(revision: 1, index: 0, repeatMode: .all),
                            subtitle: "接下来播放的歌曲",
                            songHeader: NowPlayingQueueSongHeader(song: entries[0].song, artworkNamespace: artworkNamespace),
                            headerHeight: NowPlayingQueuePage.songHeaderHeight, horizontalInset: 32,
                            onPlay: { _ in }, onMove: { _, _ in }, onScroll: { _ in })
            .environment(player)
            .environment(actions)
            .environment(NeoMusicPlayerServices.make(actions: actions, library: library,
                prepareArtwork: { _ in }))
            .environment(\.playerVisualsActive, true)
            .environment(\.artworkLoadAction, ArtworkLoadAction(handler: { _ in }))
    }
}
