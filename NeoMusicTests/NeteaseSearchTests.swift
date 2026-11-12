import Foundation
import Synchronization
import XCTest
@testable import NeoMusic

@MainActor final class NeteaseSearchTests: XCTestCase {
    func testCombinedKeepsServerOrderFiltersUnknownAndDeduplicatesIdentities() throws {
        let data = Data(#"{"code":200,"result":{"order":["voice","artist","song","album","song","playList"],"artist":{"artists":[{"id":2,"name":"Artist"}],"more":true},"song":{"songs":[{"id":1,"name":"Song","ar":[],"dt":1000},{"id":1,"name":"Duplicate"}]},"album":{"albums":[{"id":1,"name":"Album"}]},"playList":{"playLists":[]}}}"#.utf8)
        let page = try NeteaseSearchClient.parse(data, kind: .combined, offset: 0)
        XCTAssertEqual(page.groups.map(\.kind), [.artist, .song, .album])
        XCTAssertEqual(page.groups.flatMap(\.items).map(\.id), ["100:2", "1:1", "10:1"])
        XCTAssertFalse(page.hasMore)
        XCTAssertTrue(page.groups[0].hasMore)
    }
    func testLegacySongShapeAndEmptyPagination() throws {
        let data = Data(#"{"code":200,"result":{"songs":[{"id":7,"name":"Song","artists":[{"id":8,"name":"Artist"}],"album":{"id":9,"name":"Album","picUrl":"http://example.com/a.jpg"},"duration":123000}],"songCount":32}}"#.utf8)
        let page = try NeteaseSearchClient.parse(data, kind: .song, offset: 30)
        let song = try XCTUnwrap(page.groups.first?.items.first?.song)
        XCTAssertEqual(song.artist, "Artist"); XCTAssertEqual(song.albumID, 9); XCTAssertEqual(song.duration, 123)
        XCTAssertEqual(song.artworkURL?.scheme, "https"); XCTAssertEqual(page.nextOffset, 31); XCTAssertTrue(page.hasMore)
        let empty = try NeteaseSearchClient.parse(Data(#"{"code":200,"result":{"songs":[],"hasMore":true}}"#.utf8), kind: .song, offset: 31)
        XCTAssertFalse(empty.hasMore)
        XCTAssertThrowsError(try NeteaseSearchClient.parse(Data(#"{"code":503}"#.utf8), kind: .song, offset: 0))
    }
    func testPaginationPreservesOrderAndStopsOnRepeatedResources() {
        let a = page([1, 2], offset: 2), b = page([2, 3], offset: 4)
        let merged = NeteaseSearchStore.merging(a, b)
        XCTAssertEqual(merged.groups[0].items.map(\.resourceID), [1, 2, 3]); XCTAssertTrue(merged.hasMore)
        XCTAssertFalse(NeteaseSearchStore.merging(merged, page([1, 2, 3], offset: 7)).hasMore)
        XCTAssertFalse(NeteaseSearchStore.merging(a, page([3], offset: 2)).hasMore)
    }
    func testGuestRequestsUseSearchProfileWithoutCredentials() throws {
        let transport = NeteaseAccountClient()
        let request = try transport.makeRequest(credential: nil, path: "/api/search/get", fields: ["s": "test"], profile: .search)
        XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.contains("os=ios") == true)
        XCTAssertFalse(request.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U") == true)
        let suggest = try transport.makeWebRequest(path: "/api/search/suggest/keyword", fields: ["s": "test"], credential: nil)
        XCTAssertFalse(suggest.value(forHTTPHeaderField: "Cookie")?.contains("MUSIC_U") == true)
    }
    func testDetailCompletionRetainsSearchOrderAndPartialFailureKeepsResults() async throws {
        let (client, network) = client(responses: ["/eapi/search/get": [Data(#"{"code":200,"result":{"songs":[{"id":2,"name":"Second"},{"id":1,"name":"First"}],"songCount":2}}"#.utf8)],
            "/eapi/v3/song/detail": [songs([1, 2])]])
        defer { network.invalidateAndCancel() }
        let page = try await client.search("test", kind: .song, credential: nil)
        XCTAssertEqual(page.groups[0].items.map(\.resourceID), [2, 1])
        XCTAssertEqual(page.groups[0].items[0].song?.duration, 60)
        SearchFixtureProtocol.state.withLock { $0.responses["/eapi/v3/song/detail"] = [Data(#"{"code":503}"#.utf8)] }
        let partial = try await client.search("test", kind: .song, credential: nil)
        XCTAssertEqual(partial.groups[0].items.map(\.title), ["Second", "First"])
    }
    func testQueryCacheRefreshFailureAndAccountHistoryIsolation() async throws {
        let response = Data(#"{"code":200,"result":{"artists":[{"id":1,"name":"Artist"}],"artistCount":1}}"#.utf8)
        let (client, network) = client(responses: ["/eapi/search/get": [response]])
        defer { network.invalidateAndCancel() }
        let suite = "search-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NeteaseSearchStore(client: client, defaults: defaults)
        await store.setSession(owner: 1, credential: nil)
        for index in 0..<25 { store.record("Query \(index)", scope: "online") }
        XCTAssertEqual(store.history.count, 20); XCTAssertEqual(store.history.first, "Query 24")
        store.record("Query 23", scope: "online"); XCTAssertEqual(store.history.first, "Query 23")
        await store.search("test", kind: .artist)
        await store.search("test", kind: .artist)
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts["/eapi/search/get"] }, 1)
        SearchFixtureProtocol.state.withLock { $0.responses["/eapi/search/get"] = [Data(#"{"code":503}"#.utf8)] }
        await store.search("test", kind: .artist, force: true)
        XCTAssertNotNil(store.error); XCTAssertEqual(store.page?.groups[0].items[0].title, "Artist")
        await store.setSession(owner: 2, credential: nil)
        XCTAssertTrue(store.history.isEmpty); XCTAssertNil(store.page)
        await store.setSession(owner: 1, credential: nil)
        XCTAssertEqual(store.history.first, "Query 23")
    }

    func testCategoryOrderCachePaginationAndFailureRetention() async throws {
        func lists(_ ids: [Int]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["code": 200, "more": true,
                "playlists": ids.map { ["id": $0, "name": "List \($0)"] }])
        }
        let (client, network) = client(responses: [
            "/eapi/playlist/catalogue": [Data(#"{"code":200,"sub":[{"name":"风格","category":1,"hot":false},{"name":"热门","category":3,"hot":true},{"name":"语种","category":0},{"name":"热门","category":3,"hot":true}]}"#.utf8)],
            "/eapi/playlist/list": [try lists([1, 2]), try lists([2, 3]), try lists([3])]
        ])
        defer { network.invalidateAndCancel() }
        let store = NeteaseSearchStore(client: client)
        await store.loadCategories(); await store.loadCategories()
        XCTAssertEqual(store.categories.map(\.name), ["热门", "语种", "风格"])
        XCTAssertEqual(store.categories.map(\.group), [3, 0, 1])
        XCTAssertEqual(store.categories.map(\.isHot), [true, false, false])
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts["/eapi/playlist/catalogue"] }, 1)
        await store.openCategory("流行")
        await store.loadMoreCategory()
        XCTAssertEqual(store.categoryPage?.groups.first?.items.map(\.resourceID), [1, 2, 3])
        await store.loadMoreCategory()
        XCTAssertEqual(store.categoryPage?.hasMore, false)
        await store.openCategory("民谣"); await store.openCategory("流行")
        XCTAssertEqual(store.categoryPage?.groups.first?.items.map(\.resourceID), [1, 2, 3])
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts["/eapi/playlist/list"] }, 4)
        SearchFixtureProtocol.state.withLock { $0.responses["/eapi/playlist/list"] = [Data(#"{"code":503}"#.utf8)] }
        await store.openCategory("流行", force: true)
        XCTAssertNotNil(store.categoryError)
        XCTAssertEqual(store.categoryPage?.groups.first?.items.map(\.resourceID), [1, 2, 3])
        await store.setSession(owner: 2, credential: nil)
        XCTAssertTrue(store.categories.isEmpty); XCTAssertNil(store.categoryPage); XCTAssertNil(store.category)
    }

    func testCategoryMetadataProjectsIntoStableHotAndSemanticSections() {
        let source: [NeteaseSearchCategory] = [
            .init(name: "摇滚", group: 1, isHot: true),
            .init(name: "影视原声", group: 4, isHot: false),
            .init(name: "华语", group: 0, isHot: true),
            .init(name: "夜晚", group: 2, isHot: false),
            .init(name: "怀旧", group: 3, isHot: false),
            .init(name: "古典", group: 1, isHot: false),
            .init(name: "新分类", group: 8, isHot: false)
        ]
        let projected = SearchMusicIntegration.categoryItems(source)
        XCTAssertEqual(projected.map(\.id), source.map(\.id))
        XCTAssertEqual(projected.map(\.group), source.map { Optional($0.group) })
        XCTAssertEqual(projected.map(\.isHot), source.map(\.isHot))
        XCTAssertEqual(projected.map(\.colorIndex), Array(source.indices))

        let sections = MusicSearchCategorySection.sections(for: projected)
        XCTAssertEqual(sections.map(\.id), ["hot", "group:0", "group:1", "group:2", "group:3", "group:4", "other"])
        XCTAssertEqual(sections.map(\.title), ["热门", "语种", "风格", "场景", "情感", "主题", "其他"])
        XCTAssertEqual(sections[0].items.map(\.id), ["摇滚", "华语"])
        XCTAssertEqual(sections[2].items.map(\.id), ["摇滚", "古典"])
        XCTAssertEqual(sections.last?.items.map(\.id), ["新分类"])
        XCTAssertEqual(Set(sections.dropFirst().flatMap(\.items).map(\.id)), Set(projected.map(\.id)))
    }

    func testCategoriesWithoutGroupMetadataRetainFlatPresentation() {
        let items = [MusicSearchCategory(id: "流行", title: "流行"),
                     MusicSearchCategory(id: "民谣", title: "民谣", colorIndex: 1)]
        let sections = MusicSearchCategorySection.sections(for: items)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.id, "all")
        XCTAssertNil(sections.first?.title)
        XCTAssertEqual(sections.first?.items, items)
        XCTAssertTrue(MusicSearchCategorySection.sections(for: []).isEmpty)
    }

    func testCategoryForegroundMeetsNormalTextContrastAcrossCurrentPalette() {
        XCTAssertEqual(SearchCategoryColor.palette.count, 7)
        for color in SearchCategoryColor.palette {
            XCTAssertGreaterThanOrEqual(color.contrast, 4.5)
            XCTAssertTrue(color.usesDarkForeground)
        }
        let dark = SearchCategoryColor(red: 0.1, green: 0.1, blue: 0.1)
        XCTAssertFalse(dark.usesDarkForeground)
        XCTAssertGreaterThanOrEqual(dark.contrast, 4.5)
    }

    func testIndexPersistsFullMembershipAndSharedSongSurvivesCollectionRemoval() async throws {
        let root = directory(), index = NeteaseLibrarySearchIndex(directory: root)
        let session = NeteaseLibrarySearchIndex.Session(owner: "1", revision: UUID())
        await index.activate(session)
        try await index.replace(collection: "playlist:1", version: "1", resources: [resource(1), resource(2)], session: session)
        try await index.replace(collection: "album:1", version: "1", resources: [resource(2), resource(3)], session: session)
        try await index.reconcile(prefix: "playlist:", keeping: [], session: session)
        let reopened = NeteaseLibrarySearchIndex(directory: root)
        await reopened.activate(session)
        let result = try await reopened.search("Song", session: session)
        XCTAssertEqual(result.map(\.resourceID), [2, 3])
        try await reopened.replace(collection: "album:1", version: "2", resources: [], session: session)
        let empty = try await reopened.search("Song", session: session)
        XCTAssertTrue(empty.isEmpty)
    }
    func testIndexRankingAlbumMatchAndAccountSwitchRejectLateWrite() async throws {
        let index = NeteaseLibrarySearchIndex(directory: directory())
        let first = NeteaseLibrarySearchIndex.Session(owner: "1", revision: UUID())
        await index.activate(first)
        let items = [resource(1, title: "My song"), resource(2, title: "Song title"), resource(3, title: "SONG")]
        try await index.replace(collection: "liked", version: "", resources: items, session: first)
        let result = try await index.search("song", session: first)
        XCTAssertEqual(result.map(\.resourceID), [3, 2, 1])
        let albumMatch = try await index.search("Release", session: first)
        XCTAssertEqual(albumMatch.count, 3)
        let second = NeteaseLibrarySearchIndex.Session(owner: "2", revision: UUID())
        await index.activate(second)
        do { try await index.replace(collection: "liked", version: "", resources: [], session: first); XCTFail("Late write succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let other = try await index.search("song", session: second); XCTAssertTrue(other.isEmpty)
        await index.activate(first)
        let original = try await index.search("song", session: first); XCTAssertEqual(original.count, 3)
    }
    func testCancelledIndexUpdateKeepsPreviousCollection() async throws {
        let index = NeteaseLibrarySearchIndex(directory: directory())
        let session = NeteaseLibrarySearchIndex.Session(owner: "1", revision: UUID())
        await index.activate(session)
        try await index.replace(collection: "liked", version: "1", resources: [resource(1)], session: session)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await index.replace(collection: "liked", version: "2", resources: [], session: session)
        }
        do { try await task.value; XCTFail("Cancelled update succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        let result = try await index.search("Song", session: session); XCTAssertEqual(result.count, 1)
    }
    func testCompleteLibrarySyncIncludesUnopenedCollectionAndPreservesFailedCollection() async throws {
        let ids = (1...205).map(Int64.init)
        let detail: [String: Any] = ["code": 200, "playlist": ["id": 10, "name": "Collection", "creator": ["userId": 1, "nickname": "User"], "trackCount": ids.count, "trackIds": ids.map { ["id": $0] }]]
        let responses: [String: [Data]] = [
            "/eapi/user/playlist": [Data(#"{"code":200,"playlist":[{"id":10,"name":"Collection","creator":{"userId":1,"nickname":"User"},"trackCount":205,"updateTime":1000}],"more":false}"#.utf8)],
            "/eapi/v6/playlist/detail": [try JSONSerialization.data(withJSONObject: detail)],
            "/eapi/v3/song/detail": [songs(Array(ids.prefix(100))), songs(Array(ids[100..<200])), songs(Array(ids.suffix(5)))],
            "/eapi/album/sublist": [Data(#"{"code":200,"data":[],"hasMore":false}"#.utf8)],
            "/eapi/artist/sublist": [Data(#"{"code":200,"data":[{"id":9,"name":"Collected artist"}],"hasMore":false}"#.utf8)],
            "/eapi/song/like/get": [Data(#"{"code":200,"ids":[1,2]}"#.utf8)]
        ]
        let (client, network) = client(responses: responses)
        defer { network.invalidateAndCancel() }
        let store = NeteaseLibrarySearchStore(client: .init(transport: client.transport), directory: directory())
        let credential = try NeteaseCredential(musicU: "fixture", csrf: nil)
        await store.setSession(owner: 1, credential: credential)
        await store.synchronize()
        XCTAssertTrue(store.failedCollections.isEmpty, "\(store.failedCollections)")
        let last = try await store.search("Song 205", kind: .song)
        XCTAssertEqual(last.map(\.resourceID), [205])
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts["/eapi/v3/song/detail"] }, 3)
        SearchFixtureProtocol.state.withLock { $0.responses["/eapi/v6/playlist/detail"] = [Data(#"{"code":503}"#.utf8)] }
        await store.synchronize(force: true)
        XCTAssertTrue(store.failedCollections.contains("playlist:10"))
        let retained = try await store.search("Song 205"); XCTAssertEqual(retained.count, 1)
        await store.setSession(owner: nil, credential: nil)
        let signedOut = try await store.search("Song"); XCTAssertTrue(signedOut.isEmpty)
    }

    func testSameSessionKeepsQueryCacheAndIndexReadiness() async throws {
        let response = Data(#"{"code":200,"result":{"artists":[{"id":1,"name":"Artist"}],"artistCount":1}}"#.utf8)
        let (client, network) = client(responses: ["/eapi/search/get": [response]])
        defer { network.invalidateAndCancel() }
        let store = NeteaseSearchStore(client: client)
        await store.setSession(owner: 1, credential: nil)
        await store.search("test", kind: .artist)
        let session = store.sessionID
        await store.setSession(owner: 1, credential: nil)
        XCTAssertEqual(store.sessionID, session)
        XCTAssertEqual(store.page?.groups.first?.items.first?.resourceID, 1)
        let index = NeteaseLibrarySearchStore(directory: directory())
        await index.setSession(owner: 1, credential: nil)
        let revision = index.revision
        await index.setSession(owner: 1, credential: nil)
        XCTAssertEqual(index.revision, revision)
        await store.setSession(owner: 2, credential: nil)
        XCTAssertNil(store.page)
        XCTAssertNotEqual(store.sessionID, session)
    }

    func testCancelledSearchActivationKeepsGuestHistory() async {
        let suite = "search-session-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Guest query"], forKey: "search.history.guest.online")
        defaults.set(["Account query"], forKey: "search.history.1.online")
        let store = NeteaseSearchStore(defaults: defaults)
        let sessionID = store.sessionID
        let activation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.setSession(owner: 1, credential: nil)
        }
        await activation.value
        XCTAssertEqual(store.history, ["Guest query"])
        XCTAssertEqual(store.sessionID, sessionID)
        store.record("Another guest query", scope: "online")
        XCTAssertEqual(defaults.stringArray(forKey: "search.history.1.online"), ["Account query"])
        XCTAssertEqual(defaults.stringArray(forKey: "search.history.guest.online")?.first, "Another guest query")
    }

    func testCancelledLibraryActivationRetainsStableOwner() async throws {
        let store = NeteaseLibrarySearchStore(directory: directory())
        let saved = NeteaseLibrarySearchIndex.Session(owner: "1", revision: UUID())
        await store.index.activate(saved)
        try await store.index.replace(collection: "liked", version: "", resources: [resource(1)], session: saved)
        await store.setSession(owner: 1, credential: nil)
        let revision = store.revision
        let activation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.setSession(owner: 2, credential: nil)
        }
        await activation.value
        let result = try await store.search("Song 1")
        XCTAssertEqual(result.map(\.resourceID), [1])
        XCTAssertEqual(store.revision, revision)
    }

    func testLogoutJoinsSynchronizationCancelledBeforeItStarts() async throws {
        let store = NeteaseLibrarySearchStore(directory: directory())
        await store.setSession(owner: 1, credential: try .init(musicU: "fixture"))
        let finished = expectation(description: "Cancelled synchronization joined")
        let logout = Task {
            store.scheduleSynchronization()
            await store.setSession(owner: nil, credential: nil)
            finished.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(result, .completed)
        if result == .completed {
            await logout.value
            XCTAssertFalse(store.isSyncing)
        } else {
            logout.cancel()
        }
    }

    func testOverlappingLibraryRestorationAndLogoutStaysSignedOut() async throws {
        let store = NeteaseLibrarySearchStore(directory: directory())
        let saved = NeteaseLibrarySearchIndex.Session(owner: "1", revision: UUID())
        await store.index.activate(saved)
        try await store.index.replace(collection: "liked", version: "", resources: [resource(1)], session: saved)
        await store.index.activate(nil)
        let gate = SearchIndexExecutorGate(entered: expectation(description: "Index executor occupied"))
        defer { gate.release.signal() }
        let occupied = Task { await store.index.holdExecutor(using: gate) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let restoring = expectation(description: "Account restoration requested")
        let activation = Task {
            restoring.fulfill()
            await store.setSession(owner: 1, credential: nil)
        }
        await fulfillment(of: [restoring], timeout: 2)
        let exiting = expectation(description: "Logout requested")
        let logout = Task {
            exiting.fulfill()
            await store.setSession(owner: nil, credential: nil)
        }
        await fulfillment(of: [exiting], timeout: 2)
        gate.release.signal()
        await occupied.value
        await activation.value
        await logout.value
        let result = try await store.search("Song 1")
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(store.isSyncing)
    }

    func testCancelledPendingLibraryActivationDoesNotPublishItsOwner() async throws {
        let store = NeteaseLibrarySearchStore(directory: directory())
        let saved = NeteaseLibrarySearchIndex.Session(owner: "1", revision: UUID())
        await store.index.activate(saved)
        try await store.index.replace(collection: "liked", version: "", resources: [resource(1)], session: saved)
        await store.index.activate(nil)
        let gate = SearchIndexExecutorGate(entered: expectation(description: "Index executor occupied"))
        defer { gate.release.signal() }
        let occupied = Task { await store.index.holdExecutor(using: gate) }
        await fulfillment(of: [gate.entered], timeout: 2)
        let restoring = expectation(description: "Account restoration requested")
        let activation = Task {
            restoring.fulfill()
            await store.setSession(owner: 1, credential: nil)
        }
        await fulfillment(of: [restoring], timeout: 2)
        activation.cancel()
        gate.release.signal()
        await occupied.value
        await activation.value
        let result = try await store.search("Song 1")
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(store.isSyncing)
    }

    func testLibraryMatchingMergesDownloadedCopiesAndRanksAllFields() {
        func item(_ id: String, title: String, album: String = "", local: Bool = false) -> MusicSearchItem {
            let song = LibrarySongItem(id: local ? "Music/song.flac" : "netease:1:7", title: title,
                artist: "Artist", album: album, albumArtist: "Artist", trackNumber: 1, artwork: .missing)
            return .init(id: id, kind: .song, title: title, subtitle: "Artist", artwork: .missing, song: song)
        }
        let values = [item("1:7", title: "Moon"), item("prefix", title: "Moonrise"),
                      item("album", title: "Other", album: "Moon"), item("1:7", title: "Moon", local: true)]
        let matched = SearchMusicIntegration.matchLibrary(values, query: "ｍｏｏｎ")
        XCTAssertEqual(matched.map(\.id), ["1:7", "prefix", "album"])
        XCTAssertEqual(matched.first?.song?.id, "Music/song.flac")
        XCTAssertTrue(SearchMusicIntegration.matchLibrary(values, query: "  ").isEmpty)
        XCTAssertEqual(SearchMusicIntegration.matchLibrary(values, query: "artist").count, 3)
    }

    func testRapidInputDebouncesAndAccountChangeCancelsSuggestions() async throws {
        let (client, network) = client(responses: [
            "/weapi/search/suggest/keyword": [Data(#"{"code":200,"result":{"allMatch":[{"keyword":"Latest"}]}}"#.utf8)],
            "/eapi/search/suggest/multimatch": [Data(#"{"code":200,"result":{}}"#.utf8)]
        ])
        defer { network.invalidateAndCancel() }
        let store = NeteaseSearchStore(client: client)
        let first = Task { await store.suggest("old") }
        await Task.yield()
        let second = Task { await store.suggest("new") }
        await first.value; await second.value
        XCTAssertEqual(store.suggestions.keywords, ["Latest"])
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts["/weapi/search/suggest/keyword"] }, 1)
        let cancelled = Task { await store.suggest("cancelled") }
        await Task.yield()
        await store.setSession(owner: 2, credential: nil)
        await cancelled.value
        XCTAssertTrue(store.suggestions.keywords.isEmpty)
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts["/weapi/search/suggest/keyword"] }, 1)
    }

    func testAccountRestorationStartsIndexAndLogoutHidesAccountResults() async throws {
        let (client, network) = client(responses: [
            "/eapi/user/playlist": [Data(#"{"code":200,"playlist":[],"more":false}"#.utf8)],
            "/eapi/album/sublist": [Data(#"{"code":200,"data":[],"hasMore":false}"#.utf8)],
            "/eapi/artist/sublist": [Data(#"{"code":200,"data":[],"hasMore":false}"#.utf8)],
            "/eapi/song/like/get": [Data(#"{"code":200,"ids":[1]}"#.utf8)],
            "/eapi/v3/song/detail": [songs([1])]
        ])
        defer { network.invalidateAndCancel() }
        let saved = NeteaseSavedSession(profile: .init(userID: 1, nickname: "Fixture", avatarURL: nil), credential: try .init(musicU: "fixture"))
        let search = NeteaseSearchStore(client: client)
        let library = NeteaseLibrarySearchStore(client: .init(transport: client.transport), directory: directory())
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {},
            search: search, librarySearch: library)
        await account.restoreCachedContent()
        // Join the lifecycle-owned sync without starting one from a view.
        for _ in 0..<100 where !library.isSyncing && library.completed == 0 { await Task.yield() }
        XCTAssertTrue(library.isSyncing || library.completed > 0)
        await library.synchronize()
        let restored = try await library.search("Song 1")
        XCTAssertEqual(restored.map(\.resourceID), [1])
        search.record("Saved query", scope: "online")
        try await account.logout()
        let loggedOut = try await library.search("Song 1")
        XCTAssertTrue(loggedOut.isEmpty)
        XCTAssertFalse(search.history.contains("Saved query"))
    }

    func testFailedLogoutRestoresCachedIndexWithoutNetworkRefresh() async throws {
        let (client, network) = client(responses: [
            "/eapi/user/playlist": [Data(#"{"code":200,"playlist":[],"more":false}"#.utf8)],
            "/eapi/album/sublist": [Data(#"{"code":200,"data":[],"hasMore":false}"#.utf8)],
            "/eapi/artist/sublist": [Data(#"{"code":200,"data":[],"hasMore":false}"#.utf8)],
            "/eapi/song/like/get": [Data(#"{"code":200,"ids":[1]}"#.utf8)],
            "/eapi/v3/song/detail": [songs([1])]
        ])
        defer {
            SearchFixtureProtocol.state.withLock { $0.onRequest = nil }
            network.invalidateAndCancel()
        }
        let saved = NeteaseSavedSession(profile: .init(userID: 1, nickname: "Fixture", avatarURL: nil),
            credential: try .init(musicU: "fixture"))
        let library = NeteaseLibrarySearchStore(client: .init(transport: client.transport), directory: directory())
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in },
            deleteSession: { throw NeteaseAccountError.keychain(-1) },
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil },
            loadAvatar: { _ in Data() }, clearAvatarCache: {}, librarySearch: library)
        await account.restoreCachedContent()
        await library.synchronize()
        let baseline = SearchFixtureProtocol.state.withLock { $0.counts }
        XCTAssertEqual(baseline.values.reduce(0, +), 5)
        let unexpected = expectation(description: "Cache recovery keeps the network idle")
        unexpected.isInverted = true
        SearchFixtureProtocol.state.withLock { $0.onRequest = { unexpected.fulfill() } }

        do { try await account.logout(); XCTFail("Expected failed logout") }
        catch { XCTAssertEqual(error as? NeteaseAccountError, .keychain(-1)) }

        let cached = try await library.search("Song 1")
        XCTAssertEqual(cached.map(\.resourceID), [1])
        XCTAssertNotNil(account.error)
        await fulfillment(of: [unexpected], timeout: 0.1)
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts }, baseline)
    }

    func testSearchPlaybackUsesLoadedGroupAndRetainsQueueOnLoginOrReplacementCancellation() {
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired }, cachedAvatar: { _ in nil },
            loadAvatar: { _ in Data() }, clearAvatarCache: {})
        func item(_ id: String) -> MusicSearchItem {
            let song = LibrarySongItem(id: id, title: id, artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
            return .init(id: id, kind: .song, title: id, subtitle: "Artist", artwork: .missing, song: song)
        }
        let a = item("downloaded-a.flac"), b = item("local-b.mp3"), later = item("local-c.mp3"), online = item("netease:search-guest:1")
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let integration = SearchMusicIntegration(account: account, player: player)
        integration.model.submitted = true
        integration.model.groups = [.init(kind: .song, items: [a, b])]
        integration.play(b)
        XCTAssertEqual(player.queue.map(\.id), [a.id, b.id]); XCTAssertEqual(player.currentIndex, 1)
        integration.model.groups[0].items.append(later)
        XCTAssertEqual(player.queue.map(\.id), [a.id, b.id])
        player.insertNext([later.song!])
        let queued = player.queue.map(\.id)
        integration.play(a)
        XCTAssertNotNil(player.pendingPlay)
        player.pendingPlay = nil
        XCTAssertEqual(player.queue.map(\.id), queued)
        integration.model.groups = [.init(kind: .song, items: [online])]
        integration.play(online)
        XCTAssertTrue(integration.showsLogin)
        XCTAssertEqual(player.queue.map(\.id), queued)
    }

    func testClosedSearchPublishesLateArtworkToQueueAndRetainedPlaylistThenEvictsIt() async throws {
        let remote = URL(string: "https://example.com/a.jpg")!
        let replacement = URL(string: "https://example.com/next.jpg")!
        let (client, network) = client(responses: [
            "/eapi/search/get": [Data(#"{"code":200,"result":{"songs":[{"id":1,"name":"Song 1"}],"songCount":1}}"#.utf8),
                                  Data(#"{"code":200,"result":{"songs":[],"songCount":0}}"#.utf8)],
            "/eapi/v3/song/detail": [songs([1])],
            "/eapi/playlist/catalogue": [Data(#"{"code":200,"sub":[]}"#.utf8)],
            remote.path: [Data("first artwork".utf8)], replacement.path: [Data("next artwork".utf8)]
        ])
        let images = NeteaseArtworkCache(directory: directory(), session: network, countLimit: 1)
        let suite = "search-artwork-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = NeteaseSearchStore(client: client, defaults: defaults, artworkCache: images)
        let saved = NeteaseSavedSession(profile: .init(userID: 1, nickname: "Fixture", avatarURL: nil),
            credential: try .init(musicU: "fixture"))
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in saved.profile }, cachedAvatar: { _ in nil },
            loadAvatar: { _ in Data() }, clearAvatarCache: {}, search: store)
        await account.restoreCachedContent()
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        player.restoreOnlineIdentity(ownerID: "1")
        let playlists = PlaylistLibrary(playlists: [])
        playlists.restoreOnlineIdentity(ownerID: "1")
        let playlist = try XCTUnwrap(playlists.createPlaylist(named: "Retained", artwork: .playlist, in: nil))
        let integration = SearchMusicIntegration(account: account, player: player, playlistLibrary: playlists)
        let previousExternal = LocalLibrary.songLibrary.externalSongs
        defer {
            player.shutdownPlayback()
            LocalLibrary.songLibrary.replaceExternalSongs([], source: "search")
            LocalLibrary.songLibrary.replaceExternalSongs(previousExternal)
            defaults.removePersistentDomain(forName: suite)
            network.invalidateAndCancel()
        }
        integration.connect()
        integration.model.kind = .song
        integration.model.submit("First")
        try await waitForPublication { integration.model.groups.first?.items.first?.song != nil }
        let item = try XCTUnwrap(integration.model.groups.first?.items.first)
        let song = try XCTUnwrap(item.song)
        let loadID = try XCTUnwrap(song.artwork.loadID)
        XCTAssertEqual(playlists.addSongs([song], to: playlist.id), 1)
        integration.play(item)
        XCTAssertEqual(player.current.id, song.id)
        integration.model.cancel()
        try await waitForPublication { integration.model.groups.isEmpty }

        integration.requestArtwork(for: loadID)
        try await waitForPublication { player.current.artworkURL != nil }
        let file = try XCTUnwrap(player.current.artworkURL)
        XCTAssertEqual(playlists.songs(in: playlist.id).first?.artworkURL, file)
        XCTAssertEqual(LocalLibrary.songLibrary.song(id: song.id)?.artworkURL, file)

        let local = LibrarySongItem(id: "local.flac", title: "Local", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: 1, artwork: .missing)
        player.play([local], from: "Local", shuffled: false)
        integration.model.submit("Second")
        try await waitForPublication { store.request?.query == "Second" && !store.isLoading }
        _ = try await images.imageURL(for: replacement, scope: "1")
        XCTAssertNil(playlists.songs(in: playlist.id).first?.artworkURL)
        XCTAssertEqual(playlists.songs(in: playlist.id).first?.artwork.loadID, loadID)
        XCTAssertNil(LocalLibrary.songLibrary.song(id: song.id)?.artworkURL)
        XCTAssertEqual(player.current, local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await account.logout()
        try await waitForPublication { integration.model.ownerID == nil }
    }

    private func waitForPublication(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for search publication")
        throw URLError(.timedOut)
    }

    private func resource(_ id: Int64, title: String? = nil) -> NeteaseSearchResource {
        NeteaseSearchClient.resource(.init(id: id, title: title ?? "Song \(id)", artist: "Artist", album: "Release", artworkURL: nil, duration: 60))
    }
    private func page(_ ids: [Int64], offset: Int) -> NeteaseSearchPage {
        .init(groups: [.init(kind: .song, items: ids.map { resource($0) }, hasMore: true)], nextOffset: offset, hasMore: true)
    }
    private func directory() -> URL {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func songs(_ ids: [Int64]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["code": 200, "songs": ids.map { ["id": $0, "name": "Song \($0)", "dt": 60000, "ar": [["id": 1, "name": "Artist"]], "al": ["id": 1, "name": "Release", "picUrl": "https://example.com/a.jpg"]] }])
    }
    private func client(responses: [String: [Data]]) -> (NeteaseSearchClient, URLSession) {
        SearchFixtureProtocol.state.withLock { $0 = .init(responses: responses) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SearchFixtureProtocol.self]
        let network = URLSession(configuration: config)
        return (.init(transport: .init(session: network)), network)
    }
}

private final class SearchIndexExecutorGate: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(entered: XCTestExpectation) { self.entered = entered }
    func hold() {
        entered.fulfill()
        release.wait()
    }
}

private extension NeteaseLibrarySearchIndex {
    /// Holds the real index executor while a session change is waiting for SQLite work.
    func holdExecutor(using gate: SearchIndexExecutorGate) { gate.hold() }
}

private final class SearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var responses: [String: [Data]]
        var counts: [String: Int] = [:]
        var onRequest: (@Sendable () -> Void)?
    }
    static let state = Mutex(State(responses: [:]))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let onRequest = Self.state.withLock { $0.onRequest }
        onRequest?()
        let data = Self.state.withLock { value -> Data in
            let key = request.url!.path; value.counts[key, default: 0] += 1
            guard var values = value.responses[key], let result = values.first else { return Data(#"{"code":404}"#.utf8) }
            if values.count > 1 { values.removeFirst(); value.responses[key] = values }
            return result
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
