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
    private struct Entry: Codable, Equatable, Sendable {
        let reference: PlaybackCollectionReference
        let date: Date

        func refersToSameCollection(as other: Entry) -> Bool {
            reference.kind == other.reference.kind && reference.id == other.reference.id && reference.ownerID == other.reference.ownerID
        }
    }
    private var entries: [Entry] = []
    @ObservationIgnored private let storage: Storage?
    @ObservationIgnored private var restored: Bool
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(url: URL? = nil, loadData: @escaping @Sendable (URL) async throws -> Data = { try Data(contentsOf: $0) }) {
        storage = url.map { Storage(url: $0, loadData: loadData) }
        restored = url == nil
    }

    func restore() async {
        await startRestoration()?.value
    }

    private func startRestoration() -> Task<Void, Never>? {
        guard !restored else { return nil }
        if let restoreTask { return restoreTask }
        let task = Task { [self] in
            let saved = await storage?.load() ?? []
            let recorded = entries
            let merged = Self.trimmed(recorded + saved.filter { savedEntry in
                !recorded.contains { $0.refersToSameCollection(as: savedEntry) }
            })
            if entries != merged { entries = merged }
            restored = true
            restoreTask = nil
            if !recorded.isEmpty { scheduleSave() }
        }
        restoreTask = task
        return task
    }

    func recent(for ownerID: String?) -> [PlaybackCollectionReference] {
        Array(entries.filter { $0.reference.ownerID == nil || $0.reference.ownerID == ownerID }.prefix(20).map(\.reference))
    }

    func record(_ reference: PlaybackCollectionReference, at date: Date = Date()) {
        let entry = Entry(reference: reference, date: date)
        let next = Self.trimmed(entries.filter { !$0.refersToSameCollection(as: entry) } + [entry])
        guard entries != next else { return }
        entries = next
        if restored { scheduleSave() }
        else { _ = startRestoration() }
    }

    private static func trimmed(_ values: [Entry]) -> [Entry] {
        var counts: [String: Int] = [:]
        return values.sorted { $0.date > $1.date }.filter { entry in
            let scope = entry.reference.ownerID.map { "account:\($0)" } ?? "local"
            counts[scope, default: 0] += 1
            return counts[scope, default: 0] <= 20
        }
    }

    private func scheduleSave() {
        guard let storage else { return }
        let snapshot = entries
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            await storage.save(snapshot)
        }
    }

    /// Finish restoration and all snapshots submitted before this lifecycle checkpoint.
    func flush() async {
        await restore()
        await saveTask?.value
    }

    private actor Storage {
        let url: URL
        let loadData: @Sendable (URL) async throws -> Data

        init(url: URL, loadData: @escaping @Sendable (URL) async throws -> Data) {
            self.url = url
            self.loadData = loadData
        }

        func load() async -> [Entry] {
            guard let data = try? await loadData(url), let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
            return saved
        }

        func save(_ entries: [Entry]) {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            } catch { NSLog("Playback history save failed: %@", error.localizedDescription) }
        }
    }
}
