import XCTest
import UIKit
import SwiftUI
@testable import NeoMusic

@MainActor
final class PlaylistPersistenceTests: XCTestCase {
    private func song(_ id: String) -> LibrarySongItem {
        LibrarySongItem(id: id, title: id, artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
    }

    private func cover(_ color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func savedCover(_ id: String, at url: URL) throws -> Data? {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let playlists = try XCTUnwrap(object["playlists"] as? [[String: Any]])
        let playlist = try XCTUnwrap(playlists.first { $0["id"] as? String == id })
        return (playlist["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }
    }

    func testRoundTripAndReconcilePreserveMetadataAndOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let songs = [song("a"), song("b")]
        let first = PlaylistLibrary(playlists: [])
        first.configurePersistence(url: url, songs: songs)
        let folder = first.createFolder(named: "folder", in: nil)
        await first.flushPersistence()
        let playlist = try XCTUnwrap(first.createPlaylist(named: "mix", artwork: .playlist, in: folder.id))
        await first.flushPersistence()
        first.savePlaylist(playlist.id, title: "saved", description: "description", showsOnProfile: false, artwork: .playlist, songs: songs.reversed())
        await first.flushPersistence()
        first.toggleFavorite(playlist.id)
        await first.flushPersistence()
        first.togglePin(playlist.id)
        await first.flushPersistence()
        let restored = PlaylistLibrary(playlists: [])
        restored.configurePersistence(url: url, songs: songs)
        XCTAssertNil(restored.persistenceError)
        XCTAssertEqual(restored.songs(in: playlist.id).map(\.id), ["b", "a"])
        XCTAssertEqual(restored.folderID(of: playlist.id), folder.id)
        XCTAssertEqual(restored.playlist(playlist.id)?.description, "description")
        XCTAssertEqual(restored.playlist(playlist.id)?.isPinned, true)
        XCTAssertEqual(restored.playlist(playlist.id)?.isFavorite, true)
        restored.reconcileSongs([songs[0]])
        await restored.flushPersistence()
        let reconciled = PlaylistLibrary(playlists: [])
        reconciled.configurePersistence(url: url, songs: songs)
        XCTAssertEqual(reconciled.songs(in: playlist.id).map(\.id), ["a"])
        reconciled.deleteFolder(folder.id)
        await reconciled.flushPersistence()
        let deleted = PlaylistLibrary(playlists: [])
        deleted.configurePersistence(url: url, songs: songs)
        XCTAssertTrue(deleted.playlists.isEmpty)
        XCTAssertTrue(deleted.folders.isEmpty)
    }

    func testCorruptStoreIsReportedAndNeverOverwritten() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = Data("invalid".utf8)
        try bytes.write(to: url)
        let library = PlaylistLibrary(playlists: [])
        library.configurePersistence(url: url, songs: [])
        XCTAssertNotNil(library.persistenceError)
        _ = library.createPlaylist(named: "new", artwork: .playlist, in: nil)
        await library.flushPersistence()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testWriteFailureIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let library = PlaylistLibrary(playlists: [])
        library.configurePersistence(url: root.appendingPathComponent("store.json"), songs: [])
        _ = library.createPlaylist(named: "new", artwork: .playlist, in: nil)
        await library.flushPersistence()
        XCTAssertNotNil(library.persistenceError)
    }

    func testMetadataEditsReuseCoverBytesIncludingRestoredPNG() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let library = PlaylistLibrary(playlists: [])
        library.configurePersistence(url: url, songs: [])
        let playlist = try XCTUnwrap(library.createPlaylist(named: "cover", artwork: .image(Image(uiImage: cover(.red))), in: nil))
        await library.flushPersistence()
        let initial = try XCTUnwrap(savedCover(playlist.id, at: url))
        XCTAssertEqual(UIImage(data: initial)?.size, CGSize(width: 512, height: 512))
        library.renamePlaylist(playlist.id, to: "renamed")
        await library.flushPersistence()
        library.toggleFavorite(playlist.id)
        await library.flushPersistence()
        library.togglePin(playlist.id)
        await library.flushPersistence()
        XCTAssertEqual(try savedCover(playlist.id, at: url), initial)

        // Existing stores can contain any decodable cover. Keep its original bytes,
        // making a metadata-only edit observable if it accidentally rerenders it.
        let storedPNG = try XCTUnwrap(cover(.green).pngData())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var entries = try XCTUnwrap(object["playlists"] as? [[String: Any]])
        entries[0]["artworkData"] = storedPNG.base64EncodedString()
        object["playlists"] = entries
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let restored = PlaylistLibrary(playlists: [])
        restored.configurePersistence(url: url, songs: [])
        restored.renamePlaylist(playlist.id, to: "restored")
        await restored.flushPersistence()
        restored.reconcileSongs([])
        await restored.flushPersistence()
        XCTAssertNil(restored.persistenceError)
        XCTAssertEqual(try savedCover(playlist.id, at: url), storedPNG)
    }

    func testReplacingAndRemovingCoverUpdatesStoredBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let library = PlaylistLibrary(playlists: [])
        library.configurePersistence(url: url, songs: [])
        let playlist = try XCTUnwrap(library.createPlaylist(named: "cover", artwork: .image(Image(uiImage: cover(.red))), in: nil))
        await library.flushPersistence()
        let original = try XCTUnwrap(savedCover(playlist.id, at: url))
        library.savePlaylist(playlist.id, title: "replacement", description: "", showsOnProfile: true,
                             artwork: .image(Image(uiImage: cover(.blue))), songs: [])
        await library.flushPersistence()
        let replacement = try XCTUnwrap(savedCover(playlist.id, at: url))
        XCTAssertNotEqual(replacement, original)
        XCTAssertEqual(UIImage(data: replacement)?.size, CGSize(width: 512, height: 512))
        library.togglePin(playlist.id)
        await library.flushPersistence()
        XCTAssertEqual(try savedCover(playlist.id, at: url), replacement)
        library.savePlaylist(playlist.id, title: "no cover", description: "", showsOnProfile: true,
                             artwork: .playlist, songs: [])
        await library.flushPersistence()
        XCTAssertNil(try savedCover(playlist.id, at: url))
    }

