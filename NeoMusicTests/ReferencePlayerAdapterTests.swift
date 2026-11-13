import XCTest
import UIKit
import SwiftUI
import Nuke
import AVFoundation
@testable import NeoMusic

@MainActor final class NowPlayingProgressScrubTests: XCTestCase {
    func testScrubSeeksOnlyWhileTheFingerIsDown() {
        let scrub = NowPlayingProgressScrub()
        var sought: [Double] = []
        scrub.propose(90) { sought.append($0) }
        scrub.propose(.nan) { sought.append($0) }
        scrub.setEditing(true)
        scrub.propose(64) { sought.append($0) }
        scrub.setEditing(false)
        scrub.propose(96) { sought.append($0) }
        XCTAssertEqual(sought, [64])
    }
}

@MainActor final class LyricsControlSurfaceHitShieldTests: XCTestCase {
    func testMissedButtonTapDoesNotReachTheLyricBehindTheControls() async throws {
        try await assertProbe(shielded: false, besideHitsLyric: true)
        try await assertProbe(shielded: true, besideHitsLyric: false)
    }

    private func assertProbe(shielded: Bool, besideHitsLyric: Bool) async throws {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        let host = UIHostingController(rootView: LyricsControlHitProbe(shielded: shielded))
        host.view.frame = window.bounds
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        defer { window.isHidden = true }

        let lyric = try XCTUnwrap(view(identifier: "lyric", in: window))
        let page = try XCTUnwrap(view(identifier: "page", in: window))
        let pageFrame = page.convert(page.bounds, to: window)
        let lyricFrame = lyric.convert(lyric.bounds, to: window)
        let onButton = CGPoint(x: pageFrame.midX, y: min(pageFrame.maxY, window.bounds.maxY) - 4)
        let beside = CGPoint(x: lyricFrame.minX + 12, y: pageFrame.minY - 16)
        let besideHit = window.hitTest(beside, with: nil)
        XCTAssertTrue(window.bounds.contains(beside))
        XCTAssertTrue(window.bounds.contains(onButton))
        XCTAssertGreaterThan(pageFrame.width, 30)
        XCTAssertFalse(pageFrame.contains(beside))
        XCTAssertEqual(isDescendant(besideHit, of: lyric), besideHitsLyric,
                       "shielded=\(shielded) beside=\(String(describing: besideHit)) page=\(pageFrame) lyric=\(lyricFrame)")
        XCTAssertTrue(isDescendant(window.hitTest(onButton, with: nil), of: page))
    }

    private func view(identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for child in root.subviews {
            if let found = view(identifier: identifier, in: child) { return found }
        }
        return nil
    }

    private func isDescendant(_ view: UIView?, of ancestor: UIView) -> Bool {
        var current = view
        while let candidate = current {
            if candidate === ancestor { return true }
            current = candidate.superview
        }
        return false
    }
}

private struct LyricsControlHitProbe: View {
    var shielded: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            HitTarget(identifier: "lyric")
                .frame(width: 300, height: 400)
            HitTarget(identifier: "page")
                .frame(width: 44, height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .frame(height: 120)
                .modifier(LyricsControlSurfaceHitShield(isActive: shielded))
        }
        .frame(width: 300, height: 400)
    }
}

private struct HitTarget: UIViewRepresentable {
    var identifier: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.accessibilityIdentifier = identifier
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.accessibilityIdentifier = identifier
    }
}

@MainActor final class ReferencePlayerAdapterTests: XCTestCase {
    private func track(_ id: String) -> ReferenceTrack {
        ReferenceTrack(id: id, title: id, artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 210)
    }
    func testLocalFormatLabelsPreserveFormatWithoutInventingQuality() {
        for ext in ["mp3", "wav", "flac", "aac", "alac", "aiff", "m4a"] {
            let value = PlayerAudioQuality.localFile(URL(fileURLWithPath: "/music/track.\(ext.uppercased())"))
            XCTAssertEqual(value?.title, ext.uppercased())
            XCTAssertEqual(value?.isLocalFormat, true)
            XCTAssertEqual(value?.isLossless, false)
        }
        XCTAssertEqual(PlayerAudioQuality.localFile(URL(fileURLWithPath: "/music/track.aif"))?.title, "AIFF")
        XCTAssertNil(PlayerAudioQuality.localFile(URL(fileURLWithPath: "/music/track.txt")))
    }

