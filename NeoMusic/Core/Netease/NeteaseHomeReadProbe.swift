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
        let anonymous: NeteaseCredential? = nil
        var requests: [(String, String, [String: Any], NeteaseCredential?)] = [
            ("public", "/api/personalized/playlist", ["limit": 30, "total": true, "n": 1000], anonymous),
            ("anonymousDetail", "/api/v6/playlist/detail", ["id": 3778678, "n": 0, "s": 0], anonymous)
        ]
        if let saved {
            requests += [
                ("personal", "/api/v1/discovery/recommend/resource", [:], saved.credential),
                ("daily", "/api/v3/discovery/recommend/songs", [:], saved.credential)
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
}
#endif
