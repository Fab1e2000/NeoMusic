import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import NeoMusic

final class NeteaseAvatarSnapshotTests: XCTestCase, @unchecked Sendable {
    private let profile = NeteaseProfile(userID: 1, nickname: "Account A",
                                        avatarURL: URL(string: "https://avatar.invalid/a.png")!)

    func testNewStoreLoadsPersistedThumbnailWithBoundedDimensions() async throws {
        let file = try makeFileURL()
        let original = try makeImage(width: 768, height: 384)
        await NeteaseAvatarSnapshotStore(fileURL: file).save(original, for: profile)

        let restoredStore = NeteaseAvatarSnapshotStore(fileURL: file)
        let started = ProcessInfo.processInfo.systemUptime
        let restored = restoredStore.load()
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let snapshot = try XCTUnwrap(restored)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(snapshot.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertTrue(snapshot.belongs(to: profile))
        XCTAssertEqual(snapshot.avatarURL, profile.avatarURL)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        XCTAssertEqual(image.width, 192)
        XCTAssertEqual(image.height, 96)
        XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, 256 * 1024)
        print("NeteaseAvatarSnapshot load: \(elapsed) ms; thumbnail: \(snapshot.data.count) bytes")
    }

    func testSnapshotBelongsToItsAccountRegardlessOfNicknameOrAvatarURL() async throws {
        let file = try makeFileURL()
        let store = NeteaseAvatarSnapshotStore(fileURL: file)
        await store.save(try makeImage(width: 24, height: 24), for: profile)
        let snapshot = try XCTUnwrap(store.load())

        XCTAssertTrue(snapshot.belongs(to: NeteaseProfile(userID: profile.userID, nickname: "Renamed",
                                                          avatarURL: profile.avatarURL)))
        XCTAssertFalse(snapshot.belongs(to: NeteaseProfile(userID: 2, nickname: "Account B",
                                                           avatarURL: profile.avatarURL)))
        XCTAssertTrue(snapshot.belongs(to: NeteaseProfile(userID: profile.userID, nickname: profile.nickname,
                                                          avatarURL: URL(string: "https://avatar.invalid/updated.png")!)))
        XCTAssertTrue(snapshot.belongs(to: NeteaseProfile(userID: profile.userID, nickname: profile.nickname,
                                                          avatarURL: nil)))
    }

    func testInvalidImageDoesNotReplaceExistingSnapshot() async throws {
        let file = try makeFileURL()
        let store = NeteaseAvatarSnapshotStore(fileURL: file)
        await store.save(try makeImage(width: 64, height: 64), for: profile)
        let original = try XCTUnwrap(store.load())
        let other = NeteaseProfile(userID: 2, nickname: "Account B", avatarURL: profile.avatarURL)

        await store.save(Data("invalid image".utf8), for: other)

        XCTAssertEqual(store.load(), original)
    }

    func testCancelledSaveDoesNotReplaceExistingSnapshot() async throws {
        let file = try makeFileURL()
        let store = NeteaseAvatarSnapshotStore(fileURL: file)
        let image = try makeImage(width: 64, height: 64)
        await store.save(image, for: profile)
        let original = try XCTUnwrap(store.load())
        let other = NeteaseProfile(userID: 2, nickname: "Account B", avatarURL: profile.avatarURL)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.save(image, for: other)
        }
        await cancelled.value

        XCTAssertEqual(store.load(), original)
    }

    func testAccountReplacementAndClearAreVisibleToNewStores() async throws {
        let file = try makeFileURL()
        let store = NeteaseAvatarSnapshotStore(fileURL: file)
        let image = try makeImage(width: 64, height: 64)
        await store.save(image, for: profile)
        let other = NeteaseProfile(userID: 2, nickname: "Account B",
                                   avatarURL: URL(string: "https://avatar.invalid/b.png")!)

        await store.save(image, for: other)

        let snapshot = try XCTUnwrap(NeteaseAvatarSnapshotStore(fileURL: file).load())
        XCTAssertTrue(snapshot.belongs(to: other))
        XCTAssertFalse(snapshot.belongs(to: profile))
        XCTAssertEqual(snapshot.avatarURL, other.avatarURL)
        store.clear()
        XCTAssertNil(NeteaseAvatarSnapshotStore(fileURL: file).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        store.clear()
    }

    func testMissingMalformedAndOversizedFilesReturnNoSnapshot() throws {
        let file = try makeFileURL()
        let store = NeteaseAvatarSnapshotStore(fileURL: file)
        XCTAssertNil(store.load())
        try Data("invalid property list".utf8).write(to: file)
        XCTAssertNil(store.load())
        let oversized = NeteaseAvatarSnapshot(userID: profile.userID, avatarURL: profile.avatarURL!,
                                              data: Data(repeating: 0, count: 256 * 1024))
        try PropertyListEncoder().encode(oversized).write(to: file)

        XCTAssertNil(store.load())
    }

    func testFailedWriteRemainsACacheMiss() async throws {
        let file = try makeFileURL()
        try Data("a file cannot contain the cache directory".utf8).write(to: file)
        let store = NeteaseAvatarSnapshotStore(fileURL: file.appending(path: "snapshot.plist"))

        await store.save(try makeImage(width: 64, height: 64), for: profile)

        XCTAssertNil(store.load())
    }

    private func makeFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "NeteaseAvatarSnapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appending(path: "display.plist")
    }

    private func makeImage(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