    func testFailedCoverSaveRetriesWithLatestImageAndMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let library = PlaylistLibrary(playlists: [])
        library.configurePersistence(url: url, songs: [])
        let playlist = try XCTUnwrap(library.createPlaylist(named: "cover", artwork: .image(Image(uiImage: cover(.red))), in: nil))
        await library.flushPersistence()
        let original = try XCTUnwrap(savedCover(playlist.id, at: url))
        // A directory at the destination makes atomic replacement fail deterministically.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        library.savePlaylist(playlist.id, title: "new cover", description: "latest", showsOnProfile: false,
                             artwork: .image(Image(uiImage: cover(.blue))), songs: [])
        await library.flushPersistence()
        XCTAssertNotNil(library.persistenceError)
        try FileManager.default.removeItem(at: url)
        library.renamePlaylist(playlist.id, to: "retry")
        await library.flushPersistence()
        XCTAssertNil(library.persistenceError)
        let replacement = try XCTUnwrap(savedCover(playlist.id, at: url))
        XCTAssertNotEqual(replacement, original)
        XCTAssertEqual(UIImage(data: replacement)?.size, CGSize(width: 512, height: 512))
        let restored = PlaylistLibrary(playlists: [])
        restored.configurePersistence(url: url, songs: [])
        XCTAssertEqual(restored.playlist(playlist.id)?.title, "retry")
        XCTAssertEqual(restored.playlist(playlist.id)?.description, "latest")
        XCTAssertEqual(restored.playlist(playlist.id)?.showsOnProfile, false)
        restored.toggleFavorite(playlist.id)
        await restored.flushPersistence()
        XCTAssertEqual(try savedCover(playlist.id, at: url), replacement)
    }

    func testRapidEditsFlushLatestSnapshotAndSongOrder() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let songs = [song("first"), song("second")]
        let library = PlaylistLibrary(playlists: [])
        XCTAssertTrue(library.configurePersistence(url: url, songs: songs))
        let playlist = try XCTUnwrap(library.createPlaylist(named: "Initial", artwork: .playlist, in: nil))
        for index in 0..<30 {
            library.savePlaylist(playlist.id, title: "Revision \(index)", description: "", showsOnProfile: false,
                                 artwork: .playlist, songs: index.isMultiple(of: 2) ? songs : Array(songs.reversed()))
        }
        XCTAssertEqual(library.playlist(playlist.id)?.title, "Revision 29")
        XCTAssertEqual(library.songs(in: playlist.id).map(\.id), ["second", "first"])
        await library.flushPersistence()
        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: songs))
        XCTAssertEqual(restored.playlist(playlist.id)?.title, "Revision 29")
        XCTAssertEqual(restored.songs(in: playlist.id).map(\.id), ["second", "first"])
        XCTAssertNil(library.persistenceError)
    }

    func testUnflushedAccountSwitchKeepsPreferencesScoped() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let library = PlaylistLibrary(playlists: [])
        XCTAssertTrue(library.configurePersistence(url: url, songs: []))
        let first = LibraryPlaylistItem(id: "netease-playlist:1:10", title: "First", artwork: .playlist, sourceOwnerID: "1")
        let second = LibraryPlaylistItem(id: "netease-playlist:2:10", title: "Second", artwork: .playlist, sourceOwnerID: "2")
        library.replaceOnlinePlaylists(items: [first], songs: [:], ownerID: "1")
        library.togglePin(first.id)
        library.replaceOnlinePlaylists(items: [second], songs: [:], ownerID: "2")
        library.toggleFavorite(second.id)
        library.replaceOnlinePlaylists(items: [first], songs: [:], ownerID: "1")
        XCTAssertEqual(library.playlist(first.id)?.isPinned, true)
        XCTAssertEqual(library.playlist(first.id)?.isFavorite, false)
        await library.flushPersistence()

        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        restored.replaceOnlinePlaylists(items: [first], songs: [:], ownerID: "1")
        XCTAssertEqual(restored.playlist(first.id)?.isPinned, true)
        XCTAssertEqual(restored.playlist(first.id)?.isFavorite, false)
        restored.replaceOnlinePlaylists(items: [second], songs: [:], ownerID: "2")
        XCTAssertEqual(restored.playlist(second.id)?.isFavorite, true)
        XCTAssertEqual(restored.playlist(second.id)?.isPinned, false)
        await restored.flushPersistence()
    }

    func testBackgroundSaveIncludesMetadataArrivingDuringPendingWrite() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let library = PlaylistLibrary(playlists: [])
        XCTAssertTrue(library.configurePersistence(url: url, songs: []))
        library.restoreOnlineIdentity(ownerID: "42")
        let playlist = try XCTUnwrap(library.createPlaylist(named: "Mixed", artwork: .playlist, in: nil))
        let original = song("netease:42:7")
        library.addSongs([original], to: playlist.id)
        let updated = LibrarySongItem(id: original.id, title: "Arrived while saving", artist: original.artist,
                                      album: original.album, albumArtist: original.albumArtist, trackNumber: 1, artwork: .missing)
        library.reconcileOnlineSongs([updated])
        await library.flushPersistence()
        library.saveForBackground()
        await library.flushPersistence()

        let restored = PlaylistLibrary(playlists: [])
        restored.restoreOnlineIdentity(ownerID: "42")
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        XCTAssertEqual(restored.songs(in: playlist.id).first?.title, updated.title)
    }

    func testFailedOnlinePreferencesRetryOnLocalEditAndBackgroundSave() async throws {
        for retryInBackground in [false, true] {
            let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("playlists.json")
            let preferencesURL = root.appendingPathComponent("online-playlist-preferences-42.json")
            let library = PlaylistLibrary(playlists: [])
            XCTAssertTrue(library.configurePersistence(url: url, songs: []))
            let item = LibraryPlaylistItem(id: "netease-playlist:42:10", title: "Online", artwork: .playlist, sourceOwnerID: "42")
            library.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "42")
            library.togglePin(item.id)
            await library.flushPersistence()

            try FileManager.default.removeItem(at: preferencesURL)
            try FileManager.default.createDirectory(at: preferencesURL, withIntermediateDirectories: false)
            library.toggleFavorite(item.id)
            await library.flushPersistence()
            XCTAssertNotNil(library.persistenceError)

            try FileManager.default.removeItem(at: preferencesURL)
            if retryInBackground {
                library.saveForBackground()
            } else {
                _ = library.createFolder(named: "Local edit", in: nil)
            }
            await library.flushPersistence()
            XCTAssertNil(library.persistenceError)

            let restored = PlaylistLibrary(playlists: [])
            XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
            restored.replaceOnlinePlaylists(items: [item], songs: [:], ownerID: "42")
            XCTAssertEqual(restored.playlist(item.id)?.isPinned, true)
            XCTAssertEqual(restored.playlist(item.id)?.isFavorite, true)
            await restored.flushPersistence()
        }
    }
}

