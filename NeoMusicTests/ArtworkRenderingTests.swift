import XCTest
import SwiftUI
import Nuke
@testable import NeoMusic

@MainActor
final class ArtworkRenderingTests: XCTestCase {
    func testPlayerCoverSurvivesSameSongRefreshAndNeverLeaksToAnotherSong() async throws {
        let firstURL = fileURL(), secondURL = fileURL()
        try XCTUnwrap(solid(.red).pngData()).write(to: firstURL)
        try XCTUnwrap(solid(.blue).pngData()).write(to: secondURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let size = CGSize(width: 96, height: 96)
        let requests = [firstURL, secondURL].compactMap {
            ArtworkImagePipeline.request(for: $0, size: size, displayScale: 1)
        }
        await ArtworkImagePipeline.prefetch(requests)
        let state = ArtworkRenderingState(.deferred(id: "first-arrival", placeholder: .missing), contentID: "song-1")
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: PlayerArtworkRenderingPage(state: state))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let host = ArtworkRenderingHost(window: window, controller: controller)
        let empty = await frames(host, count: 2)
        state.artwork = .file(firstURL)
        let initial = await frames(host, count: 3)
        let first = try XCTUnwrap(initial.last)
        XCTAssertNotEqual(first.pixels, empty.last?.pixels)
        state.artwork = .deferred(id: "replacement", placeholder: .missing)
        let pending = await frames(host, count: 4)
        state.artwork = .file(fileURL())
        let failed = await frames(host, count: 4)
        for frame in pending + failed { XCTAssertEqual(frame.pixels, first.pixels) }
        state.contentID = "song-2"
        state.artwork = .file(secondURL)
        let updated = await frames(host, count: 4)
        XCTAssertNotEqual(updated.last?.pixels, first.pixels)
        state.artwork = .deferred(id: "second-refresh", placeholder: .missing)
        let secondPending = await frames(host, count: 3)
        for frame in secondPending { XCTAssertEqual(frame.pixels, updated.last?.pixels) }
        state.contentID = "song-1"
        state.artwork = .deferred(id: "first-refresh", placeholder: .missing)
        let returned = await frames(host, count: 3)
        for frame in returned { XCTAssertNotEqual(frame.pixels, updated.last?.pixels, "The second song's image must not be attributed to the first") }
        state.artwork = .file(firstURL)
        let reloaded = await frames(host, count: 3)
        XCTAssertEqual(reloaded.last?.pixels, first.pixels)
        state.artwork = .missing
        let invalidated = await frames(host, count: 3)
        XCTAssertNotEqual(invalidated.last?.pixels, first.pixels, "Signing out clears even the same song's retained image")
        attach(empty + initial + pending + failed + updated + secondPending + returned + reloaded + invalidated,
               name: "Player cover metadata refresh")
    }

