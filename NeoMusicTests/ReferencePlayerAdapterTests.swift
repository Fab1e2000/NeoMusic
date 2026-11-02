import XCTest
import UIKit
import Nuke
@testable import NeoMusic

@MainActor final class ReferencePlayerAdapterTests: XCTestCase {
    private func track(_ id: String) -> ReferenceTrack {
        ReferenceTrack(id: id, title: id, artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 210)
    }
    func testDuplicateQueueOccurrencesSelectAndEnqueueIndependently() {
        let a = track("a"), b = track("b")
        let owner = PlayerTestFixtures.owner(tracks: [a, b, a])
        let player = ReferencePlayerState(model: owner)
        player.skip(toQueueIndex: 2)
        XCTAssertEqual(player.currentQueueIndex, 2)
        XCTAssertEqual(player.upcoming.map(\.index), [0, 1])
        player.enqueue(b, next: true)
        XCTAssertEqual(player.upcoming.first?.index, 3)
        XCTAssertEqual(player.upcoming.first?.track.id, "b")
        player.enqueue(a, next: false)
        XCTAssertEqual(player.upcoming.map(\.track.id), ["b", "a", "a", "b"])
        player.playFromQueue(at: 3)
        XCTAssertEqual(player.currentTrack?.id, "b")
        XCTAssertEqual(player.progress, 0)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(owner.currentIndex, 3)
        XCTAssertTrue(owner.isPlaying)
    }
    func testUpcomingReorderPreservesCurrentSongAndPosition() {
        let player = PlayerTestFixtures.state(tracks: [track("a"), track("b"), track("c"), track("d")])
        player.skip(toQueueIndex: 1)
        player.seek(to: 24)
        player.moveUpcomingQueueItems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(player.currentQueueIndex, 1)
        XCTAssertEqual(player.currentTrack?.id, "b")
        XCTAssertEqual(player.progress, 24)
        XCTAssertEqual(player.upcoming.map(\.track.id), ["a", "c", "d"])
    }
    func testFavoriteAndNativeMenuGrouping() {
        var favorites: Set<String> = []
        var openedArtistID: String?
        let actions = ReferencePlayerActions(isFavorite: { favorites.contains($0) },
            toggleFavorite: { if favorites.contains($0) { favorites.remove($0) } else { favorites.insert($0) } },
            addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { openedArtistID = $0 })
        let song = track("a")
        actions.toggleFavorite(song)
        XCTAssertTrue(actions.isFavorite(song))
        XCTAssertTrue(favorites.contains(song.id))
        actions.toggleFavorite(song)
        XCTAssertFalse(actions.isFavorite(song))
        XCTAssertFalse(favorites.contains(song.id))
        let configuration = SongMenuConfiguration(
            primary: [.init(id: "favorite", title: "喜欢", systemImage: "star.fill") {}],
            secondary: [.init(id: "album", title: "查看专辑", systemImage: "music.note.square.stack") {}],
            artistTitle: "查看艺人", artists: [.init(id: "artist", title: "Artist", systemImage: "music.microphone") {}],
            extras: [.init(id: "lyrics", title: "导入本地歌词", systemImage: "square.and.arrow.down") {}])
        let groups = configuration.nativeItems.compactMap { $0 as? UIMenu }
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].children.map(\.title), ["喜欢"])
        XCTAssertEqual(groups[1].children.map(\.title), ["查看专辑", "查看艺人"])
        XCTAssertEqual(groups[2].children.map(\.title), ["导入本地歌词"])
        actions.openArtist("Artist", track: song)
        XCTAssertEqual(openedArtistID, song.id)
    }
    func testArtistButtonMenuShowsAvailableDestinationsWithSubtitles() {
        let actions = PlayerTestFixtures.actions()
        let controller = PlayerArtistMenuController()
        let song = track("a")
        controller.bind(track: song, actions: actions)
        let items = controller.menu()?.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(items?.map(\.title), ["前往专辑", "前往艺人"])
        XCTAssertEqual(items?.compactMap(\.subtitle), ["Album", "Artist"])

        let updated = ReferenceTrack(id: "a", title: "a", artists: "New Artist", albumTitle: "", coverURL: nil, duration: 210)
        XCTAssertTrue(controller.bind(track: updated, actions: actions))
        XCTAssertEqual(controller.menu()?.children.map(\.title), ["前往艺人"])
        XCTAssertEqual(controller.menu()?.children.first?.subtitle, "New Artist")
    }
    func testImportedLyricsLateResponseDoesNotReplaceNewSong() async {
        let model = NowPlayingLyricsModel()
        var continuation: CheckedContinuation<ReferenceLyrics, Never>?
        let old = Task {
            await model.load(trackID: "old") { await withCheckedContinuation { continuation = $0 } }
        }
        while continuation == nil { await Task.yield() }
        await model.load(trackID: "new") { ReferenceLyrics.parse("[00:01]new") }
        continuation?.resume(returning: ReferenceLyrics.parse("[00:01]old"))
        await old.value
        XCTAssertEqual(model.lyrics?.lines.first?.text, "new")
        XCTAssertEqual(model.availability(for: "new"), .available)
        XCTAssertEqual(model.availability(for: "old"), .loading)
    }

    func testLyricsAdapterUsesStoreAndDoesNotInventMissingLyrics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("imports")
        let audio = root.appendingPathComponent("song.wav")
        let reader = ReferenceLyricsReader(storageDirectory: store, root: root,
            resolveAudioURL: { $0 == "song" ? audio : nil })
        let missing = try await reader.load(trackID: "missing")
        XCTAssertTrue(missing.isEmpty)
        let input = root.appendingPathComponent("lyrics.lrc")
        try Data("[00:01]Imported line".utf8).write(to: input)
        try await reader.importFile(input, trackID: "song")
        let reopened = ReferenceLyricsReader(storageDirectory: store, root: root,
            resolveAudioURL: { $0 == "song" ? audio : nil })
        let saved = try await reopened.load(trackID: "song")
        XCTAssertEqual(saved.lines.first?.text, "Imported line")
    }
}

