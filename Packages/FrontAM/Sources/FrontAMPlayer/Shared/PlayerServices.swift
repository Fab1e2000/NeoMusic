import SwiftUI
import Observation

@MainActor @Observable public final class PlayerLyricsSource {
    private let revisionLookup: () -> Int
    private let loadAction: (String) async throws -> PlayerLyrics
    private let importAction: ((URL, String) async throws -> Void)?
    public var contentRevision: Int { revisionLookup() }
    public var canImport: Bool { importAction != nil }
    public init(revision: @escaping () -> Int = { 0 },
                load: @escaping (String) async throws -> PlayerLyrics,
                importFile: ((URL, String) async throws -> Void)? = nil) {
        revisionLookup = revision; loadAction = load; importAction = importFile
    }
    public func load(trackID: String) async throws -> PlayerLyrics { try await loadAction(trackID) }
    public func importFile(_ url: URL, trackID: String) async throws {
        guard let importAction else { throw CocoaError(.featureUnsupported) }
        try await importAction(url, trackID)
    }
}

public struct PlayerArtworkRequest: Hashable, Sendable {
    public let url: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let fits: Bool
    public init(url: URL, pixelWidth: Int, pixelHeight: Int, fits: Bool = false) {
        self.url = url; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.fits = fits
    }
}

@MainActor public final class PlayerArtworkProvider {
    private let cachedAction: (PlayerArtworkRequest) -> UIImage?
    private let displayFallbackAction: (PlayerArtworkRequest) -> UIImage?
    private let loadAction: (PlayerArtworkRequest) async throws -> UIImage
    private let prefetchAction: (([PlayerArtworkRequest]) async -> Void)?
    private let prepareAction: (String) -> Void
    private let prepareQueueAction: ((String, Bool) -> Task<Void, Never>?)?
    public init(cached: @escaping (PlayerArtworkRequest) -> UIImage?,
                displayFallback: @escaping (PlayerArtworkRequest) -> UIImage? = { _ in nil },
                load: @escaping (PlayerArtworkRequest) async throws -> UIImage,
                prefetch: (([PlayerArtworkRequest]) async -> Void)? = nil,
                prepare: @escaping (String) -> Void = { _ in },
                prepareQueue: ((String, Bool) -> Task<Void, Never>?)? = nil) {
        cachedAction = cached; loadAction = load; prepareAction = prepare; prefetchAction = prefetch
        displayFallbackAction = displayFallback; prepareQueueAction = prepareQueue
    }
    /// A cached decode that satisfies the requested size.
    public func cached(_ request: PlayerArtworkRequest) -> UIImage? { cachedAction(request) }
    public func displayFallback(_ request: PlayerArtworkRequest) -> UIImage? { displayFallbackAction(request) }
    public func load(_ request: PlayerArtworkRequest) async throws -> UIImage { try await loadAction(request) }
    public func prefetch(_ requests: [PlayerArtworkRequest]) async {
        if let prefetchAction { await prefetchAction(requests) }
        else {
            for request in requests {
                guard !Task.isCancelled else { return }
                _ = try? await load(request)
            }
        }
    }
    public func prepare(_ identity: String?) { if let identity { prepareAction(identity) } }
    func prepareQueue(_ identity: String, foreground: Bool) -> Task<Void, Never>? {
        if let prepareQueueAction { return prepareQueueAction(identity, foreground) }
        if foreground { prepare(identity) }
        return nil
    }
}

@MainActor public final class PlayerDiagnostics {
    private let beginAction: (StaticString, Bool) -> (() -> Void)
    private let eventAction: (StaticString) -> Void
    private let queueScrollAction: (() -> String) -> Void
    public init(begin: @escaping (StaticString, Bool) -> (() -> Void),
                event: @escaping (StaticString) -> Void,
                queueScroll: @escaping (() -> String) -> Void = { _ in }) {
        beginAction = begin; eventAction = event
        queueScrollAction = queueScroll
    }
    func begin(_ name: StaticString, animation: Bool = false) -> (() -> Void) { beginAction(name, animation) }
    func event(_ name: StaticString) { eventAction(name) }
    func queueScroll(_ message: @autoclosure () -> String) { queueScrollAction(message) }
}

@MainActor @Observable public final class PlayerServices {
    public let actions: PlayerActions
    public let lyrics: PlayerLyricsSource
    public let artwork: PlayerArtworkProvider
    public let diagnostics: PlayerDiagnostics?
    public init(actions: PlayerActions, lyrics: PlayerLyricsSource, artwork: PlayerArtworkProvider,
                diagnostics: PlayerDiagnostics? = nil) {
        self.actions = actions; self.lyrics = lyrics; self.artwork = artwork; self.diagnostics = diagnostics
    }
}

public enum PlayerNotice { case favorited, unfavorited, playingNext, addedToQueue }

enum PlayerResources {
    static let bundle = Bundle.module
    static let shaders = ShaderLibrary.bundle(bundle)
}
