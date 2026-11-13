import XCTest
import UIKit
import SwiftUI
@testable import NeoMusic

@MainActor final class HomePlaylistArtworkTests: XCTestCase {
    func testPlaylistCoverUsesOriginalFirstTrackAndPreservesCreatorsCover() {
        let cover = URL(string: "https://example.com/custom.jpg")!
        let first = URL(string: "https://example.com/first.jpg")!
        let second = URL(string: "https://example.com/second.jpg")!
        let playlist = NeteaseMusicPlaylist(id: 12, title: "List", creator: "Owner", creatorID: 42,
            artworkURL: cover, trackCount: 2, isFavorites: false)
        let a = NeteaseMusicSong(id: 1, title: "A", artist: "Artist", album: "Album", artworkURL: first, duration: 10)
        let b = NeteaseMusicSong(id: 2, title: "B", artist: "Artist", album: "Album", artworkURL: second, duration: 10)
        var detail = NeteasePlaylistDetail(playlist: playlist, songs: [b, a], addedTimes: [:], trackIDs: [1, 2])
        XCTAssertEqual(detail.displayArtworkURL(ownerID: 7), first)
        XCTAssertEqual(detail.displayArtworkURL(ownerID: nil), first)
        XCTAssertEqual(detail.displayArtworkURL(ownerID: 42), cover)
        detail.trackIDs = [2, 1]
        XCTAssertEqual(detail.displayArtworkURL(ownerID: 7), second)
        detail.trackIDs = [3, 2]
        XCTAssertNil(detail.displayArtworkURL(ownerID: 7))
        detail.trackIDs = []
        XCTAssertNil(detail.displayArtworkURL(ownerID: 7))
        XCTAssertEqual(detail.displayArtworkURL(ownerID: 42), cover)
    }

    func testQuickActionVisibilityTracksMissingWaitingFailedAndImmediateArtwork() async throws {
        let probe = HomeArtworkVisibilityProbe(artwork: nil)
        let window = try await makeVisibilityHost(probe)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForVisibility(false, probe: probe)

        probe.artwork = .image(Image(uiImage: solidCover()))
        try await waitForVisibility(true, probe: probe)
        probe.artwork = .deferred(id: "home-visibility:waiting", placeholder: .playlist)
        try await waitForVisibility(false, probe: probe)
        probe.artwork = .image(Image(uiImage: solidCover()))
        try await waitForVisibility(true, probe: probe)
        probe.artwork = .file(URL.temporaryDirectory.appending(path: "\(UUID().uuidString).png"))
        try await waitForVisibility(false, probe: probe)
        probe.artwork = .image(Image(uiImage: solidCover()))
        try await waitForVisibility(true, probe: probe)
        probe.artwork = nil
        try await waitForVisibility(false, probe: probe)
    }

    func testRenderedQuickActionCoverRemainsVisibleWhenReplacementReadFails() async throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        try XCTUnwrap(solidCover().pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let probe = HomeArtworkVisibilityProbe(artwork: .file(url))
        let window = try await makeVisibilityHost(probe)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitForVisibility(true, probe: probe)
        XCTAssertEqual(probe.values, [false, true], "A file becomes visible after its pixels are rendered")

        probe.artwork = .file(URL.temporaryDirectory.appending(path: "\(UUID().uuidString).png"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(probe.values, [false, true], "The existing rendered cover remains visible after a failed replacement")
        probe.artwork = nil
        try await waitForVisibility(false, probe: probe)
    }

    func testBlurPreservesOpaqueWhiteAtBottomAndSideEdges() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cover = UIGraphicsImageRenderer(size: CGSize(width: 248, height: 248), format: format).image { renderer in
            UIColor.white.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 248, height: 248))
        }
        let result = await HomePlaylistArtworkRenderer().render(cover, key: "white", scale: 1)
        let images = try XCTUnwrap(result)
        let image = try XCTUnwrap(images.background.cgImage)
        var pixels = [UInt8](repeating: 0, count: 248 * 330 * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 248, height: 330, bitsPerComponent: 8,
                                             bytesPerRow: 248 * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 248, height: 330))
        for (x, y) in [(0, 0), (124, 0), (247, 0), (0, 329), (124, 329), (247, 329), (124, 165)] {
            let offset = (y * 248 + x) * 4
            for channel in 0..<4 { XCTAssertGreaterThanOrEqual(pixels[offset + channel], 253, "Edge pixel \(x),\(y)") }
        }
    }

    private func makeVisibilityHost(_ probe: HomeArtworkVisibilityProbe) async throws -> UIWindow {
        let window = UIWindow(windowScene: try await applicationWindowScene())
        let controller = UIHostingController(rootView: HomeArtworkVisibilityProbeView(probe: probe))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return window
    }

    private func waitForVisibility(_ expected: Bool, probe: HomeArtworkVisibilityProbe,
                                   file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if probe.values.last == expected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected visible artwork: \(expected); received \(probe.values)", file: file, line: line)
    }

    private func solidCover() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { renderer in
            UIColor.systemBlue.setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }
}

@MainActor @Observable private final class HomeArtworkVisibilityProbe {
    var artwork: Artwork?
    var values: [Bool] = []
    init(artwork: Artwork?) { self.artwork = artwork }
}

private struct HomeArtworkVisibilityProbeView: View {
    let probe: HomeArtworkVisibilityProbe
    var body: some View {
        HomeQuickActionArtwork(item: .init(action: .dailySongs, artwork: probe.artwork, subtitle: ""),
                               onVisibleArtworkChange: { probe.values.append($0) })
            .frame(width: HomeMetrics.heroWidth, height: HomeMetrics.heroHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.artworkLoadAction, ArtworkLoadAction())
    }
}
