import XCTest
import SwiftUI
@testable import NeoMusic
@testable import FullScreenPlayer

@MainActor
final class PlayerVisibilityTests: XCTestCase {
    func testPausingDuringQueueArtworkTransitionRendersIntermediateCoverSizes() async throws {
        let song = PlayerTrack(id: "push", title: "Push", artists: "Artist", albumTitle: "Album",
                               coverURL: URL(fileURLWithPath: "/cover.png"), duration: 180)
        let owner = PlayerTestFixtures.owner(tracks: [song])
        owner.isPlaying = true
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let services = PlayerServices(
            actions: PlayerTestFixtures.actions(), lyrics: .init(load: { _ in PlayerLyrics() }),
            artwork: .init(cached: { _ in cover }, load: { _ in cover })
        )
        let change = NowPlayingPageChange(source: .queue, destination: .artwork, stationaryArtworkPage: nil)
        let root = QueueLinkedArtwork(
            song: song, page: .artwork, pageChange: change, offset: QueueHeaderOffset(),
            artworkPageFrame: CGRect(x: 60, y: 60, width: 200, height: 200), isVisible: true,
            screenTop: -84,
            fade: nil, reducesMotion: false, artworkTransition: EmptyModifier()
        )
        .environment(PlayerState(model: owner))
        .environment(services)
        .environment(\.nowPlayingLayout, ReferenceNowPlayingLayout(contentSize: CGSize(width: 320, height: 420)))
        .background(.black)
        .ignoresSafeArea()
        let window = UIWindow(windowScene: try await applicationWindowScene())
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 420)
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(100))
        let playing = try renderedCoverWidth(in: window)
        XCTAssertEqual(playing, 200, accuracy: 2)

        owner.isPlaying = false
        var widths: [Int] = []
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(16))
            widths.append(try renderedCoverWidth(in: window))
        }
        let paused = 200 * NowPlayingArtworkPage.pausedArtworkScale
        XCTAssertEqual(CGFloat(try XCTUnwrap(widths.last)), paused, accuracy: 3)
        XCTAssertTrue(widths.contains { CGFloat($0) > paused + 5 && $0 < playing - 5 }, "Rendered widths: \(widths)")
    }

    private func renderedCoverWidth(in window: UIWindow) throws -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let screen = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        let image = try XCTUnwrap(screen.cgImage)
        let row = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 160, width: image.width, height: 1)))
        var bytes = [UInt8](repeating: 0, count: row.width * 4)
        let width = try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: row.width, height: 1,
                bitsPerComponent: 8, bytesPerRow: row.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(row, in: CGRect(x: 0, y: 0, width: row.width, height: 1))
            return (0..<row.width).count { pixel in
                let index = pixel * 4
                return buffer[index] > 200 && buffer[index + 1] < 40 && buffer[index + 2] > 200
            }
        }
        return width
    }

    func testQueueArtworkStartsAtTheVisibleCoverOrItsNearestEdge() {
        let header = QueueHeaderOffset()
        header.viewportHeight = 480
        let top = -NowPlayingSongHeader.lift
        let bottom = header.viewportHeight + top
        let side = NowPlayingSongHeader.referenceHeight
        let screenTop: CGFloat = -84
        let origins: [(CGFloat, CGFloat)] = [
            (0, top + 1), (-24, top - 23), (450, top + 451), (-900, screenTop - side), (1500, bottom)
        ]
        for (offset, expectedY) in origins {
            header.rawPoints = offset
            let frame = header.artworkFrame(screenTop: screenTop)
            XCTAssertEqual(frame.minY, expectedY)
            XCTAssertEqual(frame.width, side)
            XCTAssertEqual(frame.height, side)
        }
    }

    func testPopupArtworkTargetTracksQueueCoverVisibility() async throws {
        let songs = (0..<30).map { index in
            LibrarySongItem(id: "queue-cover-\(index)", title: "Song \(index)", artist: "Artist",
                            album: "Album", albumArtist: "Artist", trackNumber: index + 1, artwork: .missing, duration: 180)
        }
        let player = PlayerState(model: NowPlayingModel(queue: songs, currentIndex: 0, isPlaying: false, elapsed: 0))
        let services = NeoMusicPlayerServices.make(actions: PlayerTestFixtures.actions(), library: PlayerTestFixtures.library())
        let visible = expectation(description: "Visible queue cover supplies a popup target")
        let hidden = expectation(description: "Scrolled-out queue cover withdraws the popup target")
        let restored = expectation(description: "Returning the queue cover restores the popup target")
        var reportedVisibility: [Bool] = []
        let host = UIHostingController(rootView:
            FullScreenPlayerView(player: player, services: services, initialPage: .queue,
                                 artworkTransition: PopupArtworkVisibilityProbe { isVisible in
                guard reportedVisibility.last != isVisible,
                      isVisible || !reportedVisibility.isEmpty else { return }
                reportedVisibility.append(isVisible)
                switch reportedVisibility {
                case [true]: visible.fulfill()
                case [true, false]: hidden.fulfill()
                case [true, false, true]: restored.fulfill()
                default: break
                }
            })
            .environment(\.scenePhase, .active)
        )
        let window = UIWindow(windowScene: try await applicationWindowScene())
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await fulfillment(of: [visible], timeout: 2)

        let list = try XCTUnwrap(queueCollection(in: host.view))
        let rest = list.queueRestOffset
        list.setContentOffset(CGPoint(x: 0, y: rest + NowPlayingQueuePage.songHeaderHeight), animated: false)
        await fulfillment(of: [hidden], timeout: 2)
        list.setContentOffset(CGPoint(x: 0, y: rest), animated: false)
        await fulfillment(of: [restored], timeout: 2)
        XCTAssertEqual(reportedVisibility, [true, false, true])
    }

    private func queueCollection(in view: UIView) -> NowPlayingQueueList.EdgeFadedCollectionView? {
        if let list = view as? NowPlayingQueueList.EdgeFadedCollectionView { return list }
        return view.subviews.lazy.compactMap { self.queueCollection(in: $0) }.first
    }

    func testQueueAndArtworkUseTheSharedCoverInBothDirectionsEvenWhenOffscreen() {
        for (source, destination) in [(NowPlayingPage.artwork, NowPlayingPage.queue), (.queue, .artwork)] {
            for originalOffscreen in [true, false] {
                let endpoint = NowPlayingPageChange.resolveStationaryArtworkPage(
                    from: source, to: destination, queueArtworkOffscreen: originalOffscreen
                )
                XCTAssertNil(endpoint)
                XCTAssertTrue(NowPlayingPageChange(
                    source: source, destination: destination, stationaryArtworkPage: endpoint
                ).matchesQueueAndArtwork)
            }
        }
        XCTAssertEqual(NowPlayingPageChange.resolveStationaryArtworkPage(
            from: .queue, to: .lyrics, queueArtworkOffscreen: true
        ), .lyrics)
    }

    func testPortraitPlayerReferenceScreenshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let artwork = directory.appendingPathComponent("cover.png")
        let referenceImage = ProcessInfo.processInfo.environment["PLAYER_REFERENCE_ARTWORK"]
            .flatMap { UIImage(contentsOfFile: $0) }
        try XCTUnwrap((referenceImage ?? PlayerTestFixtures.artwork()).pngData()).write(to: artwork)
        let titles = ["不该 (feat. 张惠妹)", "Sky City -intro-", "introduction-Dawn to dusk",
                      "Flowers Blooming in a Grey City", "Rpg", "息吹-instrumental-"]
        let artists = ["周杰伦", "46", "P3T_SAYU", "乃花こより", "乃花こより", "Isekaijoucho"]
        let songs = titles.indices.map { index in
            LibrarySongItem(id: "netease:reference:\(index)", title: titles[index], artist: artists[index],
                           album: "周杰伦的床边故事", albumArtist: artists[index], trackNumber: index + 1,
                           artwork: .file(artwork), artworkURL: artwork, duration: 291)
        }
        let owner = NowPlayingModel(queue: songs, currentIndex: 0, isPlaying: false, elapsed: 39)
        owner.repeatMode = .off
        owner.sourceTitle = "喜爱歌曲"
        let player = PlayerState(model: owner)
        let library = PlayerTestFixtures.library()
        let lyrics = LyricsDocument.parse("[00:00.00]假装我们依然相爱\n[00:39.00]我真的演不出来\n[01:00.00]还是不习惯你不在\n[01:20.00]这身份转变太快\n[01:40.00]画面里不需要旁白")
        await library.reader.configureRemoteLyrics { _ in lyrics }
        let actions = PlayerActions(isFavorite: { _ in true }, toggleFavorite: { _ in },
            addToPlaylist: { _ in }, openAlbum: { _ in }, openArtist: { _ in },
            audioQuality: { _ in PlayerAudioQuality(title: "无损", isLossless: true) })
        for (page, name) in [(NowPlayingPage.artwork, "artwork"), (.lyrics, "lyrics"), (.queue, "queue")] {
            let content = ReferenceNowPlayingView(initialPage: page)
                .environment(player).environment(library).environment(actions)
                .dynamicTypeSize(.large)
                .environment(\.scenePhase, .active)
            let host = UIHostingController(rootView: content)
            host.overrideUserInterfaceStyle = .dark
            let window = UIWindow(windowScene: try await applicationWindowScene())
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            window.rootViewController = host
            window.isHidden = false
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .seconds(1))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "portrait-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    func testArtworkMeasurementNeedsNoPlayerAndMatchesPresentedCoverFrame() async throws {
        let layout = ReferenceNowPlayingLayout(contentSize: CGSize(width: 402, height: 778))
        let measured = expectation(description: "Cover frame is available on the initial layout")
        var receivedFrame: CGRect?
        let view = NowPlayingArtworkFrameMeasurement { frame in
            guard frame.width > 0, receivedFrame == nil else { return }
            receivedFrame = frame
            measured.fulfill()
        }
        .frame(width: 338, height: 650)
        .coordinateSpace(name: NowPlayingPortraitCoordinateSpace.name)
        .environment(\.nowPlayingLayout, layout)
        let host = UIHostingController(rootView: view)
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await fulfillment(of: [measured], timeout: 2)

        XCTAssertEqual(receivedFrame?.width ?? 0, 338, accuracy: 0.5)
        XCTAssertEqual(receivedFrame?.height ?? 0, 338, accuracy: 0.5)
        XCTAssertEqual(receivedFrame?.midX ?? 0, 169, accuracy: 0.5)
        XCTAssertEqual(receivedFrame?.minY ?? 0, 11, accuracy: 0.5)
    }
}

private struct PopupArtworkVisibilityProbe: ViewModifier {
    @Environment(\.playerArtworkTransitionTargetVisible) private var isVisible
    let onVisibilityChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: isVisible, initial: true) { _, isVisible in onVisibilityChange(isVisible) }
    }
}
