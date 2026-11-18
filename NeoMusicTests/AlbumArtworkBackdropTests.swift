import SwiftUI
import XCTest
import MetalKit
import Synchronization
@testable import NeoMusic
@testable import FullScreenPlayer

private struct BackdropAlbumPage: Codable, Sendable {
    let detail: NeteaseArtistAlbumDetail
    let refreshedAt: Date?
}

private struct BackdropSubscriptions: Encodable, Sendable {
    let artists: [NeteaseArtistReference] = []
    let albums: [NeteaseArtistAlbum] = []
    let refreshedAt: [String: Date] = [:]
}

private final class BackdropArtworkProtocol: URLProtocol, @unchecked Sendable {
    struct State { var image = Data(); var requests: [URL] = [] }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let data = Self.state.withLock { state in state.requests.append(url); return state.image }
        guard url.pathExtension == "png" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AlbumArtworkBackdropTests: XCTestCase {
    private func imageData(_ color: UIColor) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return image.pngData()!
    }

    func testPlaylistPreviewUsesPreparedCoverColorBeforeNavigation() async throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try imageData(.blue).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let id = "playlist-preview:" + UUID().uuidString
        LocalArtworkImages.registerResolvedArtwork(id, url: file)
        _ = await LocalArtworkImages.load(file, pixels: 128)
        let cover = Artwork.deferred(id: id, placeholder: .playlist)
        let preview = LibraryNavigationPreview(route: .playlist("test"), ownerID: nil, title: "Test", artwork: cover)
        XCTAssertNotNil(preview.albumBackdrop)
        XCTAssertEqual(preview.albumBackdrop, LocalArtworkImages.cachedBackdrop(for: .file(file)))
    }

    func testPublicExtractionProvidesBackgroundAndMatchingForeground() throws {
        let dark = try XCTUnwrap(AlbumArtworkBackdrop.extract(from: imageData(.black)))
        let light = try XCTUnwrap(AlbumArtworkBackdrop.extract(from: imageData(.white)))
        XCTAssertEqual(dark.red, 0, accuracy: 0.01)
        XCTAssertEqual(dark.green, 0, accuracy: 0.01)
        XCTAssertEqual(dark.blue, 0, accuracy: 0.01)
        XCTAssertEqual(dark.colorScheme, .dark)
        XCTAssertEqual(light.red, 1, accuracy: 0.01)
        XCTAssertEqual(light.green, 1, accuracy: 0.01)
        XCTAssertEqual(light.blue, 1, accuracy: 0.01)
        XCTAssertEqual(light.colorScheme, .light)
        XCTAssertNil(AlbumArtworkBackdrop.extract(from: Data("invalid".utf8)))
    }

    func testPublicExtractionChoosesDominantColorOverMinorityAccent() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 80, y: 0, width: 20, height: 100))
        }
        let backdrop = try XCTUnwrap(AlbumArtworkBackdrop.extract(from: XCTUnwrap(image.pngData())))
        XCTAssertEqual(backdrop.red, 1, accuracy: 0.02)
        XCTAssertEqual(backdrop.green, 0, accuracy: 0.02)
        XCTAssertEqual(backdrop.blue, 0, accuracy: 0.02)
    }

    func testMidGrayUsesReadableDarkForeground() throws {
        let backdrop = AlbumArtworkBackdrop(red: 0.60, green: 0.60, blue: 0.60)
        XCTAssertEqual(backdrop.colorScheme, .light)
        let luminance = pow((0.60 + 0.055) / 1.055, 2.4)
        XCTAssertGreaterThanOrEqual((luminance + 0.05) / 0.05, 4.5)
        XCTAssertLessThan(1.05 / (luminance + 0.05), 4.5)

        let restored = try JSONDecoder().decode(AlbumArtworkBackdrop.self,
            from: Data(#"{"red":0.6,"green":0.6,"blue":0.6}"#.utf8))
        XCTAssertEqual(restored, backdrop)
        XCTAssertEqual(restored.colorScheme, .light)
    }

    func testForegroundContrastAcrossBoundaryAndSaturatedColors() {
        let samples: [(AlbumArtworkBackdrop, ColorScheme)] = [
            (.init(red: 0, green: 0, blue: 0), .dark),
            (.init(red: 1, green: 1, blue: 1), .light),
            (.init(red: 0.45, green: 0.45, blue: 0.45), .dark),
            (.init(red: 0.56, green: 0.56, blue: 0.56), .dark),
            (.init(red: 0.57, green: 0.57, blue: 0.57), .light),
            (.init(red: 1, green: 0, blue: 0), .dark),
            (.init(red: 0, green: 1, blue: 0), .light),
            (.init(red: 0, green: 0, blue: 1), .dark),
        ]
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        for (sample, expected) in samples {
            XCTAssertEqual(sample.colorScheme, expected)
            let luminance = 0.2126 * linear(sample.red) + 0.7152 * linear(sample.green) + 0.0722 * linear(sample.blue)
            let contrast = sample.colorScheme == .dark ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
            XCTAssertGreaterThanOrEqual(contrast, 3.2)
        }
    }

    func testSelectedAlbumRowsUseToneContrastingOverlayAtGrayBoundary() async throws {
        func luminance(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let scene = try await applicationWindowScene()
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        for gray in [0.46, 0.57, 0.60] {
            let backdrop = AlbumArtworkBackdrop(red: gray, green: gray, blue: gray)
            let whiteForeground = backdrop.colorScheme == .dark
            let style: UIUserInterfaceStyle = whiteForeground ? .dark : .light
            controller.traitOverrides.userInterfaceStyle = style
            controller.updateTraitsIfNeeded()
            let cell = AlbumSelectionCell(frame: CGRect(x: 0, y: 0, width: 330, height: 60))
            controller.view.addSubview(cell)
            defer { cell.removeFromSuperview() }
            controller.view.updateTraitsIfNeeded()
            cell.updateTraitsIfNeeded()
            controller.view.layoutIfNeeded()
            XCTAssertTrue(cell.window === window)
            XCTAssertEqual(controller.traitCollection.userInterfaceStyle, style)
            XCTAssertEqual(cell.traitCollection.userInterfaceStyle, style)
            cell.isSelected = true
            cell.updateConfiguration(using: cell.configurationState)

            let overlay = try XCTUnwrap(cell.backgroundConfiguration?.backgroundColor)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            XCTAssertTrue(overlay.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(red, whiteForeground ? 1 : 0)
            XCTAssertEqual(alpha, whiteForeground ? 0.10 : 0.06, accuracy: 0.0001)
            let selectedGray = Double(red * alpha) + gray * Double(1 - alpha)
            let selectedLuminance = luminance(selectedGray)
            let selectedContrast = whiteForeground ? 1.05 / (selectedLuminance + 0.05) : (selectedLuminance + 0.05) / 0.05
            XCTAssertGreaterThanOrEqual(selectedContrast, 3.0,
                                       "The transient selection overlay must retain non-text contrast")
            XCTAssertEqual(cell.backgroundConfiguration?.cornerRadius, 0)

            cell.isSelected = false
            cell.updateConfiguration(using: cell.configurationState)
            XCTAssertEqual(cell.backgroundConfiguration?.backgroundColor?.cgColor.alpha, 0)
        }
    }

    func testAlbumUsesPreparedBackdropOfDisplayedFirstTrack() async throws {
        let saved = LocalLibrary.songLibrary.songs
        defer { LocalLibrary.songLibrary.replace(saved) }
        let firstData = imageData(.black)
        let secondData = imageData(.white)
        let prepared = try await AlbumArtworkBackdropPreparer().prepare(["backdrop/1": firstData, "backdrop/2": secondData])
        let first = LibrarySongItem(id: "backdrop/1", title: "First", artist: "A", album: "B", albumArtist: "A", trackNumber: 1,
                                    artwork: .image(Image(uiImage: UIImage(data: firstData)!)), albumDirectory: "backdrop",
                                    artworkData: firstData, artworkBackdrop: prepared["backdrop/1"])
        let second = LibrarySongItem(id: "backdrop/2", title: "Second", artist: "A", album: "B", albumArtist: "A", trackNumber: 2,
                                     artwork: .image(Image(uiImage: UIImage(data: secondData)!)), albumDirectory: "backdrop",
                                     artworkData: secondData, artworkBackdrop: prepared["backdrop/2"])
        LocalLibrary.songLibrary.replace([second, first])
        let detail = try XCTUnwrap(LocalLibrary.albumDetail(first.albumID))
        XCTAssertEqual(detail.songs.first?.id, first.id)
        XCTAssertEqual(detail.songs.first?.artworkData, firstData)
        XCTAssertEqual(detail.albumBackdrop, try XCTUnwrap(prepared[first.id]))
        XCTAssertNotEqual(detail.albumBackdrop, prepared[second.id])
        guard case .image(let displayedArtwork) = detail.artwork, case .image(let firstArtwork) = first.artwork else {
            return XCTFail("Album header should display the first track's artwork")
        }
        XCTAssertEqual(displayedArtwork, firstArtwork)
        XCTAssertNil(LocalLibrary.playlistDetail("favorites")?.albumBackdrop)
    }

    func testPreparerReusesEqualArtworkAndReplacesChangedSources() async throws {
        let firstData = Data("first artwork".utf8)
        let secondData = Data("second artwork".utf8)
        let firstColor = AlbumArtworkBackdrop(red: 0.1, green: 0.2, blue: 0.3)
        let secondColor = AlbumArtworkBackdrop(red: 0.8, green: 0.7, blue: 0.6)
        let calls = Mutex<[Data: Int]>([:])
        let preparer = AlbumArtworkBackdropPreparer { data in
            calls.withLock { $0[data, default: 0] += 1 }
            return data == firstData ? firstColor : secondColor
        }

        let first = try await preparer.prepare(["song": firstData, "same artwork": Data(Array(firstData))])
        XCTAssertEqual(first, ["song": firstColor, "same artwork": firstColor])
        XCTAssertEqual(calls.withLock { $0[firstData] }, 1)

        let changed = try await preparer.prepare(["song": secondData])
        XCTAssertEqual(changed, ["song": secondColor])
        XCTAssertEqual(calls.withLock { $0[secondData] }, 1)

        // Only artwork in the last successful snapshot remains cached.
        let restored = try await preparer.prepare(["song": firstData])
        XCTAssertEqual(restored, ["song": firstColor])
        XCTAssertEqual(calls.withLock { $0[firstData] }, 2)
    }

    func testPreparerCachesInvalidResultsAndDropsMissingArtwork() async throws {
        let valid = Data("valid artwork".utf8)
        let invalid = Data("invalid artwork".utf8)
        let color = AlbumArtworkBackdrop(red: 0.1, green: 0.2, blue: 0.3)
        let calls = Mutex<[Data: Int]>([:])
        let preparer = AlbumArtworkBackdropPreparer { data in
            calls.withLock { $0[data, default: 0] += 1 }
            return data == valid ? color : nil
        }
        let first = try await preparer.prepare(["valid": valid, "invalid": invalid, "same invalid": invalid])
        XCTAssertEqual(first, ["valid": color])
        XCTAssertEqual(calls.withLock { $0[invalid] }, 1)

        let repeated = try await preparer.prepare(["invalid": invalid])
        XCTAssertTrue(repeated.isEmpty)
        XCTAssertEqual(calls.withLock { $0[invalid] }, 1)
        let empty = try await preparer.prepare([:])
        XCTAssertTrue(empty.isEmpty)
        _ = try await preparer.prepare(["invalid": invalid])
        XCTAssertEqual(calls.withLock { $0[invalid] }, 2)
    }

    func testCancelledPreparationDoesNotCommitPartialCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("original artwork".utf8)
        let replacement = Data("replacement artwork".utf8)
        let color = AlbumArtworkBackdrop(red: 0.1, green: 0.2, blue: 0.3)
        let calls = Mutex<[Data: Int]>([:])
        let cancelReplacement = Mutex(false)
        let preparer = AlbumArtworkBackdropPreparer(cacheURL: url) { data in
            calls.withLock { $0[data, default: 0] += 1 }
            if data == replacement, cancelReplacement.withLock({ $0 }) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return color
        }
        _ = try await preparer.prepare(["song": original])
        let saved = try Data(contentsOf: url)

        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preparer.prepare(["song": replacement])
        }
        do {
            _ = try await alreadyCancelled.value
            XCTFail("Preparation must reject a cancelled task")
        } catch is CancellationError {
        }
        XCTAssertNil(calls.withLock { $0[replacement] })

        cancelReplacement.withLock { $0 = true }
        let cancelledDuringExtraction = Task { try await preparer.prepare(["song": replacement]) }
        do {
            _ = try await cancelledDuringExtraction.value
            XCTFail("Preparation must check cancellation after extracting artwork")
        } catch is CancellationError {
        }
        cancelReplacement.withLock { $0 = false }
        XCTAssertEqual(try Data(contentsOf: url), saved)

        let retried = try await preparer.prepare(["original": original, "replacement": replacement])
        XCTAssertEqual(retried, ["original": color, "replacement": color])
        XCTAssertEqual(calls.withLock { $0[original] }, 1)
        XCTAssertEqual(calls.withLock { $0[replacement] }, 2)
    }

    func testDiskCacheReusesColorsAndInvalidResultsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let artwork = Data("original".utf8)
        let invalid = Data("invalid".utf8)
        let replacement = Data("replacement".utf8)
        let color = AlbumArtworkBackdrop(red: 0.2, green: 0.3, blue: 0.4)
        let first = AlbumArtworkBackdropPreparer(cacheURL: url) { $0 == invalid ? nil : color }
        _ = try await first.prepare(["a": artwork, "invalid": invalid])
        let sentinel = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: url.path)
        let calls = Mutex<[Data]>([])
        let second = AlbumArtworkBackdropPreparer(cacheURL: url) { data in
            calls.withLock { $0.append(data) }
            return color
        }
        let restored = try await second.prepare(["renamed": artwork, "duplicate": artwork, "invalid": invalid])
        XCTAssertEqual(restored, ["renamed": color, "duplicate": color])
        XCTAssertTrue(calls.withLock { $0.isEmpty })
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, sentinel)
        let updated = try await second.prepare(["renamed": replacement, "duplicate": replacement])
        XCTAssertEqual(updated, ["renamed": color, "duplicate": color])
        XCTAssertEqual(calls.withLock { $0 }, [replacement])
        let third = AlbumArtworkBackdropPreparer(cacheURL: url) { data in
            calls.withLock { $0.append(data) }
            return color
        }
        _ = try await third.prepare(["restored": artwork])
        XCTAssertEqual(calls.withLock { $0 }, [replacement, artwork], "Removed covers must leave the disk cache")
    }

    func testIncrementalImagePreparationKeepsPreviouslyPreparedColorsAcrossLaunches() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Data("first cover".utf8), second = Data("second cover".utf8)
        let color = AlbumArtworkBackdrop(red: 0.2, green: 0.3, blue: 0.4)
        let preparer = AlbumArtworkBackdropPreparer(cacheURL: url) { _ in color }
        _ = try await preparer.prepareAdditionalArtwork(["first": first])
        _ = try await preparer.prepareAdditionalArtwork(["second": second])
        let restored = AlbumArtworkBackdropPreparer(cacheURL: url) { _ in
            XCTFail("Preparing a later image must retain the earlier image's persisted color")
            return nil
        }
        let values = try await restored.prepareAdditionalArtwork(["first": first, "second": second])
        XCTAssertEqual(values, ["first": color, "second": color])
    }

    func testDisplayedCachedArtworkAlreadyHasItsNavigationBackdrop() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try imageData(.black).write(to: url)
        XCTAssertNil(LocalArtworkImages.cached(url, pixels: 0))
        _ = await LocalArtworkImages.load(url, pixels: 128)
        XCTAssertNotNil(LocalArtworkImages.cached(url, pixels: 128))
        let color = try XCTUnwrap(LocalArtworkImages.cachedBackdrop(for: .file(url)))
        XCTAssertEqual(color.colorScheme, .dark)
        XCTAssertEqual(color.red, 0, accuracy: 0.01)
        let route = LibraryRoute.album("catalog:album:812")
        var captured: LibraryNavigationPreview?
        let action = OpenLibraryRouteAction(handler: { _ in XCTFail("Expected a preview") },
            previewSourceHandler: { _, preview, _ in captured = preview })
        action(LibraryShelfItem(id: "catalog:album:812", title: "Cached album", artwork: .file(url), route: route),
               sourceProvider: { nil })
        let preview = try XCTUnwrap(captured)
        guard case .image = preview.artwork else { return XCTFail("The source must retain its decoded pixels") }
        XCTAssertEqual(preview.albumBackdrop, color)
        XCTAssertEqual(LibraryNavigationPreview(route: route, ownerID: nil, title: "Search album", artwork: .file(url)).albumBackdrop, color)
        XCTAssertEqual(LibraryNavigationPreview(route: .playlist("playlist"), ownerID: nil, title: "Playlist", artwork: .file(url)).albumBackdrop, color)
    }

    func testOnlineAlbumFirstPublicationUsesAlreadyDisplayedCoverBackdrop() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let previousAlbums = LocalLibrary.catalog.albums, previousArtists = LocalLibrary.catalog.artists
        defer {
            LocalLibrary.catalog.albums = previousAlbums
            LocalLibrary.catalog.artists = previousArtists
            try? FileManager.default.removeItem(at: directory)
        }
        let remote = try XCTUnwrap(URL(string: "https://artwork.test/\(UUID().uuidString).png"))
        let sourceData = imageData(.black)
        BackdropArtworkProtocol.state.withLock { $0 = .init(image: sourceData) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BackdropArtworkProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = NeteaseArtistStore(client: NeteaseMusicClient(transport: NeteaseAccountClient(session: session)),
            directory: directory, artworkSession: session)
        let cache = NeteasePageCache(directory: directory.appendingPathComponent("Pages"))
        try await cache.save(BackdropSubscriptions(), scope: "42", key: "subscriptions")
        let album = NeteaseArtistAlbum(id: 8, title: "Album", artist: "Artist", artworkURL: remote,
            publishTime: nil, type: "Album", trackCount: 0)
        try await cache.save(BackdropAlbumPage(detail: .init(album: album, songs: []), refreshedAt: Date()),
                             scope: "42", key: "album:8")
        let saved = NeteaseSavedSession(profile: .init(userID: 42, nickname: "Test", avatarURL: nil),
            credential: try .init(musicU: "fixture"))
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() },
            clearAvatarCache: {}, artists: store)
        await account.restoreCachedContent()
        let imageReady = expectation(description: "Source artwork is cached")
        store.onArtworkChange = { urls in if urls.contains(remote) { imageReady.fulfill() } }
        store.requestArtwork([remote])
        await fulfillment(of: [imageReady], timeout: 3)
        let file = try XCTUnwrap(store.cachedArtworkURL(remote))
        _ = await LocalArtworkImages.load(file, pixels: 128)
        let expected = try XCTUnwrap(LocalArtworkImages.cachedBackdrop(for: .file(file)))
        XCTAssertNil(store.albums[8], "The visible source does not need the full album page")
        let integration = ArtistMusicIntegration(account: account)
        integration.connect()
        let publish = store.onContentChange
        defer { store.onContentChange = publish }
        var firstPublications: [AlbumArtworkBackdrop?] = []
        store.onContentChange = { change in
            publish?(change)
            if case .album(8) = change { firstPublications.append(integration.albumDetail(8)?.albumBackdrop) }
        }
        await integration.load(.album("catalog:album:8"))
        XCTAssertEqual(firstPublications, [expected], "The first metadata publication must already match the visible cover")
        XCTAssertEqual(integration.albumDetail(8)?.artwork, .file(file))
        XCTAssertEqual(BackdropArtworkProtocol.state.withLock { $0.requests }, [remote])
        await store.invalidate()
    }

    func testPreviousPaletteVersionIsRecomputedAndPersisted() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let artwork = Data("artwork".utf8)
        let previous = AlbumArtworkBackdrop(red: 0.1, green: 0.2, blue: 0.3)
        let updated = AlbumArtworkBackdrop(red: 0.8, green: 0.2, blue: 0.1)
        _ = try await AlbumArtworkBackdropPreparer(cacheURL: url) { _ in previous }.prepare(["song": artwork])
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        snapshot["version"] = 1
        try JSONSerialization.data(withJSONObject: snapshot).write(to: url)

        let calls = Mutex(0)
        let preparer = AlbumArtworkBackdropPreparer(cacheURL: url) { _ in
            calls.withLock { $0 += 1 }
            return updated
        }
        let result = try await preparer.prepare(["song": artwork])
        XCTAssertEqual(result, ["song": updated])
        XCTAssertEqual(calls.withLock { $0 }, 1)
        let restored = AlbumArtworkBackdropPreparer(cacheURL: url) { _ in
            XCTFail("The new public palette should be reused across launches")
            return nil
        }
        let restoredResult = try await restored.prepare(["song": artwork])
        XCTAssertEqual(restoredResult, result)
    }

    func testMissingCorruptOrUnwritableColorCacheStillPreparesAppearance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artwork = Data("artwork".utf8)
        let color = AlbumArtworkBackdrop(red: 0.1, green: 0.2, blue: 0.3)
        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("invalid JSON".utf8).write(to: corrupt)
        for url in [root.appendingPathComponent("missing.json"), corrupt, root] {
            let preparer = AlbumArtworkBackdropPreparer(cacheURL: url) { _ in color }
            let result = try await preparer.prepare(["song": artwork])
            XCTAssertEqual(result, ["song": color])
        }
        let restored = AlbumArtworkBackdropPreparer(cacheURL: corrupt) { _ in
            XCTFail("A corrupt cache should be replaced with reusable colors")
            return nil
        }
        let result = try await restored.prepare(["song": artwork])
        XCTAssertEqual(result, ["song": color])
    }
}

