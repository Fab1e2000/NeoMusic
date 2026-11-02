import SwiftUI
import Observation

typealias ReferenceLyrics = LyricsDocument
typealias ReferenceLyricLine = LyricsLine
extension LyricsDocument { var isTimed: Bool { !lines.isEmpty } }

@MainActor @Observable final class ReferenceLibrary {
    var contentRevision = 0
    let reader: ReferenceLyricsReader
    init(reader: ReferenceLyricsReader) { self.reader = reader }
}

/// Adapts the local lyrics store to the player presentation.
actor ReferenceLyricsReader {
    private let reader: LyricsReader
    private let root: URL
    private let resolve: @MainActor @Sendable (String) -> URL?
    init(storageDirectory: URL, root: URL, resolveAudioURL: @escaping @MainActor @Sendable (String) -> URL?) {
        reader = LyricsReader(storageDirectory: storageDirectory); self.root = root; resolve = resolveAudioURL
    }
    func load(trackID: String) async throws -> LyricsDocument {
        try Task.checkCancellation()
        guard let audioURL = await resolve(trackID) else { return LyricsDocument() }
        return try await reader.load(songID: trackID, audioURL: audioURL, root: root)
    }
    func importFile(_ url: URL, trackID: String) async throws {
        try await reader.importFile(url, songID: trackID)
    }
}

enum LyricsFocus { static let storageKey = "preview.lyrics.focusPosition" }
enum ImmersiveMode { static let storageKey = "preview.appearance.immersive" }

/// Only the source palette entries actually consumed by the player are carried over.
enum DizzyPalette {
    static let artworkPlaceholder = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 38/255, green: 38/255, blue: 38/255, alpha: 1) : .white })
    static let artworkPlaceholderSymbol = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 145/255, green: 154/255, blue: 161/255, alpha: 1)
        : UIColor(red: 106/255, green: 115/255, blue: 123/255, alpha: 1) })
    static let accentOnDark = Color.white
}
