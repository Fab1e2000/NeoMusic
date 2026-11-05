#if DEBUG
import Foundation

/// Read-only device verification. Reports schema and counts without account content or credentials.
@MainActor enum NeteaseHomeReadProbe {
    static func run() async {
        var report: [String: Any] = [:]
        let client = NeteaseAccountClient()
        let saved: NeteaseSavedSession?
        do { saved = try await NeteaseCredentialStore().read() }
        catch { saved = nil; report["sessionError"] = error.localizedDescription }
        report["hasSession"] = saved != nil
        if ProcessInfo.processInfo.arguments.contains("-homeActionReadProbe") {
            await probeActions(client: client, saved: saved)
            return
        }
        let anonymous: NeteaseCredential? = nil
        var requests: [(String, String, [String: any Sendable], NeteaseCredential?)] = [
            ("public", "/api/personalized/playlist", ["limit": 30, "total": true, "n": 1000], anonymous),
            ("anonymousDetail", "/api/v6/playlist/detail", ["id": 3778678, "n": 0, "s": 0], anonymous)
        ]
        if let saved {
            requests += [
                ("personal", "/api/v1/discovery/recommend/resource", [:], saved.credential),
                ("daily", "/api/v3/discovery/recommend/songs", [:], saved.credential),
                ("feed", "/api/homepage/block/page", ["refresh": true], saved.credential),
                ("charts", "/api/toplist", [:], saved.credential),
                ("followed", "/api/sub/artist/new/works/song/list", ["limit": 20, "startTimestamp": Int64(Date().timeIntervalSince1970 * 1000)], saved.credential)
            ]
        }
        for (name, path, fields, credential) in requests {
            do {
                let data = try await client.request(path: path, fields: fields, credential: credential)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NeteaseAccountError.invalidResponse }
                var entry: [String: Any] = ["keys": root.keys.sorted(), "code": root["code"] ?? NSNull()]
                if let items = (root["result"] ?? root["recommend"]) as? [[String: Any]] {
                    entry["count"] = items.count
                    entry["itemKeys"] = items.first?.keys.sorted() ?? []
                    entry["uniqueIDs"] = Set(items.compactMap { $0["id"] as? Int64 }).count
                }
                if let value = root["data"] as? [String: Any] {
                    entry["dataKeys"] = value.keys.sorted()
                    entry["demote"] = value["demote"] ?? NSNull()
                    if let blocks = value["blocks"] as? [[String: Any]] {
                        entry["blocks"] = blocks.map { block -> [String: Any] in
                            let creatives = block["creatives"] as? [[String: Any]] ?? []
                            let resources = creatives.flatMap { $0["resources"] as? [[String: Any]] ?? [] }
                            return ["code": block["blockCode"] ?? "", "keys": block.keys.sorted(),
                                    "creativeTypes": creatives.compactMap { $0["creativeType"] as? String },
                                    "resourceTypes": resources.compactMap { $0["resourceType"] as? String },
                                    "resourceKeys": resources.first?.keys.sorted() ?? [],
                                    "extraKeys": (resources.first?["resourceExtInfo"] as? [String: Any])?.keys.sorted() ?? []]
                        }
                        let directory = URL.applicationSupportDirectory.appendingPathComponent("HomeReadProbe")
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try data.write(to: directory.appendingPathComponent("feed.json"), options: .atomic)
                        var page = value
                        var seen = Set<String>()
                        for index in 1...8 {
                            guard page["hasMore"] as? Bool == true,
                                  let cursor = page["cursor"] as? String, !cursor.isEmpty,
                                  seen.insert(cursor).inserted else { break }
                            let next = try await client.request(path: "/api/homepage/block/page",
                                fields: ["refresh": false, "cursor": cursor], credential: credential)
                            try next.write(to: directory.appendingPathComponent("feed-\(index).json"), options: .atomic)
                            guard let root = try JSONSerialization.jsonObject(with: next) as? [String: Any],
                                  let value = root["data"] as? [String: Any] else { break }
                            page = value
                        }

                    }
                    if let songs = value["dailySongs"] as? [[String: Any]] {
                        entry["songCount"] = songs.count
                        entry["songKeys"] = songs.first?.keys.sorted() ?? []
                        entry["uniqueSongIDs"] = Set(songs.compactMap { $0["id"] as? Int64 }).count
                    }
                }
                if let playlist = root["playlist"] as? [String: Any] {
                    entry["trackCount"] = playlist["trackCount"] ?? NSNull()
                    entry["trackIDCount"] = (playlist["trackIds"] as? [Any])?.count ?? 0
                }
                if ["charts", "followed"].contains(name) {
                    let directory = URL.applicationSupportDirectory.appendingPathComponent("HomeReadProbe")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
                }
                report[name] = entry
            } catch { report[name] = ["error": error.localizedDescription] }
        }
        do {
            let directory = URL.applicationSupportDirectory.appendingPathComponent("HomeReadProbe")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
                .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch { NSLog("Home read probe report failed: %@", error.localizedDescription) }
    }
    private static func probeActions(client: NeteaseAccountClient, saved: NeteaseSavedSession?) async {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("HomeActionReadProbe")
        var report: [String: Any] = ["hasSession": saved != nil]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let saved else { throw NeteaseAccountError.authenticationRequired }
            let music = NeteaseMusicClient(transport: client)
            let playlists = try await music.playlists(userID: saved.profile.userID, credential: saved.credential)
            guard let liked = playlists.first(where: \.isFavorites) else { throw NeteaseAccountError.invalidResponse }
            let detail = try await music.detail(id: liked.id, credential: saved.credential, trackLimit: 1)
            guard let seed = detail.songs.first(where: { !$0.unavailable && $0.id > 0 }) else { throw NeteaseAccountError.invalidResponse }
            let requests: [(String, String, [String: any Sendable])] = [
                ("heart", "/api/playmode/intelligence/list", ["songId": seed.id, "type": "fromPlayOne", "playlistId": liked.id, "startMusicId": seed.id, "count": 1]),
                ("roaming", "/api/v1/radio/get", ["mode": "EXPLORE", "limit": 30]),
                ("similar", "/api/v1/discovery/simiSong", ["songid": seed.id, "limit": 50, "offset": 0]),
                ("newSongs", "/api/v1/discovery/new/songs", ["areaId": 0, "total": true])
            ]
            for (name, path, fields) in requests {
                do {
                    let data = try await client.request(path: path, fields: fields, credential: saved.credential)
                    try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
                    let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    let songs = (root["data"] ?? root["songs"]) as? [[String: Any]] ?? []
                    var entry: [String: Any] = ["code": root["code"] ?? NSNull(), "keys": root.keys.sorted(),
                        "count": songs.count, "itemKeys": songs.first?.keys.sorted() ?? []]
                    switch name {
                    case "heart":
                        let parsed = try JSONDecoder().decode(NeteaseHomeSupplemental.Intelligence.self, from: data)
                        let ids = parsed.songIDs
                        let details = try await music.songs(ids: ids, credential: saved.credential)
                        entry["typedIDCount"] = ids.count
                        entry["typedOrderMatches"] = ids == songs.compactMap { $0["id"] as? Int64 }
                        entry["detailCount"] = details.count
                        entry["matchingDetailCount"] = Set(details.map(\.id)).intersection(ids).count
                        entry["detailOrderMatches"] = details.map(\.id) == ids
                    case "similar":
                        let parsed = try JSONDecoder().decode(NeteaseHomeSupplemental.Similar.self, from: data)
                        entry["typedCount"] = parsed.models.count
                        entry["typedOrderMatches"] = parsed.models.map(\.id) == songs.compactMap { $0["id"] as? Int64 }
                    default:
                        let parsed = try JSONDecoder().decode(NeteaseHomeSupplemental.SongBatch.self, from: data)
                        entry["typedCount"] = parsed.songs.count
                        entry["typedOrderMatches"] = parsed.songs.map(\.id) == songs.compactMap { $0["id"] as? Int64 }
                    }
                    report[name] = entry
                } catch { report[name] = ["error": error.localizedDescription] }
            }
        } catch { report["error"] = error.localizedDescription }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch { NSLog("Home action probe report failed: %@", error.localizedDescription) }
    }

}
/// Compares the legacy and playback request profiles without publishing account or song data.
@MainActor enum NeteasePlaybackReadProbe {
    static func run() async {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("PlaybackReadProbe")
        var report: [String: Any] = ["completed": false]
        var results: [[String: Any]] = []
        func save() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: directory.appendingPathComponent("report.json"), options: .atomic)
            }
        }
        func errorCode(_ error: any Error) -> String {
            if let value = error as? NeteaseAccountError { return String(describing: value) }
            let value = error as NSError
            return "\(value.domain):\(value.code)"
        }
        save()
        do {
            guard let saved = try await NeteaseCredentialStore().read() else { throw NeteaseAccountError.authenticationRequired }
            let client = NeteaseMusicClient()
            let ids = try await client.likedIDs(userID: saved.profile.userID, credential: saved.credential).sorted().prefix(3)
            report["sampleCount"] = ids.count
            for (index, id) in ids.enumerated() {
                for profile in [NeteaseAccountClient.EAPIProfile.account, .playback] {
                    let start = Date()
                    var result: [String: Any] = ["sample": index, "profile": profile == .account ? "legacy" : "MeloX-playback"]
                    do {
                        let data = try await client.transport.request(path: "/api/song/enhance/player/url/v1",
                            fields: ["ids": "[\(id)]", "level": "lossless", "encodeType": "flac"],
                            credential: saved.credential, profile: profile)
                        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        let items = root?["data"] as? [[String: Any]] ?? []
                        result["code"] = root?["code"]
                        result["fullSourceCount"] = items.filter { $0["url"] is String && ($0["freeTrialInfo"] == nil || $0["freeTrialInfo"] is NSNull) }.count
                        result["responseCount"] = items.count
                    } catch { result["error"] = errorCode(error) }
                    result["elapsedMS"] = Int(Date().timeIntervalSince(start) * 1000)
                    results.append(result)
                    report["requests"] = results
                    save()
                }
                var typed: [String: Any] = ["sample": index, "profile": "production-stream"]
                do {
                    let source = try await client.stream(id: id, quality: .lossless, credential: saved.credential)
                    typed["https"] = source.url.scheme == "https"
                    typed["unexpired"] = source.expiresAt > Date()
                    typed["quality"] = source.quality.rawValue
                } catch { typed["error"] = errorCode(error) }
                results.append(typed)
                report["requests"] = results
                save()
            }
        } catch { report["error"] = errorCode(error) }
        report["completed"] = true
        save()
    }
}
#endif
