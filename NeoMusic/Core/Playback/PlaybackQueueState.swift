import Foundation

/// Identifies an account-owned queue that can request further songs.
struct PlaybackQueueContinuation: Codable, Equatable, Sendable {
    let id: UUID
    let ownerID: String

    init(ownerID: String, id: UUID = UUID()) {
        self.id = id
        self.ownerID = ownerID
    }
}
