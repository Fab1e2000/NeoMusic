import Foundation
import Observation

struct PlaybackCollectionReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case favorites, localAlbum, localPlaylist, onlinePlaylist, daily }
    let kind: Kind
    let id: String
    let ownerID: String?
    let title: String
}

@MainActor @Observable
final class PlaybackCollectionHistory {
    private struct Entry: Codable {
        let reference: PlaybackCollectionReference
        let date: Date
    }
    private var entries: [Entry] = []
    private let url: URL?
    init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved.sorted { $0.date > $1.date }
        }
    }
    func recent(for ownerID: String?) -> [PlaybackCollectionReference] {
        Array(entries.filter { $0.reference.ownerID == nil || $0.reference.ownerID == ownerID }.prefix(20).map(\.reference))
    }
    func record(_ reference: PlaybackCollectionReference, at date: Date = Date()) {
        entries.removeAll { $0.reference.kind == reference.kind && $0.reference.id == reference.id && $0.reference.ownerID == reference.ownerID }
        entries.append(Entry(reference: reference, date: date))
        entries.sort { $0.date > $1.date }
        var counts: [String: Int] = [:]
        entries = entries.filter { entry in
            let scope = entry.reference.ownerID.map { "account:\($0)" } ?? "local"
            counts[scope, default: 0] += 1
            return counts[scope, default: 0] <= 20
        }
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { NSLog("Playback history save failed: %@", error.localizedDescription) }
    }
}
