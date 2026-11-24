import Foundation

enum AtomicJSONStore {
    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value? {
        try Task.checkCancellation()
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try writeData(encode(value), to: url)
    }

    @concurrent static func readInBackground<Value: Decodable & Sendable>(_ type: Value.Type, from url: URL) async throws -> Value? {
        try read(type, from: url)
    }

    @concurrent static func writeInBackground<Value: Encodable & Sendable>(_ value: Value, to url: URL) async throws {
        try write(value, to: url)
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try Task.checkCancellation()
        return try JSONEncoder().encode(value)
    }

    static func writeData(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
