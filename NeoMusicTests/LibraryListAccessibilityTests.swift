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
