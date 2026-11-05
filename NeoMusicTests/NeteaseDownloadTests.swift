import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

final class NeteaseDownloadTests: XCTestCase, @unchecked Sendable {
    private struct Saved: Encodable {
        var records: [NeteaseDownloadRecord] = []
        var collections: [NeteaseDownloadCollection] = []
        var jobs: [NeteaseDownloadJob] = []
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func saved(_ id: Int64 = 1) throws -> NeteaseSavedSession {
        try .init(profile: .init(userID: id, nickname: "User", avatarURL: nil), credential: .init(musicU: "test-secret"))
    }
    private func song(_ id: Int64 = 12) -> NeteaseDownloadSong {
        .init(song: .init(id: id, title: "Song", artist: "Artist", album: "Album", artworkURL: nil, duration: 60, albumID: 3),
              albumArtist: "Album Artist", trackNumber: 2, discNumber: 1)
    }
    private func client(_ responses: [String]) -> NeteaseMusicClient {
        DownloadFixtureProtocol.state.withLock { $0 = .init(replies: responses) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        return NeteaseMusicClient(transport: NeteaseAccountClient(session: URLSession(configuration: configuration)))
    }
    @MainActor private func store(_ root: URL, responses: [String] = [], processor: NeteaseDownloadStore.Processor? = nil) -> NeteaseDownloadStore {
        let defaults = UserDefaults(suiteName: "download-tests-" + UUID().uuidString)!
        let configuration = URLSessionConfiguration.ephemeral
        let transport = NeteaseDownloadTransport(spool: root.appending(path: "Transfers"), configuration: configuration)
        return NeteaseDownloadStore(client: client(responses), directory: root, musicDirectory: root.appending(path: "Music"),
            defaults: defaults, transport: transport, process: processor ?? { file, _, _, staging in
                let output = staging.appending(path: "processed.flac")
                try FileManager.default.copyItem(at: file, to: output)
                return output
            })
    }
    private func persist(_ snapshot: Saved, root: URL) throws {
        try JSONEncoder().encode(snapshot).write(to: root.appending(path: "index.json"))
    }
    @MainActor private func account(downloads: NeteaseDownloadStore,
                                   read: @escaping @MainActor () async throws -> NeteaseSavedSession?) -> NeteaseAccount {
        NeteaseAccount(readSession: read, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in .init(userID: 1, nickname: "User", avatarURL: nil) },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {}, downloads: downloads)
    }
    private func stage(_ root: URL, owner: Int64 = 1, expectedSize: Int64? = nil) throws -> NeteaseDownloadJob {
        var job = NeteaseDownloadJob(id: UUID(), ownerID: owner, metadata: song(), requestedQuality: .lossless,
                                    actualQuality: .lossless, type: "flac", expectedSize: expectedSize)
        job.stagedFilename = job.id.uuidString + ".transfer"
        let spool = root.appending(path: "Transfers")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try Data("fLaC-fixture".utf8).write(to: spool.appending(path: job.stagedFilename!))
        return job
    }
    @MainActor func testDownloadDefaultsAndSettingsPersist() throws {
        let root = try directory(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        let transport = NeteaseDownloadTransport(spool: root, configuration: .ephemeral)
        let store = NeteaseDownloadStore(directory: root, defaults: defaults, transport: transport)
        XCTAssertEqual(store.quality, .lossless); XCTAssertTrue(store.allowsCellular)
        store.quality = .hiRes; store.allowsCellular = false
        XCTAssertEqual(defaults.string(forKey: "netease.download.quality"), "hires")
        XCTAssertFalse(defaults.bool(forKey: "netease.download.cellular"))
    }
    @MainActor func testConcurrentStartupRestorePublishesOneSnapshot() async throws {
        let root = try directory(), store = store(root)
        var publications = 0
        store.onRecordsChanged = { publications += 1 }
        async let first: Void = store.restore()
        async let second: Void = store.restore()
        _ = await (first, second)
        XCTAssertTrue(store.isRestored)
        XCTAssertEqual(publications, 1)
    }
    @MainActor func testTrialAndWrongIdentityFallBackToCompleteSource() async throws {
        let client = client([
            #"{"code":200,"data":{"id":12,"url":"https://example.com/trial","level":"hires","type":"ncm","freeTrialInfo":{}}}"#,
            #"{"code":200,"data":{"id":99,"url":"https://example.com/wrong","level":"lossless","type":"flac"}}"#,
            #"{"code":200,"data":{"id":12,"url":"http://example.com/song","level":"exhigh","type":"mp3","size":200}}"#
        ])
        let result = try await client.downloadSource(id: 12, quality: .hiRes, credential: saved().credential)
        XCTAssertEqual(result.quality, .high); XCTAssertEqual(result.url.scheme, "https"); XCTAssertEqual(result.size, 200)
        XCTAssertEqual(DownloadFixtureProtocol.state.withLock { $0.paths.count }, 3)
        XCTAssertTrue(DownloadFixtureProtocol.state.withLock { $0.paths.allSatisfy { $0.contains("/download/") } })
    }
    @MainActor func testUnavailableDownloadNeverFallsBackToPlayerEndpoint() async throws {
        let client = client([#"{"code":200,"data":null}"#])
        do { _ = try await client.downloadSource(id: 12, quality: .standard, credential: saved().credential); XCTFail() }
        catch { XCTAssertTrue(error is NeteaseDownloadError) }
        XCTAssertEqual(DownloadFixtureProtocol.state.withLock { $0.paths.count }, 1)
    }
    @MainActor func testSongPlanningReadsAllBatchesAndKeepsMissingIdentities() async throws {
        let client = client(Array(repeating: #"{"code":200,"songs":[]}"#, count: 3))
        let result = try await client.downloadSongs(ids: Array(1...201) + [1], credential: saved().credential)
        XCTAssertEqual(result.map(\.song.id), Array(1...201))
        XCTAssertTrue(result.allSatisfy(\.song.unavailable))
        XCTAssertEqual(DownloadFixtureProtocol.state.withLock { $0.paths.count }, 3)
    }
    @MainActor func testStagedBackgroundDownloadWaitsForAccountAndCommitsMetadata() async throws {
        let root = try directory(), job = try stage(root)
        try persist(Saved(jobs: [job]), root: root)
        let captured = Mutex<DownloadedAudioTags.Metadata?>(nil)
        let store = store(root, responses: [#"{"code":200,"lrc":{"lyric":"[00:01]Text"},"tlyric":{"lyric":"[00:01]翻译"}}"#]) { file, _, tags, staging in
            captured.withLock { $0 = tags }
            let output = staging.appending(path: "processed.flac")
            try FileManager.default.copyItem(at: file, to: output)
            return output
        }
        await store.restore()
        XCTAssertNil(store.resource(songID: 12)); XCTAssertTrue(DownloadFixtureProtocol.state.withLock { $0.paths.isEmpty })
        await store.activate(try saved()); await store.waitForProcessing()
        let file = try XCTUnwrap(store.resource(songID: 12))
        XCTAssertEqual(try Data(contentsOf: file), Data("fLaC-fixture".utf8))
        XCTAssertEqual(store.states[12], .downloaded)
        XCTAssertEqual(store.records[12]?.metadata.trackNumber, 2)
        XCTAssertEqual(store.records[12]?.ownerID, 1)
        XCTAssertEqual(captured.withLock { $0?.albumArtist }, "Album Artist")
        XCTAssertTrue(captured.withLock { $0?.lyrics?.contains("翻译") } == true)
        let index = try String(contentsOf: root.appending(path: "index.json"), encoding: .utf8)
        XCTAssertFalse(index.contains("test-secret")); XCTAssertFalse(index.contains("https://"))
        await store.activate(nil)
        XCTAssertEqual(store.resource(songID: 12), file)
        XCTAssertEqual(store.states[12], .downloaded)
    }
    @MainActor func testDifferentAccountCancelsRestoredTransferWithoutPublishing() async throws {
        let root = try directory(), job = try stage(root)
        try persist(Saved(jobs: [job]), root: root)
        let store = store(root)
        await store.restore(); await store.activate(try saved(2)); await store.waitForProcessing()
        XCTAssertTrue(store.records.isEmpty); XCTAssertNil(store.states[12])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Transfers/" + job.stagedFilename!).path))
    }
    @MainActor func testTruncatedTransferFailsWithoutPublishingFile() async throws {
        let root = try directory(), job = try stage(root, expectedSize: 999)
        try persist(Saved(jobs: [job]), root: root)
        let store = store(root)
        await store.restore(); await store.activate(try saved()); await store.waitForProcessing()
        XCTAssertNil(store.records[12]); XCTAssertNil(store.resource(songID: 12))
        guard case .failed = store.states[12] else { return XCTFail("Missing failure state") }
    }
    @MainActor func testRemovalRetainsCollectionAndUnrelatedLocalFile() async throws {
        let root = try directory(), job = try stage(root)
        let collection = NeteaseDownloadCollection(kind: .playlist, id: 55, ownerID: 1, title: "List", artist: "User", orderedSongIDs: [12])
        try persist(Saved(collections: [collection], jobs: [job]), root: root)
        let store = store(root, responses: [#"{"code":200}"#])
        await store.restore(); await store.activate(try saved()); await store.waitForProcessing()
        let file = try XCTUnwrap(store.resource(songID: 12))
        let unrelated = file.deletingLastPathComponent().appending(path: "imported.mp3")
        try Data("user-owned".utf8).write(to: unrelated)
        try await store.remove(songIDs: [12])
        XCTAssertNotNil(store.records[12]); XCTAssertNil(store.resource(songID: 12))
        XCTAssertEqual(store.collections[collection.key], collection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    @MainActor func testExternalDeletionRemovesDownloadedState() async throws {
        let root = try directory(), job = try stage(root)
        try persist(Saved(jobs: [job]), root: root)
        let store = store(root, responses: [#"{"code":200}"#])
        await store.restore(); await store.activate(try saved()); await store.waitForProcessing()
        let file = try XCTUnwrap(store.resource(songID: 12))
        try FileManager.default.removeItem(at: file)
        await store.reconcileFiles()
        XCTAssertNotNil(store.records[12]); XCTAssertNil(store.resource(songID: 12)); XCTAssertNil(store.states[12])
        var publications = 0
        store.onRecordsChanged = { publications += 1 }
        await store.reconcileFiles()
        XCTAssertEqual(publications, 0)
    }
    @MainActor func testRetainedProvenanceDoesNotSkipDownloadAfterFileRemoval() async throws {
        let root = try directory()
        let record = NeteaseDownloadRecord(metadata: song(), relativePath: "网易云/Album [3]/01 Song [12].flac",
            lyricsRelativePath: nil, quality: .lossless, downloadedAt: Date(), ownerID: 1)
        try persist(Saved(records: [record]), root: root)
        let store = store(root, responses: [
            #"{"code":200,"songs":[{"id":12,"name":"Song","ar":[{"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":60000,"no":2}]}"#,
            #"{"code":200,"album":{"id":3,"name":"Album","size":1},"songs":[{"id":12,"name":"Song","ar":[{"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":60000}]}"#,
            #"{"code":200,"data":null}"#, #"{"code":200,"data":null}"#, #"{"code":200,"data":null}"#
        ])
        await store.restore(); await store.activate(try saved())
        try await store.enqueue(songIDs: [12]); await store.waitForProcessing()
        XCTAssertEqual(store.records[12], record); XCTAssertNil(store.resource(songID: 12))
        guard case .failed = store.states[12] else { return XCTFail("Expected real download attempt") }
        XCTAssertEqual(DownloadFixtureProtocol.state.withLock { $0.paths.filter { $0.contains("/download/") }.count }, 3)
    }
    @MainActor func testStopCollectionCancelsMetadataPlanningBeforeJobsPublish() async throws {
        let root = try directory(), store = store(root)
        await store.restore(); await store.activate(try saved())
        let started = expectation(description: "playlist metadata requested")
        DownloadFixtureProtocol.state.withLock { value in
            value.holdNext = true
            value.onRequest = { started.fulfill() }
        }
        let request = Task { try await store.enqueuePlaylist(id: 55) }
        await fulfillment(of: [started], timeout: 2)
        await store.stopCollection(key: "playlist:55")
        switch await request.result {
        case .success: XCTFail("Cancelled planning completed")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        await store.waitForProcessing()
        XCTAssertTrue(store.states.isEmpty); XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertNil(store.collections["playlist:55"])
        XCTAssertEqual(DownloadFixtureProtocol.state.withLock { $0.paths.count }, 1)
    }
    @MainActor func testConcurrentSameSongRequestsSharePlanningAndTransferAttempt() async throws {
        let root = try directory()
        let store = store(root, responses: [
            #"{"code":200,"songs":[{"id":12,"name":"Song","ar":[{"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":60000}]}"#,
            #"{"code":200,"album":{"id":3,"name":"Album","size":1},"songs":[{"id":12,"name":"Song","ar":[{"name":"Artist"}],"al":{"id":3,"name":"Album"},"dt":60000}]}"#,
            #"{"code":200,"data":null}"#, #"{"code":200,"data":null}"#, #"{"code":200,"data":null}"#
        ])
        await store.restore(); await store.activate(try saved())
        async let first: Void = store.enqueue(songIDs: [12, 12])
        async let second: Void = store.enqueue(songIDs: [12])
        _ = try await (first, second)
        await store.waitForProcessing()
        let paths = DownloadFixtureProtocol.state.withLock { $0.paths }
        XCTAssertEqual(paths.filter { $0.contains("/v3/song/detail") }.count, 1)
        XCTAssertEqual(paths.filter { $0.contains("/download/") }.count, 3)
        XCTAssertEqual(store.states.count, 1)
    }
    @MainActor func testAccountCredentialReadFailurePreservesDownloadJobsAndFiles() async throws {
        let root = try directory(), job = try stage(root)
        let path = "网易云/Album [3]/01 Existing [99].flac"
        let file = root.appending(path: "Music/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing-audio".utf8).write(to: file)
        let record = NeteaseDownloadRecord(metadata: song(99), relativePath: path, lyricsRelativePath: nil,
                                           quality: .lossless, downloadedAt: Date(), ownerID: 1)
        try persist(Saved(records: [record], jobs: [job]), root: root)
        let originalIndex = try Data(contentsOf: root.appending(path: "index.json"))
        let store = store(root)
        await store.restore()
        let account = account(downloads: store) { throw NeteaseAccountError.keychain(-25308) }
        await account.restoreCachedContent()
        XCTAssertEqual(account.restoredPlaybackIdentity, .pending)
        XCTAssertEqual(store.states[12], .queued)
        XCTAssertEqual(store.records[99], record); XCTAssertEqual(store.resource(songID: 99), file)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "index.json")), originalIndex)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Transfers/" + job.stagedFilename!).path))
    }
    @MainActor func testAccountLogoutCancelsProcessingAndKeepsOfflineFile() async throws {
        let root = try directory(), job = try stage(root), gate = DownloadProcessingGate()
        let path = "网易云/Album [3]/01 Existing [99].flac"
        let file = root.appending(path: "Music/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing-audio".utf8).write(to: file)
        let record = NeteaseDownloadRecord(metadata: song(99), relativePath: path, lyricsRelativePath: nil,
                                           quality: .lossless, downloadedAt: Date(), ownerID: 1)
        try persist(Saved(records: [record], jobs: [job]), root: root)
        let store = store(root, responses: [#"{"code":200}"#]) { source, _, _, staging in
            await gate.pause()
            let output = staging.appending(path: "late.flac")
            try FileManager.default.copyItem(at: source, to: output)
            return output
        }
        let session = try saved()
        let account = account(downloads: store) { session }
        await account.restoreCachedContent(); await gate.waitUntilStarted()
        let logout = Task { try await account.logout() }
        while store.userID != nil { await Task.yield() }
        await gate.open(); try await logout.value
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedOut)
        XCTAssertNil(store.states[12]); XCTAssertNil(store.records[12])
        XCTAssertEqual(store.records[99], record); XCTAssertEqual(store.resource(songID: 99), file)
        XCTAssertEqual(try Data(contentsOf: file), Data("existing-audio".utf8))
    }
    @MainActor func testCorruptIndexDoesNotOverwriteSavedData() async throws {
        let root = try directory(), original = Data("broken-index".utf8)
        try original.write(to: root.appending(path: "index.json"))
        let store = store(root)
        await store.restore(); await store.activate(try saved())
        XCTAssertFalse(store.isRestored); XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "index.json")), original)
    }
    @MainActor func testAccountSwitchWaitsForProcessingAndRejectsLateResult() async throws {
        let root = try directory(), job = try stage(root), gate = DownloadProcessingGate()
        try persist(Saved(jobs: [job]), root: root)
        let store = store(root, responses: [#"{"code":200}"#]) { file, _, _, staging in
            await gate.pause()
            let output = staging.appending(path: "late.flac")
            try FileManager.default.copyItem(at: file, to: output)
            return output
        }
        await store.restore(); await store.activate(try saved()); await gate.waitUntilStarted()
        let replacement = try saved(2)
        let switchTask = Task { await store.activate(replacement) }
        while store.userID != 2 { await Task.yield() }
        await gate.open(); await switchTask.value
        XCTAssertEqual(store.userID, 2); XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(store.resource(songID: 12)); XCTAssertNil(store.states[12])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Processing/" + job.id.uuidString).path))
    }
    @MainActor func testStoppingProcessingRetainsExistingCompletedFiles() async throws {
        let root = try directory(), job = try stage(root), gate = DownloadProcessingGate()
        let path = "网易云/Other [4]/01 Existing [99].flac"
        let existingURL = root.appending(path: "Music/" + path)
        try FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: existingURL)
        let record = NeteaseDownloadRecord(metadata: song(99), relativePath: path, lyricsRelativePath: nil, quality: .high, downloadedAt: Date())
        try persist(Saved(records: [record], jobs: [job]), root: root)
        let store = store(root, responses: [#"{"code":200}"#]) { file, _, _, staging in
            await gate.pause()
            let output = staging.appending(path: "late.flac")
            try FileManager.default.copyItem(at: file, to: output)
            return output
        }
        await store.restore(); await store.activate(try saved()); await gate.waitUntilStarted()
        let stop = Task { await store.stop(songIDs: [12, 99]) }
        await Task.yield(); await gate.open(); await stop.value
        XCTAssertNil(store.records[12]); XCTAssertEqual(store.records[99], record)
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("existing".utf8))
    }
}

private actor DownloadProcessingGate {
    var started = false
    var waitingForStart: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true; waitingForStart?.resume(); waitingForStart = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waitingForStart = $0 }
    }
    func open() { release?.resume(); release = nil }
}

private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var replies: [String]
        var paths: [String] = []
        var holdNext = false
        var onRequest: (@Sendable () -> Void)?
    }
    static let state = Mutex(State(replies: []))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (response, callback) = Self.state.withLock { value -> (String?, (@Sendable () -> Void)?) in
            value.paths.append(request.url?.path ?? "")
            if value.holdNext { value.holdNext = false; return (nil, value.onRequest) }
            return (value.replies.isEmpty ? #"{"code":200}"# : value.replies.removeFirst(), value.onRequest)
        }
        callback?()
        guard let response else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
