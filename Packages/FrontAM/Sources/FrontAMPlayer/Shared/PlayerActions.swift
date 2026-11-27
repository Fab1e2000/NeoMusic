// Source: NeoDizzy / MeloX-derived song menu presentation (GPL-3.0).
import SwiftUI
import UIKit

public struct PlayerAudioQuality: Equatable, Sendable {
    public let title: String
    public var detail: String? = nil
    public var isLossless = false
    public var isLocalFormat = false


    public init(title: String, detail: String? = nil, isLossless: Bool = false, isLocalFormat: Bool = false) {
        self.title = title; self.detail = detail; self.isLossless = isLossless; self.isLocalFormat = isLocalFormat
    }

}

@MainActor struct SongMenuConfiguration {
    var primary: [SongRowAction]
    let secondary: [SongRowAction]
    var artistTitle: String
    var artists: [SongRowAction]
    var extras: [SongRowAction]

    var nativeItems: [UIMenuElement] {
        func action(_ item: SongRowAction) -> UIAction {
            UIAction(title: item.title, image: UIImage(systemName: item.systemImage),
                     attributes: item.disabled ? [.disabled] : item.role == .destructive ? [.destructive] : []) { _ in item.perform() }
        }
        let quick = UIMenu(options: .displayInline, children: primary.map(action))
        quick.preferredElementSize = .medium
        var navigation: [UIMenuElement] = secondary.map(action)
        if artists.count == 1, let artist = artists.first {
            navigation.append(UIAction(title: artistTitle, image: UIImage(systemName: "music.microphone")) { _ in artist.perform() })
        } else if !artists.isEmpty {
            navigation.append(UIMenu(title: artistTitle, image: UIImage(systemName: "music.microphone"), children: artists.map(action)))
        }
        var result: [UIMenuElement] = [quick]
        if !navigation.isEmpty { result.append(UIMenu(options: .displayInline, children: navigation)) }
        if !extras.isEmpty { result.append(UIMenu(options: .displayInline, children: extras.map(action))) }
        return result
    }
}

struct ReferenceSongMenuContents: View {
    let configuration: SongMenuConfiguration
    var body: some View {
        ControlGroup {
            ForEach(configuration.primary) { item in action(item) }
        }
        Section {
            ForEach(configuration.secondary) { item in action(item) }
            if configuration.artists.count == 1, let artist = configuration.artists.first {
                Button(configuration.artistTitle, systemImage: "music.microphone", action: artist.perform)
            } else if !configuration.artists.isEmpty {
                Menu(configuration.artistTitle, systemImage: "music.microphone") {
                    ForEach(configuration.artists) { item in action(item) }
                }
            }
        }
        if !configuration.extras.isEmpty {
            Section { ForEach(configuration.extras) { item in action(item) } }
        }
    }
    private func action(_ item: SongRowAction) -> some View {
        Button(item.title, systemImage: item.systemImage, role: item.role, action: item.perform)
            .disabled(item.disabled)
    }
}

@MainActor @Observable public final class PlayerActions {
    private let feedbackAction: () -> Void
    private let favoriteLookup: (String) -> Bool
    private let favoriteAction: (String) -> Void
    private let favoriteCompletesSynchronously: ((String) -> Bool)?
    private let playlistAction: (String) -> Void
    private let albumAction: (String) -> Void
    private let artistAction: (String) -> Void
    private let artistLookup: ((String) -> [String])?
    private let namedArtistAction: ((String, String) -> Void)?
    private let notifyAction: (PlayerNotice) -> Void
    private let audioQualityLookup: ((String) -> PlayerAudioQuality?)?
    private let audioQualitySettingsAction: (() -> Void)?
    public init(isFavorite: @escaping (String) -> Bool, toggleFavorite: @escaping (String) -> Void,
         addToPlaylist: @escaping (String) -> Void, openAlbum: @escaping (String) -> Void,
         openArtist: @escaping (String) -> Void, artistNames: ((String) -> [String])? = nil,
         openNamedArtist: ((String, String) -> Void)? = nil,
         feedback: @escaping () -> Void = {},
         notify: @escaping (PlayerNotice) -> Void = { _ in },
         completesFavoriteSynchronously: ((String) -> Bool)? = nil,
         audioQuality: ((String) -> PlayerAudioQuality?)? = nil,
         openAudioQualitySettings: (() -> Void)? = nil) {
        artistLookup = artistNames; namedArtistAction = openNamedArtist
        favoriteLookup = isFavorite; favoriteAction = toggleFavorite; favoriteCompletesSynchronously = completesFavoriteSynchronously
        playlistAction = addToPlaylist; albumAction = openAlbum; artistAction = openArtist
        feedbackAction = feedback
        notifyAction = notify
        audioQualityLookup = audioQuality
        audioQualitySettingsAction = openAudioQualitySettings
    }
    public func isFavorite(_ track: PlayerTrack) -> Bool { favoriteLookup(track.id) }
    public func addToPlaylist(_ track: PlayerTrack) { playlistAction(track.id) }
    public func openAlbum(_ track: PlayerTrack) { albumAction(track.id) }
    public func audioQuality(for track: PlayerTrack) -> PlayerAudioQuality? { audioQualityLookup?(track.id) }
    public var canOpenAudioQualitySettings: Bool { audioQualitySettingsAction != nil }
    public func openAudioQualitySettings() { audioQualitySettingsAction?() }

