import SwiftUI
import XCTest
import MetalKit
import Synchronization
@testable import NeoMusic

@MainActor
final class AlbumArtworkBackdropTests: XCTestCase {
    private func imageData(_ color: UIColor) -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        return image.pngData()!
    }

    func testSystemAnalyzerProvidesBackgroundAndMatchingForeground() throws {
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

    func testMidGrayUsesReadableDarkForeground() throws {
        let backdrop = AlbumArtworkBackdrop(red: 0.55, green: 0.55, blue: 0.55)
        XCTAssertEqual(backdrop.colorScheme, .light)
        let luminance = pow((0.55 + 0.055) / 1.055, 2.4)
        XCTAssertGreaterThanOrEqual((luminance + 0.05) / 0.05, 4.5)
        XCTAssertLessThan(1.05 / (luminance + 0.05), 4.5)

        let restored = try JSONDecoder().decode(AlbumArtworkBackdrop.self,
            from: Data(#"{"red":0.55,"green":0.55,"blue":0.55}"#.utf8))
        XCTAssertEqual(restored, backdrop)
        XCTAssertEqual(restored.colorScheme, .light)
    }

    func testForegroundContrastAcrossBoundaryAndSaturatedColors() {
        let samples: [(AlbumArtworkBackdrop, ColorScheme)] = [
            (.init(red: 0, green: 0, blue: 0), .dark),
            (.init(red: 1, green: 1, blue: 1), .light),
            (.init(red: 0.45, green: 0.45, blue: 0.45), .dark),
            (.init(red: 0.46, green: 0.46, blue: 0.46), .dark),
            (.init(red: 0.47, green: 0.47, blue: 0.47), .light),
            (.init(red: 1, green: 0, blue: 0), .light),
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
            XCTAssertGreaterThanOrEqual(contrast, 4.5)
        }
    }

    func testSelectedAlbumRowsImproveCompositedContrastAtGrayBoundary() async throws {
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
        for gray in [0.46, 0.47, 0.55] {
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
            XCTAssertEqual(red, whiteForeground ? 0 : 1)
            XCTAssertEqual(alpha, whiteForeground ? 0.10 : 0.06, accuracy: 0.0001)
            let selectedGray = Double(red * alpha) + gray * Double(1 - alpha)
            let originalLuminance = luminance(gray)
            let selectedLuminance = luminance(selectedGray)
            let originalContrast = whiteForeground ? 1.05 / (originalLuminance + 0.05) : (originalLuminance + 0.05) / 0.05
            let selectedContrast = whiteForeground ? 1.05 / (selectedLuminance + 0.05) : (selectedLuminance + 0.05) / 0.05
            XCTAssertGreaterThanOrEqual(selectedContrast, 4.5)
            XCTAssertGreaterThan(selectedContrast, originalContrast)
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
        let white = PlayerEDRGlyphView.textFont(fontSize: 54, weight: .semibold, isWhite: true,
                                              fontSizeIsScaled: true, traits: traits)
        let artist = PlayerEDRGlyphView.textFont(fontSize: 54, weight: .regular, isWhite: false,
                                               fontSizeIsScaled: true, traits: traits)
        XCTAssertEqual(white.pointSize, 54)
        XCTAssertEqual(artist.pointSize, 54)
    }

    func testBaseGlyphFontsRetainTheirExistingTextStyleScaling() {
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let artist = PlayerEDRGlyphView.textFont(fontSize: 13, weight: .regular, isWhite: false,
                                               fontSizeIsScaled: false, traits: traits)
        let expectedArtist = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13), compatibleWith: traits)
        XCTAssertEqual(artist.pointSize, expectedArtist.pointSize)

        let title = PlayerEDRGlyphView.textFont(fontSize: 17, weight: .semibold, isWhite: true,
                                              fontSizeIsScaled: false, traits: traits)
        let expectedTitle = UIFontMetrics(forTextStyle: .headline)
            .scaledFont(for: .systemFont(ofSize: 17, weight: .semibold), compatibleWith: traits)
        XCTAssertEqual(title.pointSize, expectedTitle.pointSize)
        let fixed = PlayerEDRGlyphView.textFont(fontSize: 20, weight: .regular, isWhite: false,
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

@MainActor
final class PlayerEDRTextureReuseTests: XCTestCase {
    private func backdrop(_ color: UIColor) -> CGImage {
        // Production backdrops are sRGB RGBA8; UIGraphicsImageRenderer may store solid gray as monochrome.
        let context = CGContext(data: nil, width: 1, height: 256, bitsPerComponent: 8,
                                bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 256))
        let image = context.makeImage()!
        XCTAssertEqual(image.colorSpace?.model, .rgb)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 32)
        return image
    }

    private func view() async throws -> PlayerEDRGlyphView {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal texture creation is unavailable on this test destination")
        await PlayerEDRResources.shared.prepare()
        XCTAssertTrue(PlayerEDRResources.shared.isReady)
        return PlayerEDRGlyphView(frame: CGRect(x: 0, y: 0, width: 180, height: 28))
    }

    private func update(_ view: PlayerEDRGlyphView, text: String = "Artist", size: CGFloat = 13,
                        weight: UIFont.Weight = .regular, isWhite: Bool = false, brightness: Double = 0.35) {
        view.update(text: text, fontSize: size, image: nil, anchor: nil,
                    brightness: brightness, isWhite: isWhite, fontWeight: weight)
    }

    private func textures(_ view: PlayerEDRGlyphView, _ image: CGImage, scale: CGFloat = 3,
                          file: StaticString = #filePath, line: UInt = #line) throws
        -> (mask: MTLTexture, backdrop: MTLTexture) {
        try XCTUnwrap(view.preparedTextures(backdrop: image, scale: scale), file: file, line: line)
    }

    func testMovementAndBrightnessReuseTexturesWhileNewImageReplacesOnlyBackdrop() async throws {
        let view = try await view()
        let image = backdrop(.red)
        update(view)
        let first = try textures(view, image)

        update(view)
        view.frame.origin = CGPoint(x: 50, y: 120)
        update(view, brightness: 0.7)
        let moved = try textures(view, image)
        XCTAssertTrue(first.mask === moved.mask)
        XCTAssertTrue(first.backdrop === moved.backdrop)

        let changed = try textures(view, backdrop(.blue))
        XCTAssertTrue(first.mask === changed.mask)
        XCTAssertFalse(first.backdrop === changed.backdrop)
    }

    func testTextShapeAndFontChangesReplaceMaskWithoutReloadingBackdrop() async throws {
        let view = try await view()
        let image = backdrop(.gray)
        update(view)
        var previous = try textures(view, image)
        let textChanges: [() -> Void] = [
            { self.update(view, text: "Other artist") },
            { self.update(view, text: "Other artist", size: 17) },
            { self.update(view, text: "Other artist", size: 17, weight: .semibold) },
            { self.update(view, text: "Other artist", size: 17, weight: .semibold, isWhite: true) }
        ]
        for change in textChanges {
            change()
            let current = try textures(view, image)
            XCTAssertFalse(previous.mask === current.mask)
            XCTAssertTrue(previous.backdrop === current.backdrop)
            previous = current
        }

        let shapes: [PlayerEDRMask] = [
            .symbol("airplayaudio", 18, 1), .symbol("airplayaudio", 22.5, 1),
            .symbol("airplayaudio", 22.5, 0.5), .symbol("speaker.wave.2", 22.5, 0.5),
            .circle(20), .circle(22), .time("0:01", false), .time("0:02", false), .time("0:02", true)
        ]
        for shape in shapes {
            view.update(shape: shape, image: nil, anchor: nil, brightness: 0.35)
            let current = try textures(view, image)
            XCTAssertFalse(previous.mask === current.mask)
            XCTAssertTrue(previous.backdrop === current.backdrop)
            let repeated = try textures(view, image)
            XCTAssertTrue(current.mask === repeated.mask)
            previous = current
        }

        // The stored text/font fields still match the earlier text: changing modes must invalidate it.
        update(view, text: "Other artist", size: 17, weight: .semibold)
        let restoredText = try textures(view, image)
        XCTAssertFalse(previous.mask === restoredText.mask)
        XCTAssertTrue(previous.backdrop === restoredText.backdrop)
    }

    func testGeometryScaleAndFontTraitsInvalidateOnlyMask() async throws {
        let view = try await view()
        let image = backdrop(.gray)
        update(view)
        var previous = try textures(view, image)
        let geometryChanges: [() -> Void] = [
            { view.bounds.size.width = 140 },
            { view.bounds.size.height = 32 },
            { view.bounds.origin = CGPoint(x: 2, y: 1) },
            {
                let previousCategory = view.traitCollection.preferredContentSizeCategory
                let category: UIContentSizeCategory = previousCategory == .accessibilityExtraExtraExtraLarge ? .large : .accessibilityExtraExtraExtraLarge
                view.traitOverrides.preferredContentSizeCategory = category
                view.updateTraitsIfNeeded()
                XCTAssertEqual(view.traitCollection.preferredContentSizeCategory, category)
                XCTAssertNotEqual(view.traitCollection.preferredContentSizeCategory, previousCategory)
            },
            {
                let previousWeight = view.traitCollection.legibilityWeight
                let weight: UILegibilityWeight = previousWeight == .bold ? .regular : .bold
                view.traitOverrides.legibilityWeight = weight
                view.updateTraitsIfNeeded()
                XCTAssertEqual(view.traitCollection.legibilityWeight, weight)
                XCTAssertNotEqual(view.traitCollection.legibilityWeight, previousWeight)
            }
        ]
        for change in geometryChanges {
            change()
            let current = try textures(view, image)
            XCTAssertFalse(previous.mask === current.mask)
            XCTAssertTrue(previous.backdrop === current.backdrop)
            previous = current
        }

        let rescaled = try textures(view, image, scale: 2)
        XCTAssertFalse(previous.mask === rescaled.mask)
        XCTAssertTrue(previous.backdrop === rescaled.backdrop)
        XCTAssertEqual(rescaled.mask.width, 280)
        XCTAssertEqual(rescaled.mask.height, 64)

        let bounds = view.bounds
        view.bounds = .zero
        XCTAssertNil(view.preparedTextures(backdrop: image, scale: 2))
        view.bounds = bounds
        let restored = try textures(view, image, scale: 2)
        XCTAssertTrue(rescaled.mask === restored.mask)
        XCTAssertTrue(rescaled.backdrop === restored.backdrop)
    }
}
