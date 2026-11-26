import XCTest
import SwiftUI
import Observation
import FrontAMPlayer

@MainActor final class PlayerContractTests: XCTestCase {
    func testPlaybackReadsStayLiveWithoutPublishingAnotherQueue() {
        let owner = TestPlaybackSource()
        let player = PlayerState(source: owner)
        var titleChanges = 0
        withObservationTracking { _ = player.currentTrack?.title } onChange: {
            MainActor.assumeIsolated { titleChanges += 1 }
        }
        owner.progress = 15
        XCTAssertEqual(player.progress, 15)
        XCTAssertEqual(titleChanges, 0)
        owner.currentTrack = PlayerTrack(id: "other", title: "Other", artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 120)
        XCTAssertEqual(player.currentTrack?.id, "other")
        XCTAssertEqual(titleChanges, 1)
        XCTAssertTrue(player.upcomingQueueEntries.isEmpty)
    }

    func testCommandsReachTheSameOwnerAndSeparatePlayersStayIndependent() {
        let first = TestPlaybackSource(), second = TestPlaybackSource()
        let player = PlayerState(source: first), other = PlayerState(source: second)
        player.togglePlayback()
        player.seek(to: 42)
        player.next()
        player.next()
        player.moveUpcomingQueueItems(fromOffsets: [0], toOffset: 2)
        player.removeFromQueue(at: 3)
        XCTAssertTrue(first.isPlaying)
        XCTAssertEqual(first.progress, 42)
        XCTAssertEqual(first.commands, ["next", "next", "move:0:2", "remove:3"])
        XCTAssertFalse(other.isPlaying)
        XCTAssertEqual(other.progress, 0)
        XCTAssertTrue(second.commands.isEmpty)
    }

    func testPublicRootAcceptsHostServicesAndAnOptionalContainerModifier() {
        let owner = TestPlaybackSource()
        let player = PlayerState(source: owner)
        let services = makeServices()
        let root = FullScreenPlayerView(player: player, services: services)
        let decorated = FullScreenPlayerView(player: player, services: services, initialPage: .queue,
                                             artworkTransition: TestTransition())
        _ = root.body
        _ = decorated.body
        XCTAssertFalse(services.lyrics.canImport)
    }

    func testArtworkProviderPreservesRequestDimensionsAndForwardsPreparation() async throws {
        var prepared: [String] = [], requests: [PlayerArtworkRequest] = []
        let image = UIImage()
        let provider = PlayerArtworkProvider(cached: { _ in image }, load: { request in
            requests.append(request); return image
        }, prefetch: { requests.append(contentsOf: $0) }, prepare: { prepared.append($0) })
        let request = PlayerArtworkRequest(url: URL(fileURLWithPath: "/cover"), pixelWidth: 320, pixelHeight: 240, fits: true)
        provider.prepare("opaque-resource")
        provider.prepare(nil)
        XCTAssertTrue(provider.cached(request) === image)
        let loaded = try await provider.load(request)
        XCTAssertTrue(loaded === image)
        await provider.prefetch([request])
        XCTAssertEqual(requests, [request, request])
        XCTAssertEqual(prepared, ["opaque-resource"])
    }

    func testLyricsServiceUsesOpaqueIdentityAndHostRevision() async throws {
        let revision = Revision()
        var imports: [String] = []
        let provider = PlayerLyricsSource(revision: { revision.value }, load: { id in
            PlayerLyrics(lines: [.init(id: 9, time: 3, text: id)])
        }, importFile: { _, id in imports.append(id) })
        let document = try await provider.load(trackID: "arbitrary/identity")
        XCTAssertEqual(document.lines.first?.text, "arbitrary/identity")
        XCTAssertEqual(document.activeLine(at: 3), 9)
        try await provider.importFile(URL(fileURLWithPath: "/lyrics"), trackID: "arbitrary/identity")
        revision.value = 2
        XCTAssertEqual(provider.contentRevision, 2)
        XCTAssertEqual(imports, ["arbitrary/identity"])
    }

    private func makeServices() -> PlayerServices {
        PlayerServices(actions: PlayerActions(isFavorite: { _ in false }, toggleFavorite: { _ in },
            addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in }),
            lyrics: PlayerLyricsSource(load: { _ in PlayerLyrics() }),
            artwork: PlayerArtworkProvider(cached: { _ in nil }, load: { _ in throw URLError(.fileDoesNotExist) }))
    }
}

private struct TestTransition: ViewModifier {
    func body(content: Content) -> some View { content.accessibilityIdentifier("external-transition") }
}

@MainActor @Observable final class TestPlaybackSource: PlayerPlaybackSource {
    var currentTrack: PlayerTrack? = PlayerTrack(id: "one", title: "One", artists: "Artist", albumTitle: "Album", coverURL: nil, duration: 120)
    var tracks: [PlayerTrack] { currentTrack.map { [$0] } ?? [] }
    var currentQueueIndex = 0
    var isPlaying = false
    var isLoading = false
    var issue: String?
    var duration = 120.0
    var progress = 0.0
    var isCrossfadeEnabled = false
    var isShuffled = false
    var repeatMode = PlayerRepeatMode.off
    var canPlayNext = true
    var canPlayPrevious = true
    var canAutomaticallyContinue = false
    var isAutomaticContinuationEnabled = false
    var automaticContinuationDescription = "Queue"
    var previousInOrder: PlayerAdjacentTrack?
    var nextInOrder: PlayerAdjacentTrack?
    var upcoming: [PlayerAdjacentTrack] = []
    var upcomingQueueVersion = PlayerQueueVersion(revision: 0, index: 0, repeatMode: .off)
    var upcomingQueueEntries: [PlayerQueueEntry] = []
    var commands: [String] = []
    func togglePlayback() { isPlaying.toggle() }
    func seek(to value: Double) { progress = value }
    func next() { commands.append("next") }
    func previous() { commands.append("previous") }
    func skip(toQueueIndex index: Int) { currentQueueIndex = index }
    func playFromQueue(at index: Int) { currentQueueIndex = index; isPlaying = true }
    func enqueue(_ track: PlayerTrack, next: Bool) { commands.append("enqueue:\(track.id):\(next)") }
    func toggleShuffle() { isShuffled.toggle() }
    func cycleRepeatMode() { repeatMode = repeatMode == .off ? .all : .off }
    func toggleCrossfade() { isCrossfadeEnabled.toggle() }
    func toggleAutomaticContinuation() { isAutomaticContinuationEnabled.toggle() }
    func moveUpcomingQueueItems(fromOffsets source: IndexSet, toOffset destination: Int) {
        commands.append("move:\(source.first ?? -1):\(destination)")
    }
    func removeFromQueue(at index: Int) { commands.append("remove:\(index)") }
}

@MainActor @Observable private final class Revision { var value = 1 }