@MainActor final class ReferenceTrackPagingTests: XCTestCase {
    func testPrefetchWarmsExactArtworkRequests() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try XCTUnwrap(image.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let thumbnails = [160, 240].map { size in
            var request = ImageRequest(url: url)
            request.thumbnail = .init(size: CGSize(width: size, height: size), unit: .pixels, contentMode: .aspectFill)
            return request
        }
        let full = try XCTUnwrap(ArtworkImagePipeline.request(for: url, size: CGSize(width: 128, height: 128), displayScale: 3))
        let requests = thumbnails + [full]
        await ArtworkImagePipeline.prefetch(requests)
        for request in requests {
            XCTAssertNotNil(ImagePipeline.shared.cache.cachedImage(for: request))
        }
    }
}

extension ReferencePlayerAdapterTests {
    func testProductionFacadeReadsLiveQueueAndWritesSameOwner() {
        let a = LibrarySongItem(id: "local/a", title: "A", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing, duration: 90)
        let b = LibrarySongItem(id: "local/b", title: "B", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 2, artwork: .missing, duration: 100)
        let owner = NowPlayingModel(queue: [a, b], currentIndex: 0, isPlaying: false, elapsed: 12)
        let facade = ReferencePlayerState(model: owner)
        XCTAssertEqual(facade.currentTrack?.id, a.id)
        XCTAssertEqual(facade.progress, 12)
        facade.enqueue(facade.currentTrack!, next: false)
        XCTAssertEqual(owner.queue.map(\.id), [a.id, b.id, a.id])
        owner.select(1)
        XCTAssertEqual(facade.currentTrack?.title, "B")
        facade.seek(to: 30)
        XCTAssertEqual(owner.elapsed, 30)
        facade.cycleRepeatMode()
        XCTAssertEqual(facade.repeatMode, .one)
    }
}
