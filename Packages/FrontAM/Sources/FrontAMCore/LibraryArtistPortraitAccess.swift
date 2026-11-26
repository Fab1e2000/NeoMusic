import SwiftUI

public struct LibraryArtistPortraitAccess {
    public struct Snapshot: Equatable {
        public let session: UUID
        public let knownURL: URL?
        public let file: URL?

        public init(session: UUID, knownURL: URL? = nil, file: URL? = nil) {
            self.session = session
            self.knownURL = knownURL
            self.file = file
        }
    }

    public let snapshot: @MainActor (LibraryArtistIdentity) -> Snapshot?
    public let resolve: @MainActor (LibraryArtistIdentity, UUID) async -> Void

    public init(snapshot: @escaping @MainActor (LibraryArtistIdentity) -> Snapshot?,
                resolve: @escaping @MainActor (LibraryArtistIdentity, UUID) async -> Void) {
        self.snapshot = snapshot
        self.resolve = resolve
    }
}

public enum LibraryArtistIdentity: Hashable, Codable {
    case local(UUID)
    case catalog(id: String, ownerID: String?)

    public var itemID: String {
        switch self {
        case .local(let id): id.uuidString
        case .catalog(let id, _): id
        }
    }
}
