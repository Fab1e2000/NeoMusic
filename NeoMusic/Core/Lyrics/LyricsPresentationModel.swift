import Foundation
import Observation

@MainActor @Observable final class LyricsPresentationModel {
    private(set) var songID: String?
    private(set) var document: LyricsDocument?
    private(set) var isLoading = false
    private(set) var error: String?
    private var generation = 0

    func load(songID: String, resolve: () async throws -> LyricsDocument) async {
        generation += 1
        let request = generation
        self.songID = songID
        document = nil
        error = nil
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let result = try await resolve()
            try Task.checkCancellation()
            guard generation == request else { return }
            document = result
        } catch is CancellationError { }
        catch {
            guard generation == request, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        generation += 1
        songID = nil
        document = nil
        error = nil
        isLoading = false
    }
}