    func testMetadataRefreshKeepsAvailableCoverAndNewLoadIdentity() throws {
        let url = fileURL()
        try XCTUnwrap(solid(.red).pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let old = LibrarySongItem(id: "netease:42:1", title: "Song", artist: "Artist", album: "Album",
                                 albumArtist: "Artist", trackNumber: 1, artwork: .file(url), artworkURL: url)
        var updated = old
        updated.artworkURL = nil
        updated.artwork = .deferred(id: "new-remote", placeholder: .missing)
        updated.isFavorite = true
        let merged = updated.retainingArtwork(from: old)
        XCTAssertEqual(merged.artworkURL, url)
        XCTAssertEqual(merged.artwork.loadID, "new-remote")
        XCTAssertTrue(merged.isFavorite)
        updated.unavailabilityReason = "Signed out"
        XCTAssertNil(updated.retainingArtwork(from: old).artworkURL)
        XCTAssertNil(LibrarySongItem.unavailable("netease:99:1").retainingArtwork(from: old).artworkURL)
        try FileManager.default.removeItem(at: url)
        updated.unavailabilityReason = nil
        XCTAssertNil(updated.retainingArtwork(from: old).artworkURL)
    }

    func testCachedThumbnailSurvivesSourceChangeWhileLargerDecodeIsPending() async throws {
        let url = fileURL()
        try XCTUnwrap(solid(.red).pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await LocalArtworkImages.load(url, pixels: 64)
        let decoder = ControlledArtworkDecoder()
        let state = ArtworkRenderingState(.file(url), contentID: "album-1")
        let host = try await makeHost(state: state, decoder: decoder, native: true)
        defer { host.window.isHidden = true; decoder.finishAll() }
        let initial = await frames(host, count: 3)
        let source = try XCTUnwrap(initial.last)
        XCTAssertTrue(decoder.hasPending(url))
        let replacement = fileURL()
        state.artwork = .file(replacement)
        let pending = await frames(host, count: 4)
        for frame in pending { XCTAssertEqual(frame.pixels, source.pixels, "A visible cached thumbnail must remain during the next decode") }
        decoder.finish(replacement, with: solid(.blue))
        let completed = await frames(host, count: 4)
        XCTAssertNotEqual(completed.last?.pixels, source.pixels)
        attach(initial + pending + completed, name: "Cached cover during file update")
    }

    func testLibraryNavigationRetainsDisplayedAlbumAndPlaylistCoverOnDetailFailure() async throws {
        let url = fileURL()
        try XCTUnwrap(solid(.red).pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await LocalArtworkImages.load(url, pixels: 128)
        for route in [LibraryRoute.album("catalog:album:1"), .playlist("playlist-1")] {
            var preview: LibraryNavigationPreview?
            let action = OpenLibraryRouteAction(handler: { _ in XCTFail("Expected cover preview") },
                previewSourceHandler: { _, value, _ in preview = value })
            action(LibraryShelfItem(id: "item-1", title: "Album", artwork: .file(url), route: route,
                                    sourceOwnerID: "1"), sourceProvider: { nil })
            let captured = try XCTUnwrap(preview)
            XCTAssertEqual(captured.ownerID, "1")
            XCTAssertEqual(captured.route, route)
            guard case .image = captured.artwork else { return XCTFail("Navigation must retain decoded pixels") }
            let targetURL = fileURL()
            let decoder = ControlledArtworkDecoder()
            let state = ArtworkRenderingState(captured.artwork, contentID: captured.contentID)
            state.previewArtwork = captured.artwork
            let host = try await makeHost(state: state, decoder: decoder, native: true)
            defer { host.window.isHidden = true; decoder.finishAll() }
            let initial = await frames(host, count: 3)
            let source = try XCTUnwrap(initial.last)
            state.artwork = .file(targetURL)
            let pending = await frames(host, count: 4)
            decoder.finish(targetURL, with: nil)
            let failed = await frames(host, count: 4)
            for frame in pending + failed { XCTAssertEqual(frame.pixels, source.pixels) }
            attach(initial + pending + failed, name: "Library \(route) detail cover")
        }
    }

    func testPlayerBackdropSurvivesSameSongMetadataRefreshAndClearsForMissingNextSong() async throws {
        let url = URL(fileURLWithPath: "/tmp/backdrop-refresh-test.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        NowPlayingBackdropRenderer.shared.cache.setObject(
            .init(.init(dimmed: image, undimmed: image)), forKey: url as NSURL)
        defer { NowPlayingBackdropRenderer.shared.cache.removeObject(forKey: url as NSURL) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        var displayed: UIImage?
        let host = UIHostingController(rootView: NowPlayingArtworkBackdrop(
            artworkURL: url, trackID: "song-a", onImageChange: { displayed = $0 }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(displayed)
        host.rootView = NowPlayingArtworkBackdrop(
            artworkURL: nil, trackID: "song-a", onImageChange: { displayed = $0 })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(displayed)
        host.rootView = NowPlayingArtworkBackdrop(
            artworkURL: nil, trackID: "song-b", onImageChange: { displayed = $0 })
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(displayed)
    }

    func testDeferredFileKeepsPlaceholderUntilDecodedInBothHosts() async throws {
        for native in [false, true] {
            let decoder = ControlledArtworkDecoder()
            let state = ArtworkRenderingState(.deferred(id: "playlist-cover", placeholder: .playlist))
            let host = try await makeHost(state: state, decoder: decoder, native: native)
            defer { host.window.isHidden = true; decoder.finishAll() }
            let initial = await frames(host, count: 3)
            let placeholder = try XCTUnwrap(initial.last)
            let surface = nativeSurface(host.controller.view)
            XCTAssertEqual(surface != nil, native)

            let url = fileURL()
            state.artwork = .file(url)
            let pending = await frames(host, count: 5)
            XCTAssertTrue(decoder.hasPending(url))
            for frame in pending { XCTAssertEqual(frame.pixels, placeholder.pixels, "File readiness must not erase the placeholder") }
            decoder.finish(url, with: solid(.red))
            let transition = await frames(host, count: 6)
            let completed = transition + (await settledFrames(host, count: 2))
            let cover = try XCTUnwrap(completed.last)
            XCTAssertNotEqual(cover.pixels, placeholder.pixels)
            assertFade(completed, from: placeholder, to: cover)
            if native { XCTAssertTrue(surface === nativeSurface(host.controller.view), "Keep the native zoom source") }
            attach(initial + pending + completed, name: native ? "Native placeholder to cover" : "Placeholder to cover")
        }
    }

    func testStableContentKeepsOldCoverThroughDeferredAndNewFile() async throws {
        let firstURL = fileURL()
        let decoder = ControlledArtworkDecoder()
        let state = ArtworkRenderingState(.file(firstURL), contentID: "account-1:playlist-2")
        let host = try await makeHost(state: state, decoder: decoder, native: true)
        defer { host.window.isHidden = true; decoder.finishAll() }
        _ = await frames(host, count: 3)
        XCTAssertTrue(decoder.hasPending(firstURL))
        decoder.finish(firstURL, with: solid(.red))
        let loaded = await settledFrames(host, count: 3)
        let old = try XCTUnwrap(loaded.last)

        state.artwork = .deferred(id: "updated-cover", placeholder: .playlist)
        let deferred = await frames(host, count: 3)
        let secondURL = fileURL()
        state.artwork = .file(secondURL)
        let pending = await frames(host, count: 4)
        for frame in deferred + pending { XCTAssertEqual(frame.pixels, old.pixels) }
        decoder.finish(secondURL, with: solid(.blue))
        let completed = await frames(host, count: 5)
        let new = try XCTUnwrap(completed.last)
        XCTAssertNotEqual(new.pixels, old.pixels)
        assertSingleReplacement(completed, from: old, to: new)
        attach([old] + deferred + pending + completed, name: "Same playlist retains its cover")

        state.artwork = .missing
        let cleared = await frames(host, count: 3)
        XCTAssertNotEqual(cleared.last?.pixels, new.pixels, "An explicit missing artwork clears the retained cover")
    }

    func testChangedIdentityAndUnidentifiedFileNeverKeepAnotherCover() async throws {
        for initialIdentity in [nil, "account-1:playlist-2"] as [String?] {
            let firstURL = fileURL()
            let decoder = ControlledArtworkDecoder()
            let state = ArtworkRenderingState(.file(firstURL), contentID: initialIdentity)
            let host = try await makeHost(state: state, decoder: decoder, native: false)
            defer { host.window.isHidden = true; decoder.finishAll() }
            let initial = await frames(host, count: 3)
            let placeholder = try XCTUnwrap(initial.last)
            decoder.finish(firstURL, with: solid(.red))
            let loaded = await settledFrames(host, count: 3)
            let old = try XCTUnwrap(loaded.last)
            XCTAssertNotEqual(old.pixels, placeholder.pixels)

            let supersededURL = fileURL()
            state.artwork = .file(supersededURL)
            _ = await frames(host, count: 3)
            XCTAssertTrue(decoder.hasPending(supersededURL))
            if initialIdentity != nil { state.contentID = "account-3:playlist-2" }
            let nextURL = fileURL()
            state.artwork = .file(nextURL)
            let pending = await frames(host, count: 4)
            XCTAssertTrue(decoder.hasPending(nextURL))
            for frame in pending { XCTAssertEqual(frame.pixels, placeholder.pixels, "A different item must not display the previous item's image") }
            decoder.finish(supersededURL, with: solid(.green))
            let lateCompletion = await frames(host, count: 3)
            for frame in lateCompletion { XCTAssertEqual(frame.pixels, placeholder.pixels, "A cancelled previous item must not publish its late image") }
            decoder.finish(nextURL, with: nil)
            let failed = await frames(host, count: 3)
            for frame in failed { XCTAssertEqual(frame.pixels, placeholder.pixels, "Decode failure keeps the placeholder") }
            attach([old] + pending + lateCompletion + failed, name: initialIdentity == nil ? "Unidentified file replacement" : "Account identity replacement")
        }
    }

    func testSameURLKeepsDecodedImageWhilePreparingLargerSize() async throws {
        let url = fileURL()
        let decoder = ControlledArtworkDecoder()
        let state = ArtworkRenderingState(.file(url))
        let host = try await makeHost(state: state, decoder: decoder, native: false)
        defer { host.window.isHidden = true; decoder.finishAll() }
        _ = await frames(host, count: 3)
        decoder.finish(url, with: solid(.red))
        let loaded = await settledFrames(host, count: 3)
        let small = try XCTUnwrap(loaded.last)
        state.side = 160
        let larger = await frames(host, count: 4)
        XCTAssertTrue(decoder.hasPending(url))
        for frame in larger { XCTAssertEqual(frame.pixels, small.pixels) }
        decoder.finish(url, with: solid(.red))
        let completed = await frames(host, count: 3)
        for frame in completed { XCTAssertEqual(frame.pixels, small.pixels) }
        attach([small] + larger + completed, name: "Same URL larger thumbnail")
    }

    func testNavigationPreviewSurvivesDetailDecodeFailureAndClearsWithIdentity() async throws {
        let url = fileURL()
        let decoder = ControlledArtworkDecoder()
        let state = ArtworkRenderingState(.file(url), contentID: "account-1:playlist-2")
        state.previewArtwork = .image(Image(uiImage: solid(.red)))
        let host = try await makeHost(state: state, decoder: decoder, native: true)
        defer { host.window.isHidden = true; decoder.finishAll() }
        let initial = await frames(host, count: 4)
        let preview = try XCTUnwrap(initial.last)
        XCTAssertTrue(decoder.hasPending(url))
        decoder.finish(url, with: nil)
        let failed = await frames(host, count: 4)
        for frame in failed { XCTAssertEqual(frame.pixels, preview.pixels) }
        let replacementURL = fileURL()
        state.artwork = .file(replacementURL)
        let pending = await frames(host, count: 3)
        for frame in pending { XCTAssertEqual(frame.pixels, preview.pixels) }
        decoder.finish(replacementURL, with: solid(.blue))
        let completed = await frames(host, count: 4)
        let replacement = try XCTUnwrap(completed.last)
        XCTAssertNotEqual(replacement.pixels, preview.pixels)
        state.contentID = "account-3:playlist-2"
        state.previewArtwork = nil
        state.artwork = .deferred(id: "other-account", placeholder: .playlist)
        let cleared = await frames(host, count: 3)
        XCTAssertNotEqual(cleared.last?.pixels, preview.pixels)
        XCTAssertNotEqual(cleared.last?.pixels, replacement.pixels)
        attach(initial + failed + pending + completed + cleared, name: "Navigation cover continuity")
    }

    private func makeHost(state: ArtworkRenderingState, decoder: ControlledArtworkDecoder,
                          native: Bool) async throws -> ArtworkRenderingHost {
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: ArtworkRenderingPage(state: state, decoder: decoder, native: native))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return ArtworkRenderingHost(window: window, controller: controller)
    }

    /// Each sample is drawn after a display-link boundary from the same live hierarchy.
    private func frames(_ host: ArtworkRenderingHost, count: Int) async -> [ArtworkRenderedFrame] {
        var result: [ArtworkRenderedFrame] = []
        for _ in 0..<count {
            await ArtworkDisplayFrame.next()
            let view = host.controller.view!
            view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            format.preferredRange = .standard
            let size = CGSize(width: 80, height: 80)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                context.cgContext.translateBy(x: 40 - view.bounds.midX, y: 40 - view.bounds.midY)
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            result.append(ArtworkRenderedFrame(image: image))
        }
        return result
    }

    private func settledFrames(_ host: ArtworkRenderingHost, count: Int) async -> [ArtworkRenderedFrame] {
        try? await Task.sleep(for: .milliseconds(250))
        return await frames(host, count: count)
    }

    private func assertFade(_ frames: [ArtworkRenderedFrame], from old: ArtworkRenderedFrame,
                            to new: ArtworkRenderedFrame, file: StaticString = #filePath, line: UInt = #line) {
        func distance(_ pixels: Data) -> Double {
            zip(pixels, new.pixels).reduce(0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pixels.count)
        }
        var previous = distance(old.pixels)
        XCTAssertTrue(frames.contains { $0.pixels != old.pixels && $0.pixels != new.pixels },
                      "The placeholder must fade through intermediate pixels", file: file, line: line)
        for frame in frames {
            let remaining = distance(frame.pixels)
            XCTAssertLessThanOrEqual(remaining, previous + 1, "The fade must advance toward the decoded cover", file: file, line: line)
            previous = remaining
        }
        XCTAssertEqual(frames.last?.pixels, new.pixels, file: file, line: line)
    }

    private func assertSingleReplacement(_ frames: [ArtworkRenderedFrame], from old: ArtworkRenderedFrame,
                                         to new: ArtworkRenderedFrame, file: StaticString = #filePath, line: UInt = #line) {
        var replaced = false
        for frame in frames {
            if frame.pixels == new.pixels { replaced = true }
            else {
                XCTAssertFalse(replaced, "The old artwork must not return after the replacement", file: file, line: line)
                XCTAssertEqual(frame.pixels, old.pixels, "A rendered frame must show the placeholder/old cover or the decoded image", file: file, line: line)
            }
        }
        XCTAssertTrue(replaced, file: file, line: line)
    }

    private func attach(_ frames: [ArtworkRenderedFrame], name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(frames.count * 80), height: 80), format: format).image { _ in
            for (index, frame) in frames.enumerated() { frame.image.draw(at: CGPoint(x: CGFloat(index * 80), y: 0)) }
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func nativeSurface(_ view: UIView) -> LibraryArtworkSurfaceView? {
        (view as? LibraryArtworkSurfaceView) ?? view.subviews.lazy.compactMap(nativeSurface).first
    }

    private func fileURL() -> URL { URL(fileURLWithPath: "/tmp/\(UUID().uuidString).png") }
    private func solid(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }
}

@MainActor @Observable private final class ArtworkRenderingState {
    var artwork: Artwork
    var contentID: String?
    var previewArtwork: Artwork?
    var side: CGFloat = 96
    init(_ artwork: Artwork, contentID: String? = nil) { self.artwork = artwork; self.contentID = contentID }
}

private struct ArtworkRenderingPage: View {
    let state: ArtworkRenderingState
    let decoder: ControlledArtworkDecoder
    let native: Bool
    var body: some View {
        ArtworkView(artwork: state.artwork, contentID: state.contentID, previewArtwork: state.previewArtwork,
                    cornerRadius: 0, loadImage: decoder.load)
            .frame(width: state.side, height: state.side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .environment(\.nativeArtworkSurfaceEnabled, native)
            .environment(\.displayScale, 1)
            .environment(\.colorScheme, .light)
            .ignoresSafeArea()
    }
}

@MainActor private final class ControlledArtworkDecoder {
    private var pending: [URL: [CheckedContinuation<UIImage?, Never>]] = [:]
    func load(_ url: URL, _ pixels: Int) async -> UIImage? {
        await withCheckedContinuation { pending[url, default: []].append($0) }
    }
    func hasPending(_ url: URL) -> Bool { pending[url]?.isEmpty == false }
    func finish(_ url: URL, with image: UIImage?) {
        let completions = pending.removeValue(forKey: url) ?? []
        for completion in completions { completion.resume(returning: image) }
    }
    func finishAll() { for url in Array(pending.keys) { finish(url, with: nil) } }
}

@MainActor private struct ArtworkRenderingHost {
    let window: UIWindow
    let controller: UIViewController
}

private struct PlayerArtworkRenderingPage: View {
    let state: ArtworkRenderingState
    private var url: URL? { if case .file(let url) = state.artwork { url } else { nil } }
    var body: some View {
        ArtworkImage(url: url, contentID: state.contentID, artworkLoadID: state.artwork.loadID, cornerRadius: 0)
            .frame(width: 96, height: 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white)
            .environment(\.displayScale, 1)
            .environment(\.colorScheme, .light)
            .ignoresSafeArea()
    }
}

private struct ArtworkRenderedFrame {
    let image: UIImage
    let pixels: Data
    init(image: UIImage) {
        self.image = image
        if let data = image.cgImage?.dataProvider?.data { pixels = data as Data }
        else { pixels = Data() }
    }
}

@MainActor private final class ArtworkDisplayFrame: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    private var link: CADisplayLink?
    static func next() async {
        let frame = ArtworkDisplayFrame()
        await withCheckedContinuation { continuation in
            frame.continuation = continuation
            frame.link = CADisplayLink(target: frame, selector: #selector(tick))
            frame.link?.add(to: .main, forMode: .common)
        }
    }
    @objc private func tick() {
        link?.invalidate()
        link = nil
        continuation?.resume()
        continuation = nil
    }
}
