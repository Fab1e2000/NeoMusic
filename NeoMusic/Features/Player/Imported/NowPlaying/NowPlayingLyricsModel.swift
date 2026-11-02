import Foundation
import Observation

/// Data adapter for the imported player. The injected library owns local/imported lyrics.
@MainActor @Observable final class NowPlayingLyricsModel {
    private(set) var lyrics: ReferenceLyrics?
    private(set) var error: String?
    private(set) var revision = 0
    enum Availability: Equatable {
        case loading, available, unavailable
    }

    private var currentTrackID: String?
    private var loadGeneration = 0
    private var availability: Availability = .loading
    func availability(for trackID: String?) -> Availability {
        guard let trackID, currentTrackID == trackID else { return .loading }
        return availability
    }

    func load(track: ReferenceTrack, library: ReferenceLibrary, player: ReferencePlayerState) async {
        await load(trackID: track.id) {
            try await library.reader.load(trackID: track.id)
        }
    }

    /// Generation checks also reject stale results from uncancellable providers
    /// and overlapping reloads of the same track after a lyrics import.
    func load(trackID: String, resolve: () async throws -> ReferenceLyrics) async {
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
            let hasText = !result.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || result.lines.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            availability = hasText ? .available : .unavailable
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == loadGeneration else { return }
            self.error = error.localizedDescription
            availability = .unavailable
        }
    }
    func importFile(_ url: URL, trackID: String, reader: ReferenceLyricsReader) async {
        do {
            try await reader.importFile(url, trackID: trackID)
            if currentTrackID == trackID { revision += 1 }
        }
        catch { if currentTrackID == trackID { self.error = error.localizedDescription } }
    }
}
