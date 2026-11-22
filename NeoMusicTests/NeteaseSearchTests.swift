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
        for index in 0..<25 { store.record("Query \(index)") }
        XCTAssertEqual(store.history.count, 20); XCTAssertEqual(store.history.first, "Query 24")
        store.record("Query 23"); XCTAssertEqual(store.history.first, "Query 23")
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

    func testSameSessionKeepsOnlineQueryCache() async throws {
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
        store.record("Another guest query")
        XCTAssertEqual(defaults.stringArray(forKey: "search.history.1.online"), ["Account query"])
        XCTAssertEqual(defaults.stringArray(forKey: "search.history.guest.online")?.first, "Another guest query")
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

    func testAccountRestorationSwitchAndLogoutKeepOnlineHistoryIsolated() async throws {
        let response = Data(#"{"code":200,"result":{"artists":[{"id":1,"name":"Artist"}],"artistCount":1}}"#.utf8)
        let (client, network) = client(responses: ["/eapi/search/get": [response]])
        defer { network.invalidateAndCancel() }
        let suite = "search-lifecycle-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(["Guest query"], forKey: "search.history.guest.online")
        defaults.set(["First account query"], forKey: "search.history.1.online")
        defaults.set(["Second account query"], forKey: "search.history.2.online")
        defaults.set(["Retired library query"], forKey: "search.history.1.library")

        let saved = NeteaseSavedSession(
            profile: .init(userID: 1, nickname: "First", avatarURL: nil),
            credential: try .init(musicU: "first-fixture")
        )
        let second = NeteaseProfile(userID: 2, nickname: "Second", avatarURL: nil)
        let search = NeteaseSearchStore(client: client, defaults: defaults)
        let account = NeteaseAccount(
            readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { $0 == saved.credential ? saved.profile : second },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {},
            search: search
        )

        XCTAssertEqual(search.recent(), ["Guest query"])
        await account.restoreCachedContent()
        XCTAssertEqual(account.profile?.userID, 1)
        XCTAssertEqual(search.recent(), ["First account query"])
        await search.search("test", kind: .artist)
        XCTAssertEqual(search.page?.groups.first?.items.first?.title, "Artist")

        try await account.completeLogin(credential: .init(musicU: "second-fixture"))
        XCTAssertEqual(account.profile?.userID, 2)
        XCTAssertEqual(search.recent(), ["Second account query"])
        XCTAssertNil(search.page)
        search.record("Another account query")
        search.removeHistory("Second account query")

        try await account.logout()
        XCTAssertNil(account.profile)
        XCTAssertEqual(search.recent(), ["Guest query"])
        XCTAssertEqual(defaults.stringArray(forKey: "search.history.1.online"), ["First account query"])
        XCTAssertEqual(defaults.stringArray(forKey: "search.history.2.online"), ["Another account query"])
        XCTAssertEqual(defaults.stringArray(forKey: "search.history.1.library"), ["Retired library query"])
        XCTAssertEqual(SearchFixtureProtocol.state.withLock { $0.counts }, ["/eapi/search/get": 1])
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

    func testExpiredSearchSessionRequiresLoginEvenWithRetainedProfile() async throws {
        let profile = NeteaseProfile(userID: 42, nickname: "Fixture", avatarURL: nil)
        let saved = NeteaseSavedSession(profile: profile, credential: try .init(musicU: "fixture"))
        let account = NeteaseAccount(readSession: { saved }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired },
            cachedAvatar: { _ in nil }, loadAvatar: { _ in Data() }, clearAvatarCache: {})
        await account.restoreCachedContent()
        XCTAssertEqual(account.restoredPlaybackIdentity, .signedIn("42"))
        await account.revalidate()
        XCTAssertEqual(account.profile, profile)
        XCTAssertEqual(account.validationState, .requiresLogin)

        func item(_ id: String) -> MusicSearchItem {
            let song = LibrarySongItem(id: id, title: id, artist: "Artist", album: "Album", albumArtist: "Artist",
                                       trackNumber: 1, artwork: .missing)
            return .init(id: id, kind: .song, title: id, subtitle: song.artist, artwork: .missing, song: song)
        }
        let online = item("netease:42:1"), offline = item("网易云/downloaded.flac")
        let player = NowPlayingModel(queue: [], currentIndex: 0, isPlaying: false)
        let integration = SearchMusicIntegration(account: account, player: player)
        integration.model.submitted = true
        integration.model.groups = [.init(kind: .song, items: [online, offline])]
        integration.play(online)
        XCTAssertTrue(integration.showsLogin)
        XCTAssertTrue(player.queue.isEmpty)

        integration.showsLogin = false
        integration.model.groups = [.init(kind: .song, items: [offline])]
        integration.play(offline)
        XCTAssertFalse(integration.showsLogin)
        XCTAssertEqual(player.current.id, offline.id)
        player.shutdownPlayback()
    }

    func testRuntimeResolvesSearchArtworkFromDiskOnlyForItsSession() async throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/a.jpg"))
        let (client, network) = client(responses: [
            "/eapi/search/get": [Data(#"{"code":200,"result":{"songs":[{"id":1,"name":"Song 1"}],"songCount":1}}"#.utf8)],
            "/eapi/v3/song/detail": [songs([1])],
            "/eapi/playlist/catalogue": [Data(#"{"code":200,"sub":[]}"#.utf8)],
            remote.path: [NeteaseArtworkTestFixture.png]
        ])
        let root = directory()
        let writer = NeteaseArtworkCache(directory: root, session: network)
        let saved = try await writer.imageURL(for: remote, scope: "public")
        let images = NeteaseArtworkCache(directory: root, session: network)
        let suite = "search-artwork-routing-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = NeteaseSearchStore(client: client, defaults: defaults, artworkCache: images)
        let account = NeteaseAccount(readSession: { nil }, saveSession: { _ in }, deleteSession: {},
            validateCredential: { _ in throw NeteaseAccountError.authenticationRequired }, cachedAvatar: { _ in nil },
            loadAvatar: { _ in Data() }, clearAvatarCache: {}, search: store)
        let previousExternal = LocalLibrary.songLibrary.externalSongs
        defer {
            LocalLibrary.songLibrary.replaceExternalSongs([], source: "search")
            LocalLibrary.songLibrary.replaceExternalSongs(previousExternal)
            defaults.removePersistentDomain(forName: suite)
            network.invalidateAndCancel()
        }
        let runtime = AppRuntime(account: account)
        runtime.search.connect()
        runtime.search.model.kind = .song
        runtime.search.model.submit("First")
        try await waitForPublication { runtime.search.model.groups.first?.items.first?.song != nil }
        let id = try XCTUnwrap(runtime.search.model.groups.first?.items.first?.artwork.loadID)
        let resolve = try XCTUnwrap(runtime.artworkLoadAction.resolve)
        let resolved = await resolve(id)
        XCTAssertEqual(resolved, saved)

        await store.setSession(owner: 42, credential: try .init(musicU: "fixture"))
        let stale = await resolve(id)
        XCTAssertNil(stale)
    }

    func testClosedSearchPublishesLateArtworkToQueueAndRetainedPlaylistThenEvictsIt() async throws {
        let remote = URL(string: "https://example.com/a.jpg")!
        let replacement = URL(string: "https://example.com/next.jpg")!
        let (client, network) = client(responses: [
            "/eapi/search/get": [Data(#"{"code":200,"result":{"songs":[{"id":1,"name":"Song 1"}],"songCount":1}}"#.utf8),
                                  Data(#"{"code":200,"result":{"songs":[],"songCount":0}}"#.utf8)],
            "/eapi/v3/song/detail": [songs([1])],
            "/eapi/playlist/catalogue": [Data(#"{"code":200,"sub":[]}"#.utf8)],
            remote.path: [NeteaseArtworkTestFixture.png], replacement.path: [NeteaseArtworkTestFixture.png]
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
        integration.model.cancel()
        await store.cancelQuery()
        try await account.logout()
        try await waitForPublication { integration.model.ownerID == nil }
        await store.loadCategories()
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

private final class SearchFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var responses: [String: [Data]]
        var counts: [String: Int] = [:]
    }
    static let state = Mutex(State(responses: [:]))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
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
