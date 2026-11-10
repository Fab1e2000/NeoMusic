import XCTest
@testable import NeoMusic

@MainActor
final class DownloadedLibraryTests: XCTestCase {
    private func song(_ id: String, title: String = "Song") -> LibrarySongItem {
        LibrarySongItem(id: id, title: title, artist: "Artist", album: "Album", albumArtist: "Artist",
                        trackNumber: 1, artwork: .missing)
    }

    func testDownloadedSongDeduplicatesCatalogWithoutLosingOnlineLookup() {
        let local = song("Downloads/one.flac")
        let online = song("netease:1:10", title: "Online title")
        let library = SongLibrary(songs: [local])
        library.replaceOnline([online])
        library.replaceExternalSongs([online, song("netease:1:11")])
        var available = true
        library.downloadedFileID = { $0 == online.id && available ? local.id : nil }
        library.refreshDownloadPresentation()
        XCTAssertEqual(library.allSongs.map(\.id), [local.id, "netease:1:11"])
        XCTAssertEqual(library.song(id: online.id), online)
        XCTAssertEqual(library.song(id: local.id), local)
        available = false
        library.refreshDownloadPresentation()
        XCTAssertEqual(library.allSongs.map(\.id), [local.id, online.id, "netease:1:11"])
        library.replaceOnline([])
        library.replaceExternalSongs([])
        XCTAssertEqual(library.allSongs, [local])
    }

    func testDownloadedFavoriteRoutesWithoutMutatingLocalImportPreferences() throws {
        let suite = "DownloadedLibraryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let downloaded = song("Downloads/one.flac"), imported = song("Imported/two.flac")
        let library = SongLibrary(songs: [downloaded, imported], defaults: defaults)
        var requested: [(String, Bool)] = []
        library.downloadedFavoriteAction = { song, liked in
            guard song.id == downloaded.id else { return false }
            requested.append((song.id, liked))
            return true
        }
        library.toggleFavorite(downloaded.id)
        XCTAssertEqual(requested.map(\.0), [downloaded.id])
        XCTAssertEqual(requested.map(\.1), [true])
        XCTAssertFalse(try XCTUnwrap(library.song(id: downloaded.id)).isFavorite)
        XCTAssertNil(defaults.array(forKey: "favoriteSongs"))
        library.toggleFavorite(imported.id)
        XCTAssertTrue(try XCTUnwrap(library.song(id: imported.id)).isFavorite)
        XCTAssertEqual(defaults.stringArray(forKey: "favoriteSongs"), [imported.id])
        var confirmed = downloaded
        confirmed.isFavorite = true
        library.updateLocalMetadata([downloaded.id: confirmed])
        XCTAssertTrue(try XCTUnwrap(library.song(id: downloaded.id)).isFavorite)
    }

    func testDownloadedAliasesDeduplicateBeforeLocalScanAndKeepBothLookups() {
        let local = song("Downloads/one.flac")
        let current = song("netease:2:10", title: "Current owner")
        let previous = song("netease:1:10", title: "Previous queue")
        let library = SongLibrary(songs: [])
        library.downloadedFileID = { [current.id, previous.id].contains($0) ? local.id : nil }
        library.replaceOnline([current])
        library.replaceExternalSongs([previous, current], source: "downloads")
        XCTAssertEqual(library.allSongs, [current])
        XCTAssertEqual(library.song(id: current.id), current)
        XCTAssertEqual(library.song(id: previous.id), previous)

        library.replace([local])
        XCTAssertEqual(library.allSongs, [local])
        XCTAssertEqual(library.song(id: current.id), current)
        XCTAssertEqual(library.song(id: previous.id), previous)
        XCTAssertEqual(library.song(id: local.id), local)
    }

