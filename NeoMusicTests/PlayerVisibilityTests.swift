import XCTest
import SwiftUI
import Metal
@testable import NeoMusic

@MainActor
final class PlayerVisibilityTests: XCTestCase {
    func testCompiledEDRResourcesAndVisibilityPauseDisplayLink() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal is unavailable on this destination") }
        await PlayerEDRResources.shared.prepare()
        XCTAssertTrue(PlayerEDRResources.shared.isReady, "The app must contain the compiled EDR shader library")

        let controller = UIViewController()
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let glyph = PlayerEDRGlyphView(frame: CGRect(x: 20, y: 20, width: 200, height: 30))
        controller.view.addSubview(glyph)

        XCTAssertFalse(glyph.hasActiveDisplayLink)
        glyph.setRenderingActive(true)
        XCTAssertTrue(glyph.hasActiveDisplayLink)
        glyph.setRenderingActive(false)
        XCTAssertFalse(glyph.hasActiveDisplayLink)
        glyph.setRenderingActive(true)
        XCTAssertTrue(glyph.hasActiveDisplayLink)
        glyph.update(text: "Queue title", fontSize: 17, image: nil, anchor: nil,
                     brightness: 0.7, isWhite: true, fontWeight: .regular)
        XCTAssertFalse(glyph.hasActiveDisplayLink, "Position-independent title pixels need no continuous draw loop")
        glyph.layoutIfNeeded()
        XCTAssertFalse(glyph.layer.needsLayout())
        glyph.update(text: "Queue title", fontSize: 17, image: nil, anchor: nil,
                     brightness: 0.7, isWhite: true, fontWeight: .regular)
        XCTAssertFalse(glyph.layer.needsLayout(), "Unchanged hosting content must not request another Metal layout")
        glyph.frame.origin.y += 100
        glyph.setRenderingActive(false)
        glyph.setRenderingActive(true)
        XCTAssertFalse(glyph.hasActiveDisplayLink)
        glyph.update(text: "Queue artist", fontSize: 13, image: nil, anchor: nil,
                     brightness: 0.35, isWhite: false, fontWeight: .regular)
        XCTAssertTrue(glyph.hasActiveDisplayLink, "Backdrop-dependent artist glyphs still follow scrolling")
        glyph.removeFromSuperview()
        XCTAssertFalse(glyph.hasActiveDisplayLink)
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

        XCTAssertEqual(receivedFrame?.width ?? 0, 354, accuracy: 0.5)
        XCTAssertEqual(receivedFrame?.height ?? 0, 354, accuracy: 0.5)
        XCTAssertEqual(receivedFrame?.midX ?? 0, 169, accuracy: 0.5)
        XCTAssertEqual(receivedFrame?.minY ?? 0, 28, accuracy: 0.5)
    }
}
