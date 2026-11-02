import XCTest
@testable import NeoMusic

final class LocalAudioMetadataReaderTests: XCTestCase {
    func testRepeatedCreditsAndMalformedComments() {
        func length(_ number: Int) -> Data { Data((0..<4).map { UInt8((number >> ($0 * 8)) & 255) }) }
        let entries = ["ARTIST=AC/DC", "ARTIST=Second Artist", "ALBUM_ARTIST=Album Credit", "TITLE=ignored"]
        var bytes = length(0) + length(entries.count)
        for entry in entries { let data = Data(entry.utf8); bytes += length(data.count) + data }
        XCTAssertEqual(LocalAudioMetadataReader.parseComments(bytes)["ARTIST"], ["AC/DC", "Second Artist"])
        XCTAssertEqual(LocalAudioMetadataReader.parseComments(bytes)["ALBUMARTIST"], ["Album Credit"])
        XCTAssertTrue(LocalAudioMetadataReader.parseComments(bytes.dropLast()).isEmpty)
        XCTAssertTrue(LocalAudioMetadataReader.parseComments(Data([255, 255, 255, 255])).isEmpty)
        var credits: [String] = []
        LocalAudioMetadataReader.appendCredits("AC/DC\0Second Artist\0AC/DC", to: &credits)
        XCTAssertEqual(credits, ["AC/DC", "Second Artist"])
        XCTAssertEqual(LocalAudioMetadataReader.number(" 7 / 12 "), 7)
        XCTAssertEqual(LocalAudioMetadataReader.number("-1"), 0)
    }

    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    func testCorruptFirstCoverFallsBackToValidFolderImage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not an image".utf8).write(to: root.appendingPathComponent("Cover.jpg"))
        let fallback = root.appendingPathComponent("Folder.PNG")
        try Self.png.write(to: fallback)
        XCTAssertEqual(LocalAudioMetadataReader.coverURL(in: root), fallback)
    }

    func testCaseInsensitiveCoverSelectionRejectsSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("Folder.PNG")
        try Self.png.write(to: image)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Cover.jpg"), withDestinationURL: image)
        XCTAssertEqual(LocalAudioMetadataReader.coverURL(in: root), image)
    }
}
