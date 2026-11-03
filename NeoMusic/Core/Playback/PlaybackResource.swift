import Foundation

struct PlaybackResource: Sendable {
    let url: URL
    var expiresAt: Date? = nil
    var quality: String? = nil
}