@MainActor
final class CoverSelectionTests: XCTestCase {
    private func png(_ color: UIColor) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
    }

    func testPhotoSuccessAndInvalidDataPreserveLastValidDraft() async throws {
        let selection = PlaylistCoverSelection()
        let bytes = png(.red)
        await selection.loadPhoto { bytes }
        let validDraft = try XCTUnwrap(selection.image)
        XCTAssertEqual(validDraft.pngData(), UIImage(data: bytes)?.pngData())
        XCTAssertFalse(selection.isLoading)
        XCTAssertFalse(selection.photoError)

        let invalidInputs: [Data?] = [Data("not an image".utf8), nil]
        for invalid in invalidInputs {
            await selection.loadPhoto { invalid }
            XCTAssertTrue(selection.image === validDraft)
            XCTAssertTrue(selection.photoError)
            XCTAssertFalse(selection.isLoading)
        }
    }

    func testCancelledPhotoLoadKeepsDraftAndReleasesLoadingWithoutError() async {
        let selection = PlaylistCoverSelection()
        let original = UIImage()
        selection.image = original
        let gate = CoverDataLoadGate()
        let task = Task { await selection.loadPhoto { try await gate.load() } }
        await gate.waitUntilStarted()
        XCTAssertTrue(selection.isLoading)
        task.cancel()
        // The provider can still return data after cancellation; it must not be applied.
        gate.finish(.success(png(.red)))
        await task.value
        XCTAssertTrue(selection.image === original)
        XCTAssertFalse(selection.photoError)
        XCTAssertFalse(selection.isLoading)

        await selection.loadPhoto { throw CancellationError() }
        XCTAssertTrue(selection.image === original)
        XCTAssertFalse(selection.photoError)
        XCTAssertFalse(selection.isLoading)
    }

    func testClosingDraftRejectsLatePhotoWithoutDiscardingLastValidImage() async {
        let selection = PlaylistCoverSelection()
        let original = UIImage()
        selection.image = original
        let gate = CoverDataLoadGate()
        let task = Task { await selection.loadPhoto { try await gate.load() } }
        await gate.waitUntilStarted()
        XCTAssertTrue(selection.isLoading)

        selection.cancelPendingLoad()
        XCTAssertFalse(selection.isLoading)
        XCTAssertNil(selection.photo)
        gate.finish(.success(png(.red)))
        await task.value

        XCTAssertTrue(selection.image === original)
        XCTAssertFalse(selection.photoError)
        XCTAssertFalse(selection.isLoading)
    }

    func testLatePhotoFailureAfterClosingDraftDoesNotPresentAnError() async {
        let selection = PlaylistCoverSelection()
        let gate = CoverDataLoadGate()
        let task = Task { await selection.loadPhoto { try await gate.load() } }
        await gate.waitUntilStarted()

        selection.cancelPendingLoad()
        gate.finish(.failure(CocoaError(.fileReadNoPermission)))
        await task.value

        XCTAssertNil(selection.image)
        XCTAssertFalse(selection.photoError)
        XCTAssertFalse(selection.isLoading)
    }

    func testOldLoadCannotReplaceDraftOrClearNewLoadingState() async throws {
        let selection = PlaylistCoverSelection()
        let original = UIImage()
        selection.image = original
        let oldGate = CoverDataLoadGate()
        let oldTask = Task { await selection.loadPhoto { try await oldGate.load() } }
        await oldGate.waitUntilStarted()

        selection.prepareForSelection()
        let newGate = CoverDataLoadGate()
        let newTask = Task { await selection.loadPhoto { try await newGate.load() } }
        await newGate.waitUntilStarted()
        oldGate.finish(.success(png(.red)))
        await oldTask.value
        XCTAssertTrue(selection.image === original)
        XCTAssertTrue(selection.isLoading)
        XCTAssertFalse(selection.photoError)

        let newBytes = png(.blue)
        newGate.finish(.success(newBytes))
        await newTask.value
        let newDraft = try XCTUnwrap(selection.image)
        XCTAssertEqual(newDraft.pngData(), UIImage(data: newBytes)?.pngData())
        XCTAssertFalse(selection.isLoading)
        XCTAssertFalse(selection.photoError)
    }

    func testFileImportSuccessFailureCancellationAndLatePhotoResult() async throws {
        let selection = PlaylistCoverSelection()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let gate = CoverDataLoadGate()
        let oldTask = Task { await selection.loadPhoto { try await gate.load() } }
        await gate.waitUntilStarted()

        let bytes = png(.blue)
        try bytes.write(to: url)
        selection.importFile(.success(url))
        let fileDraft = try XCTUnwrap(selection.image)
        XCTAssertEqual(fileDraft.pngData(), UIImage(data: bytes)?.pngData())
        gate.finish(.success(png(.red)))
        await oldTask.value
        XCTAssertTrue(selection.image === fileDraft)
        XCTAssertFalse(selection.isLoading)
        XCTAssertFalse(selection.photoError)

        try Data("not an image".utf8).write(to: url)
        selection.importFile(.success(url))
        XCTAssertTrue(selection.image === fileDraft)
        XCTAssertTrue(selection.photoError)
        selection.importFile(.failure(CocoaError(.fileReadNoPermission)))
        XCTAssertTrue(selection.image === fileDraft)
        XCTAssertTrue(selection.photoError)

        selection.importFile(.failure(CocoaError(.userCancelled)))
        XCTAssertTrue(selection.image === fileDraft)
        XCTAssertFalse(selection.photoError)
        XCTAssertFalse(selection.isLoading)
    }
}

/// Deterministic completion order without sleeps or real photo-library access.
@MainActor
private final class CoverDataLoadGate {
    private var hasStarted = false
    private var started: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Data?, Error>?

    func load() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            hasStarted = true
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<Data?, Error>) {
        completion?.resume(with: result)
        completion = nil
    }
}
