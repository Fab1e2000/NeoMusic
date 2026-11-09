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
    func testLongQueueProjectionReusesStorageAcrossPlaybackProgress() {
        let owner = PlayerTestFixtures.owner(tracks: (0..<2_000).map { track("song-\($0)") })
        let player = ReferencePlayerState(model: owner)
        let initial = player.upcomingQueueEntries
        let version = player.upcomingQueueVersion
        XCTAssertEqual(initial.count, 1_999)
        XCTAssertEqual(initial.first?.queueIndex, 1)
        XCTAssertEqual(initial.last?.queueIndex, 1_999)

        for second in 1...5 {
            player.seek(to: Double(second))
            owner.volume = 0.5
            let current = player.upcomingQueueEntries
            XCTAssertEqual(player.upcomingQueueVersion, version)
            initial.withUnsafeBufferPointer { originalBuffer in
                current.withUnsafeBufferPointer { currentBuffer in
                    XCTAssertEqual(originalBuffer.baseAddress, currentBuffer.baseAddress,
                                   "Playback progress must reuse the long queue's presentation storage")
                }
            }
        }
    }
    func testLongQueueReorderPublishesOnceAndPreservesDuplicateOccurrences() {
        let owner = PlayerTestFixtures.owner(tracks: (0..<2_000).map { track("song-\($0 % 50)") })
        let player = ReferencePlayerState(model: owner)
        player.skip(toQueueIndex: 900)
        let current = owner.entryIDs[owner.currentIndex]
        let original = player.upcomingQueueEntries
        let songsByEntry = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.song) })
        var expected = original.map(\.id)
        expected.insert(expected.remove(at: 1_500), at: 0)
        let revision = owner.queueRevision

        player.moveUpcomingQueueItems(fromOffsets: IndexSet(integer: 1_500), toOffset: 0)

        XCTAssertEqual(owner.queueRevision, revision + 1, "A native reorder publishes one completed queue")
        XCTAssertEqual(player.upcomingQueueEntries.map(\.id), expected)
        XCTAssertEqual(owner.entryIDs[owner.currentIndex], current)
        XCTAssertEqual(owner.currentIndex, 900)
        XCTAssertEqual(Set(player.upcomingQueueEntries.map(\.id)).count, 1_999)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.song), expected.map { songsByEntry[$0]! })
    }
    func testQueueProjectionRefreshesForSelectionReorderAndArtwork() {
        let owner = PlayerTestFixtures.owner(tracks: [track("a"), track("b"), track("c"), track("d")])
        let player = ReferencePlayerState(model: owner)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.song.id), ["b", "c", "d"])
        player.skip(toQueueIndex: 1)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.song.id), ["c", "d", "a"])
        owner.repeatMode = .off
        XCTAssertEqual(player.upcomingQueueEntries.map(\.song.id), ["c", "d"])
        owner.repeatMode = .all
        player.moveUpcomingQueueItems(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.song.id), ["a", "c", "d"])
        XCTAssertEqual(player.upcomingQueueEntries.map(\.queueIndex), [2, 3, 0])

        var ready = owner.queue[3]
        let file = URL(fileURLWithPath: "/tmp/queue-cover.image")
        ready.artwork = .file(file)
        ready.artworkURL = file
        owner.updateArtwork([ready.id: ready])
        XCTAssertEqual(player.upcomingQueueEntries.first { $0.song.id == "c" }?.song.coverURL, file)

        player.enqueue(track("b"), next: true)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.song.id), ["b", "a", "c", "d"])
        player.removeFromQueue(at: 2)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.song.id), ["a", "c", "d"])
    }
    func testFavoriteAndNativeMenuGrouping() {
        var favorites: Set<String> = []
        var openedArtistID: String?
        var notes: [String] = []
        let actions = ReferencePlayerActions(isFavorite: { favorites.contains($0) },
            toggleFavorite: { if favorites.contains($0) { favorites.remove($0) } else { favorites.insert($0) } },
            addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { openedArtistID = $0 },
            notify: { notes.append($0.title) })
        let song = track("a")
        actions.toggleFavorite(song)
        XCTAssertTrue(actions.isFavorite(song))
        XCTAssertTrue(favorites.contains(song.id))
        actions.toggleFavorite(song)
        XCTAssertFalse(actions.isFavorite(song))
        XCTAssertFalse(favorites.contains(song.id))
        XCTAssertEqual(notes, [LibraryToast.favorited.title, LibraryToast.unfavorited.title])
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
    func testDeferredArtworkIdentityReachesCurrentAdjacentAndQueueTracksUntilFileArrives() {
        let songs = (0..<3).map { index in
            LibrarySongItem(id: "song-\(index)", title: "Song \(index)", artist: "Artist", album: "Album",
                albumArtist: "Artist", trackNumber: index + 1,
                artwork: .deferred(id: "cover-\(index)", placeholder: .missing), duration: 90)
        }
        let owner = NowPlayingModel(queue: songs, currentIndex: 1, isPlaying: false, elapsed: 12)
        let player = ReferencePlayerState(model: owner)
        XCTAssertEqual(player.currentTrack?.artworkLoadID, "cover-1")
        XCTAssertEqual(player.previousInOrder?.track.artworkLoadID, "cover-0")
        XCTAssertEqual(player.nextInOrder?.track.artworkLoadID, "cover-2")
        XCTAssertEqual(player.upcoming.map(\.track.artworkLoadID), ["cover-2", "cover-0"])

        var ready = songs[1]
        let file = URL(fileURLWithPath: "/tmp/player-cover.image")
        ready.artwork = .file(file)
        ready.artworkURL = file
        owner.updateArtwork([ready.id: ready])
        XCTAssertNil(player.currentTrack?.artworkLoadID)
        XCTAssertEqual(player.currentTrack?.coverURL, file)
        XCTAssertEqual(player.currentQueueIndex, 1)
        XCTAssertEqual(player.progress, 12)
        XCTAssertEqual(player.nextInOrder?.track.artworkLoadID, "cover-2")
    }

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
