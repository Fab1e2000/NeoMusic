import Foundation
import Observation

extension NowPlayingModel {
    struct TrackPlaybackEvent: Identifiable {
        let id = UUID()
        let song: LibrarySongItem
    }
}

@MainActor @Observable
final class NowPlayingHistory {
    private var events: [NowPlayingModel.TrackPlaybackEvent] = []
    private var recorded: (generation: UInt64, entry: UUID, event: UUID)?

    func visible(owner: String?, generation: UInt64, entry: UUID?) -> [NowPlayingModel.TrackPlaybackEvent] {
        let current = currentEvent(generation: generation, entry: entry)
        return events.filter { $0.id != current && isVisible($0.song, owner: owner) }
    }

    func clear(owner: String?) {
        events.removeAll { isVisible($0.song, owner: owner) }
    }

    func returnToPrevious(generation: UInt64, entry: UUID?, targetEntry: UUID, targetSongID: String, owner: String?) {
        if let current = currentEvent(generation: generation, entry: entry) {
            events.removeAll { $0.id == current }
        }
        if let last = events.last(where: { isVisible($0.song, owner: owner) }), last.song.id == targetSongID {
            recorded = (generation, targetEntry, last.id)
        }
    }

    func carryRecording(for entry: UUID, to generation: UInt64) {
        if recorded?.entry == entry { recorded?.generation = generation }
    }

    func record(_ song: LibrarySongItem, generation: UInt64, entry: UUID, owner: String?) {
        guard currentEvent(generation: generation, entry: entry) == nil, isVisible(song, owner: owner) else { return }
        let event = NowPlayingModel.TrackPlaybackEvent(song: song)
        recorded = (generation, entry, event.id)
        events.append(event)
    }

    func updateArtwork(id: String, replacement: LibrarySongItem, isOffline: Bool,
                       hasResolvedIdentity: Bool, owner: String?) -> Bool {
        var changed = false
        for event in events where event.song.id == id {
            if !isOffline, let songOwner = event.song.onlineOwnerID,
               !hasResolvedIdentity || songOwner != owner { continue }
            changed = event.song.publishArtwork(from: replacement) || changed
        }
        return changed
    }

    private func currentEvent(generation: UInt64, entry: UUID?) -> UUID? {
        guard let recorded, recorded.generation == generation, recorded.entry == entry else { return nil }
        return recorded.event
    }

    private func isVisible(_ song: LibrarySongItem, owner: String?) -> Bool {
        guard let songOwner = song.onlineOwnerID else { return true }
        return songOwner == owner
    }
}