    func testDownloadedPlaylistSurvivesAccountReplacementAndDeduplicatesOnline() throws {
        let library = PlaylistLibrary(playlists: [.init(id: "local", title: "Local", artwork: .playlist)])
        let track = song("Downloads/one.flac")
        let snapshot = LibraryPlaylistItem(id: "downloaded:playlist:7", title: "Snapshot", artwork: .playlist)
        let online = LibraryPlaylistItem(id: "netease-playlist:1:7", title: "Current", artwork: .playlist, sourceOwnerID: "1")
        library.replaceDownloadedPlaylists(items: [snapshot], songs: [snapshot.id: [track]], onlineAliases: [snapshot.id: online.id])
        XCTAssertEqual(library.playlists.map(\.id), ["local", snapshot.id])
        XCTAssertTrue(try XCTUnwrap(library.playlist(snapshot.id)).isDownloadedSnapshot)
        library.replaceOnlinePlaylists(items: [online], songs: [online.id: [song("netease:1:10")]], ownerID: "1")
        XCTAssertEqual(library.playlists.map(\.id), ["local", online.id])
        XCTAssertEqual(library.songs(in: snapshot.id), [track])
        XCTAssertNotNil(library.playlist(snapshot.id))
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: nil)
        XCTAssertEqual(library.playlists.map(\.id), ["local", snapshot.id])
        XCTAssertEqual(library.songs(in: snapshot.id), [track])
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "2")
        XCTAssertEqual(library.songs(in: snapshot.id), [track])
        library.replaceDownloadedPlaylists(items: [], songs: [:])
        XCTAssertEqual(library.playlists.map(\.id), ["local"])
        XCTAssertNil(library.playlist(snapshot.id))
        XCTAssertEqual(library.songs(in: snapshot.id), [])
    }

    func testDownloadedSnapshotsStayOutOfEditablePlaylistPersistence() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = song("Downloads/one.flac")
        let url = root.appendingPathComponent("playlists.json")
        let library = PlaylistLibrary(playlists: [.init(id: "local", title: "Local", artwork: .playlist)])
        let snapshot = LibraryPlaylistItem(id: "downloaded:playlist:7", title: "Snapshot", artwork: .playlist)
        library.replaceDownloadedPlaylists(items: [snapshot], songs: [snapshot.id: [track]])
        XCTAssertTrue(library.configurePersistence(url: url, songs: [track]))
        XCTAssertEqual(library.addSongs([track], to: "local"), 1)
        await library.flushPersistence()
        let saved = try JSONDecoder().decode(PlaylistLibrary.Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.playlists.map(\.id), ["local"])
        XCTAssertFalse(library.canDelete(snapshot.id))
        XCTAssertEqual(library.addSongs([track], to: snapshot.id), 0)
        await library.flushPersistence()
        XCTAssertNotNil(library.playlist(snapshot.id))
    }

    func testOfflineOnlineReferencesRestoreWithoutAccountAndSurviveSwitch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let online = song("netease:1:10", title: "Downloaded title")
        let original = PlaylistLibrary(playlists: [.init(id: "local", title: "Local", artwork: .playlist)])
        XCTAssertTrue(original.configurePersistence(url: url, songs: []))
        original.restoreOnlineIdentity(ownerID: "1")
        original.addSongs([online], to: "local")
        await original.flushPersistence()
        let restored = PlaylistLibrary(playlists: [])
        var available = true
        restored.configureOfflineSongs { $0 == online.id && available ? online : nil }
        XCTAssertTrue(restored.configurePersistence(url: url, songs: []))
        XCTAssertEqual(restored.songs(in: "local"), [online])
        restored.restoreOnlineIdentity(ownerID: "2")
        restored.reconcileOnlineSongs([])
        restored.reconcileSongs([])
        await restored.flushPersistence()
        XCTAssertEqual(restored.songs(in: "local"), [online])
        available = false
        restored.reconcileOfflineAvailability()
        XCTAssertEqual(restored.songs(in: "local"), [.unavailable(online.id)])
        available = true
        restored.reconcileOfflineAvailability()
        XCTAssertEqual(restored.songs(in: "local"), [online])
    }

    func testRemovingFileRemapsReferencesAndPersistsOrderIncludingDuplicates() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("playlists.json")
        let file = song("Downloads/one.flac"), imported = song("Imported/two.flac")
        let online = song("netease:1:10", title: "Retained title")
        let library = PlaylistLibrary(playlists: [.init(id: "local", title: "Local", artwork: .playlist)])
        XCTAssertTrue(library.configurePersistence(url: url, songs: [file, imported]))
        library.restoreOnlineIdentity(ownerID: "1")
        library.addSongs([file, imported, online], to: "local")
        await library.flushPersistence()
        let downloaded = LibraryPlaylistItem(id: "downloaded:playlist:7", title: "Snapshot", artwork: .playlist)
        library.replaceDownloadedPlaylists(items: [downloaded], songs: [downloaded.id: [file, imported, file]])

        library.remapSongReferences([file.id: online])
        await library.flushPersistence()
        let expected = [online, imported, online]
        XCTAssertEqual(library.songs(in: "local"), expected)
        XCTAssertEqual(library.songs(in: downloaded.id), expected)
        library.replaceOnlinePlaylists(items: [], songs: [:], ownerID: "1")
        await library.flushPersistence()
        XCTAssertEqual(library.songs(in: downloaded.id), expected)
        library.reconcileSongs([imported])
        await library.flushPersistence()
        XCTAssertEqual(library.songs(in: "local"), expected)

        let snapshot = try JSONDecoder().decode(PlaylistLibrary.Snapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(snapshot.playlists.map(\.id), ["local"])
        XCTAssertEqual(snapshot.playlists.first?.songs, expected.map(\.id))
        XCTAssertEqual(snapshot.onlineSongs?[online.id]?.song.title, online.title)

        let restored = PlaylistLibrary(playlists: [])
        XCTAssertTrue(restored.configurePersistence(url: url, songs: [imported]))
        restored.restoreOnlineIdentity(ownerID: "1")
        XCTAssertEqual(restored.songs(in: "local"), expected)
    }
}