@MainActor
final class PlayerTextMetricsTests: XCTestCase {
    func testScaledGlyphFontUsesTheProvidedSizeExactlyOnce() {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let white = NowPlayingVisualHierarchy.textFont(fontSize: 54, weight: .semibold, isWhite: true,
                                                       fontSizeIsScaled: true, traits: traits)
        let artist = NowPlayingVisualHierarchy.textFont(fontSize: 54, weight: .regular, isWhite: false,
                                                        fontSizeIsScaled: true, traits: traits)
        XCTAssertEqual(white.pointSize, 54)
        XCTAssertEqual(artist.pointSize, 54)
    }

    func testBaseGlyphFontsRetainTheirExistingTextStyleScaling() {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let artist = NowPlayingVisualHierarchy.textFont(fontSize: 13, weight: .regular, isWhite: false,
                                                        fontSizeIsScaled: false, traits: traits)
        let expectedArtist = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13), compatibleWith: traits)
        XCTAssertEqual(artist.pointSize, expectedArtist.pointSize)

        let title = NowPlayingVisualHierarchy.textFont(fontSize: 17, weight: .semibold, isWhite: true,
                                                       fontSizeIsScaled: false, traits: traits)
        let expectedTitle = UIFontMetrics(forTextStyle: .headline)
            .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), compatibleWith: traits)
        XCTAssertEqual(title.pointSize, expectedTitle.pointSize)
        let fixed = NowPlayingVisualHierarchy.textFont(fontSize: 20, weight: .regular, isWhite: false,
                                                       fontSizeIsScaled: false, traits: traits)
        XCTAssertEqual(fixed.pointSize, 20)
    }

    func testArtworkReservesTheAdditionalInformationHeight() {
        let layout = ReferenceNowPlayingLayout()
        XCTAssertEqual(NowPlayingArtworkPage.artworkSide(layout: layout, textScale: 1), layout.artworkSide)
        XCTAssertEqual(NowPlayingArtworkPage.artworkSide(layout: layout, textScale: 3), layout.artworkSide - 106)
    }

    func testArtworkReservesMeasuredAccessibilityControlsHeight() {
        let layout = ReferenceNowPlayingLayout()
        XCTAssertEqual(NowPlayingArtworkPage.artworkSide(layout: layout, textScale: 3, controlsOverflow: 140),
                       layout.artworkSide - 106 - 140)
        XCTAssertEqual(NowPlayingArtworkPage.artworkSide(layout: layout, textScale: 3, controlsOverflow: 400), 0)
    }
}