    public func artistNames(for track: PlayerTrack) -> [String] {
        if let names = artistLookup?(track.id), !names.isEmpty { return names }
        return track.artists.isEmpty ? [] : [track.artists]
    }
    public func openArtist(_ name: String, track: PlayerTrack) {
        if let namedArtistAction { namedArtistAction(track.id, name) } else { artistAction(track.id) }
    }
    public func notify(_ toast: PlayerNotice) { notifyAction(toast) }
    public func toggleFavorite(_ track: PlayerTrack) {
        let removing = isFavorite(track)
        let completesImmediately = favoriteCompletesSynchronously?(track.id) ?? true
        favoriteAction(track.id)
        if completesImmediately {
            feedbackAction()
            notify(removing ? .unfavorited : .favorited)
        }
    }
}

@MainActor struct SongRowAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var role: ButtonRole?
    var disabled = false
    let perform: () -> Void
}

struct SongMenuHost<Content: View>: View {
    let track: PlayerTrack
    var play: (() -> Void)? = nil
    var extras: [SongRowAction] = []
    @ViewBuilder let content: (SongMenuConfiguration) -> Content
    @Environment(PlayerActions.self) private var actions
    @Environment(PlayerState.self) private var player
    var body: some View { content(configuration) }
    private var configuration: SongMenuConfiguration {
        let liked = actions.isFavorite(track)
        var primary: [SongRowAction] = []
        if let play {
            let current = player.currentTrack?.id == track.id
            let pauses = current && player.isPlaying
            primary.append(.init(id: "play", title: pauses ? "暂停" : "播放", systemImage: pauses ? "pause.fill" : "play.fill") {
                if current { player.togglePlayback() } else { play() }
            })
        }
        primary.append(.init(id: "favorite", title: liked ? "取消喜欢" : "喜欢", systemImage: "star.fill") { actions.toggleFavorite(track) })
        primary.append(.init(id: "playlist", title: "加入", systemImage: "text.badge.plus") { actions.addToPlaylist(track) })
        let secondary: [SongRowAction] = [
            .init(id: "playNext", title: "下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward") {
                player.enqueue(track, next: true)
                actions.notify(.playingNext)
            },
            .init(id: "playLast", title: "最后播放", systemImage: "text.line.last.and.arrowtriangle.forward") {
                player.enqueue(track, next: false)
                actions.notify(.addedToQueue)
            },
            .init(id: "album", title: "查看专辑", systemImage: "music.note.square.stack") { actions.openAlbum(track) }
        ]
        let artists = actions.artistNames(for: track).enumerated().map { index, name in
            SongRowAction(id: "artist/\(index)", title: name, systemImage: "music.microphone") { actions.openArtist(name, track: track) }
        }
        return .init(primary: primary, secondary: secondary, artistTitle: "查看艺人", artists: artists, extras: extras)
    }
}

struct FavoriteButton: View {
    let track: PlayerTrack
    var playerStyle = false
    @Environment(PlayerActions.self) private var actions
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    private var liked: Bool { actions.isFavorite(track) }
    var body: some View {
        if playerStyle {
            Button { actions.toggleFavorite(track) } label: {
                Image(systemName: liked ? "star.fill" : "star")
                    .resizable().scaledToFit()
                    .fontWeight(.medium)
                    .frame(width: 22.5, height: 22.5)
                    .offset(x: -0.333, y: -1)
                    .nowPlayingPrimary()
                    .contentTransition(.identity)
            }
            .buttonStyle(NowPlayingTransportButtonStyle(
                reducesMotion: reducesMotion,
                diameter: 44,
                showsHighlight: false
            ))
            .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
        } else {
            Button { actions.toggleFavorite(track) } label: {
                Label(liked ? "取消喜欢" : "喜欢", systemImage: "star.fill")
            }
            .accessibilityLabel(liked ? "取消喜欢" : "喜欢")
        }
    }
}
