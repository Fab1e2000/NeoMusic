import Foundation
import FrontAMPlayer

extension PlayerAudioQuality {
    static func localFile(_ url: URL) -> Self? {
        let ext = url.pathExtension.lowercased()
        guard ["mp3", "wav", "flac", "aac", "alac", "aiff", "aif", "m4a"].contains(ext) else { return nil }
        return Self(title: ext == "aif" ? "AIFF" : ext.uppercased(), isLocalFormat: true)
    }
}

extension LibraryToast {
    init(_ notice: PlayerNotice) {
        switch notice {
        case .favorited: self = .favorited
        case .unfavorited: self = .unfavorited
        case .playingNext: self = .playingNext
        case .addedToQueue: self = .addedToQueue
        }
    }
}
