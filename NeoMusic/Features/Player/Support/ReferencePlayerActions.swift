// Source: NeoDizzy / MeloX-derived song menu presentation (GPL-3.0).
// Production adaptation: actions are supplied by the library composition.
import SwiftUI
import UIKit

/// Actual resolved playback quality, projected by the owning music or file service.
struct PlayerAudioQuality: Equatable, Sendable {
    let title: String
    var detail: String? = nil
    var isLossless = false
}

/// All entry points use the same actions; platforms supply capabilities, never menu layouts.
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

extension SongMenuConfiguration {
    /// 系统 trailing 操作按从右向左排列；喜欢位于最右侧。
    var trailingSongActions: [SongRowAction] {
        let items = primary + secondary
        return ["favorite", "download"].compactMap { id in items.first { $0.id == id && !$0.disabled } }
            + extras.filter { $0.role == .destructive && !$0.disabled }
    }
}

@MainActor @Observable final class ReferencePlayerActions {
    private let favoriteLookup: (String) -> Bool
    private let favoriteAction: (String) -> Void
    private let playlistAction: (String) -> Void
    private let albumAction: (String) -> Void
    private let artistAction: (String) -> Void
    private let artistLookup: ((String) -> [String])?
    private let namedArtistAction: ((String, String) -> Void)?
    private let notifyAction: (LibraryToast) -> Void
    private let audioQualityLookup: ((String) -> PlayerAudioQuality?)?
    private let audioQualitySettingsAction: (() -> Void)?
    init(isFavorite: @escaping (String) -> Bool, toggleFavorite: @escaping (String) -> Void,
         addToPlaylist: @escaping (String) -> Void, openAlbum: @escaping (String) -> Void,
         openArtist: @escaping (String) -> Void, artistNames: ((String) -> [String])? = nil,
         openNamedArtist: ((String, String) -> Void)? = nil,
         notify: @escaping (LibraryToast) -> Void = { _ in },
         audioQuality: ((String) -> PlayerAudioQuality?)? = nil,
         openAudioQualitySettings: (() -> Void)? = nil) {
        artistLookup = artistNames; namedArtistAction = openNamedArtist
        favoriteLookup = isFavorite; favoriteAction = toggleFavorite; playlistAction = addToPlaylist; albumAction = openAlbum; artistAction = openArtist
        notifyAction = notify
        audioQualityLookup = audioQuality
        audioQualitySettingsAction = openAudioQualitySettings
    }
    func isFavorite(_ track: ReferenceTrack) -> Bool { favoriteLookup(track.id) }
    func addToPlaylist(_ track: ReferenceTrack) { playlistAction(track.id) }
    func openAlbum(_ track: ReferenceTrack) { albumAction(track.id) }
    func audioQuality(for track: ReferenceTrack) -> PlayerAudioQuality? { audioQualityLookup?(track.id) }
    var canOpenAudioQualitySettings: Bool { audioQualitySettingsAction != nil }
    func openAudioQualitySettings() { audioQualitySettingsAction?() }

    func artistNames(for track: ReferenceTrack) -> [String] {
        if let names = artistLookup?(track.id), !names.isEmpty { return names }
        return track.artists.isEmpty ? [] : [track.artists]
    }
    func openArtist(_ name: String, track: ReferenceTrack) {
        if let namedArtistAction { namedArtistAction(track.id, name) } else { artistAction(track.id) }
    }
    func notify(_ toast: LibraryToast) { notifyAction(toast) }
    func toggleFavorite(_ track: ReferenceTrack) {
        LibraryHaptics.impact()
        let removing = isFavorite(track)
        favoriteAction(track.id)
        notify(removing ? .unfavorited : .favorited)
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
    let track: ReferenceTrack
    var play: (() -> Void)? = nil
    var extras: [SongRowAction] = []
    @ViewBuilder let content: (SongMenuConfiguration) -> Content
    @Environment(ReferencePlayerActions.self) private var actions
    @Environment(ReferencePlayerState.self) private var player
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
    let track: ReferenceTrack
    var playerStyle = false
    @Environment(ReferencePlayerActions.self) private var actions
    private var liked: Bool { actions.isFavorite(track) }
    var body: some View {
        Button { actions.toggleFavorite(track) } label: {
            if playerStyle {
                Image(systemName: liked ? "star.fill" : "star")
                    .resizable().scaledToFit()
                    .frame(width: 19.14, height: 19.14)
                    .foregroundStyle(liked ? DizzyPalette.accentOnDark : .white)
                    .frame(width: 44, height: 44)
            } else { Label(liked ? "取消喜欢" : "喜欢", systemImage: "star.fill") }
        }.accessibilityLabel(liked ? "取消喜欢" : "喜欢")
    }
}
