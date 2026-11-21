import Foundation

struct PlaybackQueueContinuation: Codable, Equatable, Sendable {
    let id: UUID
    let ownerID: String

    enum Kind: String, Codable { case recommendations }
    // Older saved continuations belong to the original radio queue.
    let kind: Kind?

    init(ownerID: String, id: UUID = UUID(), kind: Kind? = nil) {
        self.kind = kind
        self.id = id
        self.ownerID = ownerID
    }
}
