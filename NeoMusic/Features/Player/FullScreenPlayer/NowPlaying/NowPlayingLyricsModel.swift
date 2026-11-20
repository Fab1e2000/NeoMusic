import Foundation
import Observation

/// Data adapter for the imported player. The injected library owns local/imported lyrics.
@MainActor @Observable final class NowPlayingLyricsModel {
    private(set) var lyrics: PlayerLyrics?
    private(set) var error: String?
    private(set) var revision = 0
    enum Availability: Equatable {
        case loading, available, empty, failed
    }

    private var currentTrackID: String?
    private var loadGeneration = 0
    private var availability: Availability = .loading
    func availability(for trackID: String?) -> Availability {
        guard let trackID, currentTrackID == trackID else { return .loading }
        return availability
    }

    func load(track: PlayerTrack, library: PlayerLyricsSource, player: PlayerState) async {
        await load(trackID: track.id) {
            try await library.load(trackID: track.id)
        }
    }

    /// Generation checks also reject stale results from uncancellable providers
    /// and overlapping reloads of the same track after a lyrics import.
    func load(trackID: String, resolve: () async throws -> PlayerLyrics) async {
        loadGeneration += 1
        let generation = loadGeneration
        currentTrackID = trackID
        availability = .loading
        lyrics = nil
        error = nil
        do {
            let result = try await resolve()
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            lyrics = result
            let hasText: Bool
            if result.isTimed {
                let credits = LyricsCreditFilter.creditLineIndices(in: result.lines)
                hasText = result.lines.enumerated().contains { index, line in
                    !credits.contains(index) && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            } else {
                hasText = !result.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            availability = hasText ? .available : .empty
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            self.error = error.localizedDescription
            availability = .failed
        }
    }
    func importFile(_ url: URL, trackID: String, reader: PlayerLyricsSource) async {
        do {
            try await reader.importFile(url, trackID: trackID)
            if currentTrackID == trackID { revision += 1 }
        }
        catch { if currentTrackID == trackID { self.error = error.localizedDescription } }
    }
}
