import FullScreenPlayer
import SwiftUI
import Observation


@MainActor @Observable final class PlayerLyricsController {
    var contentRevision = 0
    let reader: PlayerLyricsStoreAdapter
    init(reader: PlayerLyricsStoreAdapter) { self.reader = reader }
    @ObservationIgnored private var cachedSource: PlayerLyricsSource?
    var source: PlayerLyricsSource {
        if let cachedSource { return cachedSource }
        let reader = reader
        let source = PlayerLyricsSource(revision: { [weak self] in self?.contentRevision ?? 0 },
            load: { id in
                let document = try await reader.load(trackID: id)
                return document.playerLyrics
            }, importFile: { url, id in try await reader.importFile(url, trackID: id) })
        cachedSource = source
        return source
    }
}

typealias ReferenceLibrary = PlayerLyricsController

/// Adapts the local lyrics store to the player presentation.
actor PlayerLyricsStoreAdapter {
    private let reader: LyricsReader
    private let root: URL
    private var remoteLyrics: (@MainActor @Sendable (String) async throws -> LyricsDocument)?
    func configureRemoteLyrics(_ load: @escaping @MainActor @Sendable (String) async throws -> LyricsDocument) { remoteLyrics = load }
    private let resolve: @MainActor @Sendable (String) -> URL?
    init(storageDirectory: URL, root: URL, resolveAudioURL: @escaping @MainActor @Sendable (String) -> URL?) {
        reader = LyricsReader(storageDirectory: storageDirectory); self.root = root; resolve = resolveAudioURL
    }
    func load(trackID: String) async throws -> LyricsDocument {
        try Task.checkCancellation()
        if OnlineSongIdentity.parseOwnerAndSong(trackID) != nil, let remoteLyrics {
            let result = try await remoteLyrics(trackID)
            try Task.checkCancellation()
            return result
        }
        guard let audioURL = await resolve(trackID) else { return LyricsDocument() }
        return try await reader.load(songID: trackID, audioURL: audioURL, root: root)
    }
    func importFile(_ url: URL, trackID: String) async throws {
        try await reader.importFile(url, songID: trackID)
    }
}

typealias ReferenceLyricsReader = PlayerLyricsStoreAdapter

enum ImmersiveMode { static let storageKey = "preview.appearance.immersive" }



extension LyricsDocument {
    static func onlineLyrics(original: String, translation: String) -> Self {
        let base = parse(original), translated = parse(translation)
        guard !base.lines.isEmpty else { return base }
        let translations = Dictionary(grouping: translated.lines, by: \.time)
        let lines = base.lines.map { line in
            let additional = translations[line.time, default: []].map(\.text)
                .filter { !$0.isEmpty && $0 != line.text }
            return LyricsLine(id: line.id, time: line.time, text: ([line.text] + additional).joined(separator: "\n"))
        }
        return Self(lines: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: "网易云音乐")
    }
}

extension LyricsDocument {
    var playerLyrics: PlayerLyrics {
        PlayerLyrics(lines: lines.map { PlayerLyricLine(id: $0.id, time: $0.time, text: $0.text) },
                     plainText: plainText, source: source)
    }
}
