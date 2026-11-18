import Foundation

struct PlaybackCollectionReference: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case favorites, localAlbum, localPlaylist, onlinePlaylist, daily }
    let kind: Kind
    let id: String
    let ownerID: String?
    let title: String
}
