import Foundation

/// File identities and queue-entry identities are distinct: one file may occur more than once.
struct PlaybackQueueState: Codable, Equatable {
    enum Mode: String, Codable { case off, all, one }
    var ids: [String]
    var index: Int
    var elapsed: Double
    var repeatMode: Mode
    var shuffled: Bool
    var source: String?
    var entryIDs: [UUID]?
    var originalOrder: [UUID]?
    var userQueuedIDs: Set<UUID>?

    init(ids: [String] = []) {
        self.ids = ids
        index = 0; elapsed = 0; repeatMode = .all; shuffled = false
        entryIDs = ids.map { _ in UUID() }
        originalOrder = entryIDs
        userQueuedIDs = []
    }

    mutating func normalize() {
        if entryIDs?.count != ids.count || Set(entryIDs ?? []).count != ids.count {
            entryIDs = ids.map { _ in UUID() }
        }
        let entries = entryIDs ?? []
        let existing = Set(entries)
        var seen: Set<UUID> = []
        originalOrder = ((originalOrder ?? []) + entries).filter { existing.contains($0) && seen.insert($0).inserted }
        userQueuedIDs = (userQueuedIDs ?? []).intersection(existing)
        index = min(max(0, index), max(0, ids.count - 1))
        elapsed = elapsed.isFinite ? max(0, elapsed) : 0
    }

    var nextIndex: Int? {
        guard !ids.isEmpty else { return nil }
        if repeatMode == .one { return index }
        if index + 1 < ids.count { return index + 1 }
        return repeatMode == .all ? 0 : nil
    }

    mutating func setShuffle(_ enabled: Bool) {
        normalize()
        guard enabled != shuffled, let entries = entryIDs else { return }
        let current = entries.indices.contains(index) ? entries[index] : nil
        let pairs = Array(zip(entries, ids))
        let order = Dictionary(uniqueKeysWithValues: (originalOrder ?? entries).enumerated().map { ($1, $0) })
        let arranged = enabled ? pairs.shuffled() : pairs.sorted { order[$0.0, default: 0] < order[$1.0, default: 0] }
        entryIDs = arranged.map(\.0); ids = arranged.map(\.1)
        index = current.flatMap { entryIDs?.firstIndex(of: $0) } ?? 0
        shuffled = enabled
    }

    mutating func append(_ id: String, next: Bool) {
        normalize()
        let entry = UUID(), insertion = next && !ids.isEmpty ? index + 1 : ids.count
        ids.insert(id, at: insertion); entryIDs?.insert(entry, at: insertion)
        originalOrder?.append(entry); userQueuedIDs?.insert(entry)
    }

    mutating func removeUpcoming(_ entry: UUID) {
        normalize()
        guard let position = entryIDs?.firstIndex(of: entry), position > index else { return }
        ids.remove(at: position); entryIDs?.remove(at: position)
        originalOrder?.removeAll { $0 == entry }; userQueuedIDs?.remove(entry)
    }

    mutating func moveUpcoming(_ entry: UUID, before target: UUID) {
        normalize()
        guard let from = entryIDs?.firstIndex(of: entry), let to = entryIDs?.firstIndex(of: target), from > index, to > index, from != to else { return }
        let song = ids.remove(at: from)
        entryIDs?.remove(at: from)
        let destination = from < to ? to - 1 : to
        ids.insert(song, at: destination); entryIDs?.insert(entry, at: destination)
        if !shuffled { originalOrder = entryIDs }
    }

    static func restore(from url: URL) throws -> Self {
        var state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        state.normalize()
        return state
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
