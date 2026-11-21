import XCTest
import SwiftUI
@testable import NeoMusic

@MainActor
final class FrontendMaintainabilityTests: XCTestCase {
    private func makeSong(
        id: String,
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        duration: Int = 180,
        isFavorite: Bool = false,
        addedOrder: Int = 0
    ) -> LibrarySongItem {
        LibrarySongItem(
            id: id,
            title: title,
            artist: artist,
            album: album,
            albumArtist: artist,
            trackNumber: 1,
            artwork: .missing,
            duration: duration,
            addedOrder: addedOrder,
            isFavorite: isFavorite
        )
    }

    func testTrackFilterProjectionFastPathAndBackgroundSorting() async {
        let songs = (0..<150).map { index in
            makeSong(
                id: "song-\(index)",
                title: index == 42 ? "Target Echo" : "Track \(String(format: "%03d", 150 - index))",
                artist: "Artist \(index % 5)",
                album: "Album \(index % 3)",
                duration: 100
            )
        }
        let defaultInput = TrackFilterProjectionInput(tracks: songs, query: "", sort: .order)
        let fast = TrackFilterProjection.fastPath(defaultInput)
        XCTAssertEqual(fast?.tracks.count, 150)
        XCTAssertEqual(fast?.totalDuration, 15_000)

        let searchInput = TrackFilterProjectionInput(tracks: songs, query: "Target", sort: .title)
        XCTAssertNil(TrackFilterProjection.fastPath(searchInput))

        let projection = AsyncListProjection<TrackFilterProjectionInput, TrackFilterProjectionResult>()
        await TrackFilterProjection.update(projection, for: searchInput)
        let resolved = projection.currentValue(
            for: searchInput,
            fastPath: TrackFilterProjection.fastPath,
            placeholder: { _ in .empty }
        )
        XCTAssertEqual(resolved.tracks.map(\.id), ["song-42"])
        XCTAssertEqual(resolved.totalDuration, 15_000)
    }

    func testMusicPickerSessionCachesFallbackSourceAndGroupsLibrary() {
        let songs = [
            makeSong(id: "s1", title: "Beta", artist: "B Artist", album: "Alb B", isFavorite: true, addedOrder: 1),
            makeSong(id: "s2", title: "Alpha", artist: "A Artist", album: "Alb A", isFavorite: false, addedOrder: 2),
            makeSong(id: "s3", title: "Gamma", artist: "A Artist", album: "Alb A", isFavorite: true, addedOrder: 3)
        ]
        let session = MusicPickerSession()
        var fallbackBuilds = 0
        let first = session.resolvedSource(environment: nil) {
            fallbackBuilds += 1
            return MusicPickerSource.fallback(
                songs: songs,
                playlists: [],
                playlistLibrary: nil,
                playlistSongs: [:],
                recentlyPlayed: []
            )
        }
        _ = session.resolvedSource(environment: nil) {
            fallbackBuilds += 1
            return MusicPickerSource()
        }
        XCTAssertEqual(fallbackBuilds, 1)

        session.prepareIfNeeded(using: first)
        XCTAssertEqual(session.sortedSongs.map(\.title), ["Alpha", "Beta", "Gamma"])
        XCTAssertEqual(session.sortedArtists.map(\.name), ["A Artist", "B Artist"])
        XCTAssertEqual(session.sortedAlbums.map(\.title), ["Alb A", "Alb B"])
        XCTAssertEqual(session.recentFavorites.map(\.id), ["s3", "s1"])
    }

    func testCollectionPagePaletteSwipedColorDiffersForDarkAndLight() {
        let darkPalette = CollectionPagePalette(background: UIColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1), isDark: true)
        let lightPalette = CollectionPagePalette(background: UIColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1), isDark: false)

        var darkR: CGFloat = 0, lightR: CGFloat = 0
        darkPalette.swiped.getRed(&darkR, green: nil, blue: nil, alpha: nil)
        lightPalette.swiped.getRed(&lightR, green: nil, blue: nil, alpha: nil)

        XCTAssertEqual(darkR, 0.248, accuracy: 0.001)
        XCTAssertEqual(lightR, 0.846, accuracy: 0.001)
    }

    func testDesignTokensShareFavoritesColorsWithArtwork() {
        XCTAssertEqual(Artwork.favoritesRed, DesignTokens.Colors.favoritesRed)
        XCTAssertEqual(Artwork.favoritesBackground, DesignTokens.Colors.favoritesBackground)
    }
}
