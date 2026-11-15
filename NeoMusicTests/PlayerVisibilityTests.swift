import XCTest
import SwiftUI
@testable import NeoMusic
@testable import FullScreenPlayer

@MainActor
final class PlayerVisibilityTests: XCTestCase {
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