    func testAudioQualityLookupUsesCurrentTrackAndInjectedSettingsAction() {
        var resourceTrackID = "a"
        var resolvedQuality = PlayerAudioQuality(title: "无损", detail: "24 位 / 48 kHz", isLossless: true)
        var settingsRequests = 0
        let actions = ReferencePlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
            addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in },
            audioQuality: { $0 == resourceTrackID ? resolvedQuality : nil },
            openAudioQualitySettings: { settingsRequests += 1 })
        XCTAssertEqual(actions.audioQuality(for: track("a")), resolvedQuality)
        XCTAssertNil(actions.audioQuality(for: track("b")))
        resourceTrackID = "b"
        resolvedQuality = PlayerAudioQuality(title: "高品质")
        XCTAssertNil(actions.audioQuality(for: track("a")))
        XCTAssertEqual(actions.audioQuality(for: track("b")), resolvedQuality)
        XCTAssertTrue(actions.canOpenAudioQualitySettings)
        actions.openAudioQualitySettings()
        XCTAssertEqual(settingsRequests, 1)
    }

    func testExistingPlayerActionsDoNotInventQualityOrSettingsCapability() {
        let actions = PlayerTestFixtures.actions()
        XCTAssertNil(actions.audioQuality(for: track("a")))
        XCTAssertFalse(actions.canOpenAudioQualitySettings)
    }

    func testFiniteForwardAdapterUsesOwnerCapabilityAndAcceptsConsecutiveActions() {
        let owner = PlayerTestFixtures.owner(tracks: [track("a"), track("b"), track("a")])
        let player = ReferencePlayerState(model: owner)
        owner.repeatMode = .off
        player.next()
        XCTAssertEqual(owner.currentIndex, 1)
        player.next()
        XCTAssertEqual(owner.currentIndex, 2)
        XCTAssertFalse(player.canPlayNext)
        player.next()
        XCTAssertEqual(owner.currentIndex, 2)
        owner.repeatMode = .all
        XCTAssertTrue(player.canPlayNext)
        player.next()
        XCTAssertEqual(owner.currentIndex, 0)
        XCTAssertFalse(owner.isPlaying)
    }

    func testContinuingForwardAdapterRequestsNextBatchAndDoesNotWrapProjection() {
        let owner = PlayerTestFixtures.owner(tracks: [track("a"), track("b")])
        let player = ReferencePlayerState(model: owner)
        owner.play(owner.queue, startingAt: 1, from: "Radio",
                   continuation: PlaybackQueueContinuation(ownerID: "42"))
        var advanceRequests = 0
        owner.replenishQueue = { _, advance, _ in if advance { advanceRequests += 1 } }
        XCTAssertTrue(player.canPlayNext)
        XCTAssertNil(player.nextInOrder)
        XCTAssertTrue(player.upcomingQueueEntries.isEmpty)
        let continuingVersion = player.upcomingQueueVersion
        player.next()
        player.next()
        XCTAssertEqual(advanceRequests, 2)
        XCTAssertEqual(owner.currentIndex, 1)
        owner.repeatMode = .off
        XCTAssertTrue(player.canPlayNext)
        player.next()
        XCTAssertEqual(advanceRequests, 3)

        owner.repeatMode = .all
        owner.invalidateOnlinePlayback(ownerID: nil)
        XCTAssertNotEqual(player.upcomingQueueVersion, continuingVersion)
        XCTAssertEqual(player.nextInOrder?.index, 0)
        XCTAssertEqual(player.upcomingQueueEntries.map(\.queueIndex), [0])
    }

    func testLyricsContentHidesPayloadDuringTrackMismatchAndLoading() async {
        let model = NowPlayingLyricsModel()
        await model.load(trackID: "old") { ReferenceLyrics.parse("[00:01]old") }
        let content = NowPlayingLyricsContent(availability: model.availability(for: "new"),
                                             lyrics: model.lyrics, error: "Old track error")
        XCTAssertNil(content.lyrics)
        XCTAssertNil(content.error)
        let loaded = NowPlayingLyricsContent(availability: model.availability(for: "old"),
                                            lyrics: model.lyrics, error: model.error)
        XCTAssertEqual(loaded.lyrics?.lines.first?.text, "old")
    }

    func testLyricsContentPreservesEmptyAndFailedStates() async {
        let model = NowPlayingLyricsModel()
        await model.load(trackID: "empty") { ReferenceLyrics.parse("") }
        let empty = NowPlayingLyricsContent(availability: model.availability(for: "empty"),
                                           lyrics: model.lyrics, error: model.error)
        XCTAssertTrue(empty.lyrics?.isEmpty == true)
        XCTAssertNil(empty.error)
        await model.load(trackID: "failed") { throw URLError(.notConnectedToInternet) }
        let failed = NowPlayingLyricsContent(availability: model.availability(for: "failed"),
                                            lyrics: model.lyrics, error: model.error)
        XCTAssertNil(failed.lyrics)
        XCTAssertNotNil(failed.error)
    }

    func testCancelledLyricsResultDoesNotPublishPayloadOrError() async {
        let model = NowPlayingLyricsModel()
        var continuation: CheckedContinuation<ReferenceLyrics, Never>?
        let loading = Task {
            await model.load(trackID: "cancelled") {
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        loading.cancel()
        continuation?.resume(returning: ReferenceLyrics.parse("[00:01]cancelled"))
        await loading.value
        XCTAssertNil(model.lyrics)
        XCTAssertNil(model.error)
    }

    func testAudioOutputUsesPortNamesWithoutAssumingBluetoothDeviceModel() {
        for port in [AVAudioSession.Port.bluetoothA2DP, .bluetoothLE, .bluetoothHFP] {
            let output = ReferenceAudioOutput(outputs: [(port, "Living Room Speaker")])
            XCTAssertEqual(output.name, "Living Room Speaker")
            XCTAssertFalse(output.isAirPlay)
        }
        let airPlay = ReferenceAudioOutput(outputs: [(.airPlay, "Kitchen"), (.airPlay, "Bedroom")])
        XCTAssertEqual(airPlay.name, "Kitchen，Bedroom")
        XCTAssertTrue(airPlay.isAirPlay)
        XCTAssertEqual(ReferenceAudioOutput(outputs: []).name, "")
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

    func testArtistMenusMeetMinimumHitRegionAtDefaultAndAccessibilitySizes() async throws {
        let scene = try await applicationWindowScene()
        let song = track("artist-hit-region")
        let player = PlayerTestFixtures.state(tracks: [song])
        let actions = PlayerTestFixtures.actions()
        let sizes: [(DynamicTypeSize, UIContentSizeCategory)] = [
            (.large, .large),
            (.accessibility5, .accessibilityExtraExtraExtraLarge)
        ]

        for (size, category) in sizes {
            for surface in ArtistHitRegionSurface.allCases {
                let context = "\(surface.rawValue), \(category.rawValue)"
                let laidOut = expectation(description: "Artist control laid out: \(context)")
                var reportedLayout = false
                let content = ArtistHitRegionContent(song: song, surface: surface)
                    .environment(player)
                    .environment(actions)
                    .environment(\.playerVisualsActive, false)
                    .environment(\.playerArtistEDREnabled, false)
                    .dynamicTypeSize(size)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { measured in
                        guard !reportedLayout, measured.width > 0, measured.height > 0 else { return }
                        reportedLayout = true
                        laidOut.fulfill()
                    }
                let host = UIHostingController(rootView: content)
                host.traitOverrides.preferredContentSizeCategory = category
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
                window.rootViewController = host
                window.isHidden = false
                defer { window.isHidden = true }
                host.view.layoutIfNeeded()
                await fulfillment(of: [laidOut], timeout: 2)
                host.view.layoutIfNeeded()

                let button = try XCTUnwrap(artistMenuButtons(in: host.view).first {
                    $0.accessibilityLabel == song.artists && $0.showsMenuAsPrimaryAction
                }, context)
                let hierarchy = artistHitHierarchy(button, in: window)
                let measurement = XCTAttachment(string: "\(context)\n\(hierarchy)")
                measurement.name = "Artist hit region: \(context)"
                measurement.lifetime = .keepAlways
                add(measurement)

                XCTAssertGreaterThanOrEqual(button.bounds.width, 28, "\(context)\n\(hierarchy)")
                XCTAssertGreaterThanOrEqual(button.bounds.height, 28, "\(context)\n\(hierarchy)")
                let bounds = button.bounds
                let points = [
                    CGPoint(x: bounds.midX, y: bounds.midY),
                    CGPoint(x: bounds.midX, y: bounds.minY + 0.5),
                    CGPoint(x: bounds.midX, y: bounds.maxY - 0.5),
                    CGPoint(x: bounds.minX + 0.5, y: bounds.midY),
                    CGPoint(x: bounds.maxX - 0.5, y: bounds.midY)
                ]
                for point in points {
                    let windowPoint = button.convert(point, to: window)
                    let hit = window.hitTest(windowPoint, with: nil)
                    XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                                  "\(context), point=\(windowPoint), hit=\(String(describing: hit))\n\(hierarchy)")
                }
            }
        }
    }

    private func artistMenuButtons(in view: UIView) -> [UIButton] {
        let matches = (view as? UIButton).map { [$0] } ?? []
        return matches + view.subviews.flatMap { artistMenuButtons(in: $0) }
    }

    private func artistHitHierarchy(_ button: UIButton, in window: UIWindow) -> String {
        var lines: [String] = []
        var ancestor: UIView? = button
        while let view = ancestor {
            lines.append("\(type(of: view)): frame=\(view.frame), bounds=\(view.bounds), window=\(view.convert(view.bounds, to: window)), clips=\(view.clipsToBounds), hidden=\(view.isHidden), alpha=\(view.alpha)")
            ancestor = view.superview
        }
        return lines.joined(separator: "\n")
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

private enum ArtistHitRegionSurface: String, CaseIterable {
    case songHeader
    case artwork
}

private struct ArtistHitRegionContent: View {
    let song: ReferenceTrack
    let surface: ArtistHitRegionSurface
    @Namespace private var artworkNamespace

    var body: some View {
        Group {
            switch surface {
            case .songHeader:
                NowPlayingSongHeader(song: song, artworkNamespace: artworkNamespace,
                                     usesReferenceLayout: true, usesArtworkTransition: false, showsArtwork: false)
            case .artwork:
                NowPlayingArtworkPage(song: song, artworkNamespace: artworkNamespace,
                                      usesArtworkTransition: false, showsArtwork: false)
                    .frame(height: 650)
            }
        }
        .frame(width: 338)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        XCTAssertNil(LocalArtworkImages.cached(url, pixels: 160))
        XCTAssertNotNil(PlayerPopup.cachedArtwork(for: url), "The mini player must synchronously consume its prefetch cache")
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
