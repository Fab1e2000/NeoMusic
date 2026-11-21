import Foundation

actor PlaylistPersistence {
    func save<Value: Encodable & Sendable>(_ value: Value, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
