#if DEBUG
import Foundation

/// Bounded API reads with a report containing only counts, booleans and error categories.
@MainActor enum NeteaseAssessmentReadProbe {
    static func run() async {
        let directory = URL.applicationSupportDirectory.appending(path: "AssessmentReadProbe", directoryHint: .isDirectory)
        var report: [String: Any] = ["hasSession": false, "profileValid": false, "completed": false]
        @MainActor func save() {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: directory.appending(path: "result.json"), options: .atomic)
            } catch { print("AssessmentReadProbe report write failed: \((error as NSError).code)") }
        }
        @MainActor func probe(_ name: String, operation: @MainActor () async throws -> [String: Any]) async {
            do {
                var result = try await operation()
                if result["status"] == nil { result["status"] = "ok" }
                report[name] = result
            } catch { report[name] = failure(error) }
            save()
        }
        save()
        let saved: NeteaseSavedSession
        do {
            guard let session = try await NeteaseCredentialStore().read() else {
                report["session"] = ["status": "missing"]
                report["completed"] = true
                save()
                return
            }
            saved = session
        } catch {
            report["session"] = failure(error)
            report["completed"] = true
            save()
            return
        }
        report["hasSession"] = true
        let transport = NeteaseAccountClient()
        let music = NeteaseMusicClient(transport: transport)
        let search = NeteaseSearchClient(transport: transport)
        let credential = saved.credential
        var playlistID: Int64?
        var likedIDs: Set<Int64> = []
        var samples: [NeteaseMusicSong] = []
        var artistID: Int64?
        var albumID: Int64?

        await probe("profile") {
            let profile = try await transport.profile(credential: credential)
            let valid = profile.userID == saved.profile.userID
            report["profileValid"] = valid
            return ["identityMatchesSavedSession": valid, "hasAvatar": profile.avatarURL != nil]
        }
        await probe("playlists") {
            struct Page: Decodable, Sendable {
                struct Item: Decodable, Sendable { let id: Int64; let trackCount: Int }
                let playlist: [Item]
                let more: Bool
            }
            let first: Page = try await music.read("/api/user/playlist",
                ["uid": saved.profile.userID, "limit": 20, "offset": 0], credential)
            playlistID = first.playlist.first(where: { $0.trackCount > 0 })?.id
            var result: [String: Any] = ["firstPageCount": first.playlist.count, "firstPageHasMore": first.more]
            if first.more, !first.playlist.isEmpty {
                do {
                    let second: Page = try await music.read("/api/user/playlist",
                        ["uid": saved.profile.userID, "limit": 20, "offset": first.playlist.count], credential)
                    let ids = (first.playlist + second.playlist).map(\.id)
                    result["secondPageCount"] = second.playlist.count
                    result["secondPageHasMore"] = second.more
                    result["uniqueIdentities"] = Set(ids).count == ids.count
                    if playlistID == nil { playlistID = second.playlist.first(where: { $0.trackCount > 0 })?.id }
                } catch { result["secondPage"] = failure(error) }
            }
            return result
        }
        await probe("likedSongs") {
            likedIDs = try await music.likedIDs(userID: saved.profile.userID, credential: credential)
            return ["count": likedIDs.count]
        }
        await probe("followedArtists") {
            let values = try await music.subscribedArtists(credential: credential)
            return ["count": values.count, "uniqueIdentities": Set(values.map(\.id)).count == values.count]
        }
        await probe("collectedAlbums") {
            let values = try await music.subscribedAlbums(credential: credential)
            return ["count": values.count, "uniqueIdentities": Set(values.map(\.id)).count == values.count]
        }
        await probe("homepage") {
            let first = try await music.homeFeed(credential: credential)
            let resources = first.blocks.flatMap(\.resources)
            var result: [String: Any] = ["blockCount": first.blocks.count, "resourceCount": resources.count,
                "hasMore": first.hasMore == true, "hasCursor": first.cursor?.isEmpty == false]
            if first.hasMore == true, let cursor = first.cursor, !cursor.isEmpty {
                do {
                    let second = try await music.homeFeed(credential: credential, cursor: cursor)
                    let next = Set(second.blocks.flatMap(\.resources).map(\.id))
                    result["secondPageBlockCount"] = second.blocks.count
                    result["secondPageNewResourceCount"] = next.subtracting(Set(resources.map(\.id))).count
                    result["secondPageHasMore"] = second.hasMore == true
                    result["cursorAdvanced"] = second.cursor != cursor
                } catch { result["secondPage"] = failure(error) }
            }
            return result
        }
        await probe("recommendations") {
            let values = try await music.homeRecommendations(credential: credential)
            if playlistID == nil { playlistID = values.first?.id }
            return ["count": values.count, "uniqueIdentities": Set(values.map(\.id)).count == values.count]
        }
        await probe("dailySongs") {
            let values = try await music.dailyRecommendations(credential: credential)
            samples.append(contentsOf: values.prefix(3))
            return ["count": values.count, "uniqueIdentities": Set(values.map(\.id)).count == values.count]
        }
        await probe("charts") {
            let values = try await music.homeCharts(credential: credential).resources
            return ["count": values.count]
        }
        await probe("categories") {
            let categories = try await search.categories(credential: credential)
            var result: [String: Any] = ["count": categories.count]
            if let category = categories.first {
                let first = try await search.playlists(category: category.name, limit: 10, credential: credential)
                let items = first.groups.flatMap(\.items)
                result["firstPageCount"] = items.count
                result["firstPageHasMore"] = first.hasMore
                if first.hasMore {
                    do {
                        let second = try await search.playlists(category: category.name, offset: first.nextOffset,
                            limit: 10, credential: credential)
                        let ids = (items + second.groups.flatMap(\.items)).map(\.id)
                        result["secondPageCount"] = second.groups.flatMap(\.items).count
                        result["secondPageHasMore"] = second.hasMore
                        result["offsetAdvanced"] = second.nextOffset > first.nextOffset
                        result["uniqueIdentities"] = Set(ids).count == ids.count
                    } catch { result["secondPage"] = failure(error) }
                }
            }
            return result
        }
        for kind in NeteaseSearchKind.allCases {
            await probe("search_\(kind.rawValue)") {
                let first = try await search.search("洛天依", kind: kind, credential: credential)
                let items = first.groups.flatMap(\.items)
                if kind == .artist { artistID = items.first?.resourceID }
                if kind == .album { albumID = items.first?.resourceID }
                var result: [String: Any] = ["count": items.count, "groupCount": first.groups.count,
                    "hasMore": first.hasMore, "uniqueIdentities": Set(items.map(\.id)).count == items.count]
                if kind == .song, first.hasMore {
                    do {
                        let second = try await search.search("洛天依", kind: kind, offset: first.nextOffset, credential: credential)
                        let next = second.groups.flatMap(\.items)
                        let ids = (items + next).map(\.id)
                        result["secondPageCount"] = next.count
                        result["secondPageHasMore"] = second.hasMore
                        result["offsetAdvanced"] = second.nextOffset > first.nextOffset
                        result["uniquePageIdentities"] = Set(ids).count == ids.count
                    } catch { result["secondPage"] = failure(error) }
                }
                return result
            }
        }
        await probe("suggestions") {
            let values = try await search.suggestions("洛天依", credential: credential)
            return ["keywordCount": values.keywords.count, "entityCount": values.resources.count]
        }
        await probe("playlistSongs") {
            guard let playlistID else { return ["status": "no_sample"] }
            let first = try await music.detail(id: playlistID, credential: credential, trackLimit: 20)
            samples.append(contentsOf: first.songs.prefix(3))
            var result: [String: Any] = ["firstPageCount": first.songs.count,
                "totalTrackCount": first.orderedTrackIDs.count, "firstPageComplete": first.isComplete]
            if !first.isComplete {
                do {
                    let second = try await music.loadMore(first, credential: credential, limit: 20)
                    let expected = second.orderedTrackIDs.prefix(second.nextOffset).filter { id in second.songs.contains { $0.id == id } }
                    result["loadedCountAfterSecondPage"] = second.songs.count
                    result["secondPageComplete"] = second.isComplete
                    result["offsetAdvanced"] = second.nextOffset > first.nextOffset
                    result["orderMatchesTrackIdentities"] = second.songs.map(\.id) == expected
                    result["uniqueIdentities"] = Set(second.songs.map(\.id)).count == second.songs.count
                } catch { result["secondPage"] = failure(error) }
            }
            return result
        }
        await probe("songDetail") {
            guard let id = samples.first?.id ?? likedIDs.sorted().first else { return ["status": "no_sample"] }
            let song = try await music.songDetail(id: id, credential: credential)
            samples.insert(song, at: 0)
            artistID = song.artists?.first?.id ?? artistID
            albumID = song.albumID ?? albumID
            return ["identityMatchesRequest": song.id == id, "artistCount": song.artists?.count ?? 0,
                "hasAlbumIdentity": song.albumID != nil, "hasDuration": song.duration > 0]
        }
        await probe("artist") {
            guard let artistID else { return ["status": "no_sample"] }
            let value = try await music.artistDetail(id: artistID, credential: credential)
            return ["identityMatchesRequest": value.artist.id == artistID, "songCount": value.songs.count,
                "hasBiography": !value.biography.isEmpty]
        }
        await probe("album") {
            guard let albumID else { return ["status": "no_sample"] }
            let value = try await music.albumDetail(id: albumID, credential: credential)
            return ["identityMatchesRequest": value.album.id == albumID, "songCount": value.songs.count,
                "complete": value.songs.count == value.album.trackCount]
        }
        await probe("stream") {
            var seen = Set<Int64>(), attempted = 0
            for song in samples where attempted < 3 && seen.insert(song.id).inserted {
                attempted += 1
                do {
                    let value = try await music.stream(id: song.id, quality: .lossless, credential: credential)
                    return ["attemptedCount": attempted, "https": value.url.scheme == "https",
                        "hasHost": value.url.host?.isEmpty == false, "quality": value.quality.rawValue,
                        "expiresInFuture": value.expiresAt > Date()]
                } catch NeteaseMusicError.unavailable { }
            }
            return ["status": attempted == 0 ? "no_sample" : "resource_unavailable", "attemptedCount": attempted]
        }
        await probe("lyrics") {
            guard let song = samples.first else { return ["status": "no_sample"] }
            let value = try await music.lyrics(id: song.id, credential: credential)
            return ["hasOriginal": !value.original.isEmpty, "hasTranslation": !value.translation.isEmpty]
        }
        report["completed"] = true
        save()
    }

    private static func failure(_ error: any Error) -> [String: Any] {
        if error is CancellationError { return ["status": "cancelled"] }
        if let error = error as? NeteaseAccountError {
            switch error {
            case .authenticationRequired: return ["status": "authentication_required"]
            case .http(let code): return ["status": "http_error", "code": code]
            case .server(let code): return ["status": "service_rejected", "code": code]
            case .network(let code): return ["status": "network_error", "code": code.rawValue]
            case .keychain(let code): return ["status": "keychain_error", "code": code]
            case .invalidResponse: return ["status": "invalid_response"]
            case .invalidSavedSession: return ["status": "invalid_saved_session"]
            case .requestEncoding: return ["status": "request_encoding_error"]
            }
        }
        if let error = error as? NeteaseWebResponseError { return ["status": "service_rejected", "code": error.code] }
        if let error = error as? URLError { return ["status": "network_error", "code": error.code.rawValue] }
        return ["status": "error", "type": String(reflecting: type(of: error)), "code": (error as NSError).code]
    }
}
#endif
