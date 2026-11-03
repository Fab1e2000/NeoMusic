#if DEBUG
import Foundation

@MainActor enum NeteaseArtistReadProbe {
    static func run() async {
        var report: [String: Any] = [:]
        let client = NeteaseMusicClient()
        do {
            let saved = try await NeteaseCredentialStore().read()
            report["hasSession"] = saved != nil
            report["hasCSRF"] = saved?.credential.csrf?.isEmpty == false
            let credential = saved?.credential
            var sampleArtistID: Int64 = 6452
            var playableAlbumID: Int64?
            if let saved {
                let ids = try await client.likedIDs(userID: saved.profile.userID, credential: saved.credential)
                for id in ids.sorted().prefix(20) {
                    let song = try await client.songDetail(id: id, credential: saved.credential)
                    guard let artistID = song.artists?.first?.id, let albumID = song.albumID,
                          let stream = try? await client.stream(id: id, quality: .standard, credential: saved.credential) else { continue }
                    sampleArtistID = artistID
                    playableAlbumID = albumID
                    report["playableSongID"] = id
                    report["playableSongTitle"] = song.title
                    report["resolvedQuality"] = stream.quality.rawValue
                    break
                }
                guard playableAlbumID != nil else { throw NeteaseMusicError.unavailable }
            }
            let artist = try await client.artistDetail(id: sampleArtistID, credential: credential)
            report["artistID"] = artist.artist.id
            report["hotSongCount"] = artist.songs.count
            report["songIdentities"] = artist.songs.allSatisfy { $0.artists?.isEmpty == false && $0.albumID != nil }
            let albums = try await client.artistAlbums(id: sampleArtistID, credential: credential)
            report["albumCount"] = albums.count
            report["albumTypes"] = Set(albums.map(\.type)).sorted()
            let biography = try await client.artistBiography(id: sampleArtistID, credential: credential)
            report["biographyLength"] = biography.count
            do { report["similarCount"] = try await client.similarArtists(id: sampleArtistID, credential: credential).count }
            catch { report["similarError"] = error.localizedDescription }
            if let album = albums.first {
                let detail = try await client.albumDetail(id: album.id, credential: credential)
                report["albumID"] = album.id
                report["albumSongCount"] = detail.songs.count
                report["albumComplete"] = detail.songs.count == detail.album.trackCount
            }
            if let credential {
                do { report["profileValid"] = try await NeteaseAccountClient().profile(credential: credential).userID == saved?.profile.userID }
                catch { report["profileError"] = error.localizedDescription }
                if let userID = saved?.profile.userID {
                    do { report["playlistCount"] = try await client.playlists(userID: userID, credential: credential).count }
                    catch { report["playlistError"] = error.localizedDescription }
                    do { report["likedSongCount"] = try await client.likedIDs(userID: userID, credential: credential).count }
                    catch { report["likedSongsError"] = error.localizedDescription }
                }
                let transport = NeteaseAccountClient()
                let session = URLSession(configuration: NeteaseAccountClient.sessionConfiguration())
                if let sample = albums.first {
                    for (key, path) in [("albumDynamic", "/api/album/detail/dynamic"), ("albumProduct", "/api/vipmall/albumproduct/detail")] {
                        do {
                            let request = try transport.makeWebRequest(path: path, fields: ["id": sample.id], credential: credential)
                            let (body, _) = try await session.data(for: request)
                            let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                            var entry: [String: Any] = ["keys": object.keys.sorted()]
                            for field in ["code", "message", "msg", "isSub", "subscribed", "paid", "onSale", "subCount", "isBuy", "isPurchased"] {
                                if let value = object[field] { entry[field] = value }
                            }
                            if let product = object["data"] as? [String: Any] {
                                entry["dataKeys"] = product.keys.sorted()
                                for field in ["albumId", "saleType", "albumType", "price", "saleStatus", "isBuy", "isPurchased"] {
                                    if let value = product[field] { entry[field] = value }
                                }
                            }
                            report[key] = entry
                        } catch { report[key] = ["error": error.localizedDescription] }
                    }
                }
                let artists = try await client.subscribedArtists(credential: credential)
                let collected = try await client.subscribedAlbums(credential: credential)
                report["subscribedArtistCount"] = artists.count
                report["subscribedAlbumCount"] = collected.count
                report["sampleAlbumSubscribed"] = collected.contains { $0.id == albums.first?.id }
                report["sampleArtistSubscribed"] = artists.contains { $0.id == sampleArtistID }
                let albumOnly = ProcessInfo.processInfo.arguments.contains("-albumWriteProbe")
                if ProcessInfo.processInfo.arguments.contains("-artistWriteProbe") || albumOnly,
                   let album = albumOnly ? albums.first(where: { $0.id == playableAlbumID }) : albums.first {
                    report["writeAlbumID"] = album.id
                    report["writeAlbumTitle"] = album.title
                    let artistState = artists.contains { $0.id == sampleArtistID }
                    let albumState = collected.contains { $0.id == album.id }
                    if !albumOnly {
                    do {
                        try await client.setArtistSubscribed(id: sampleArtistID, subscribed: !artistState, credential: credential)
                        let after = try await client.subscribedArtists(credential: credential)
                        report["artistWriteVerified"] = after.contains { $0.id == sampleArtistID } == !artistState
                    } catch { report["artistWriteError"] = error.localizedDescription }
                    let currentArtists = try await client.subscribedArtists(credential: credential)
                    if currentArtists.contains(where: { $0.id == sampleArtistID }) != artistState {
                        try await client.setArtistSubscribed(id: sampleArtistID, subscribed: artistState, credential: credential)
                    }
                    report["artistRestored"] = try await client.subscribedArtists(credential: credential).contains { $0.id == sampleArtistID } == artistState
                    }
                    do {
                        try await client.setAlbumSubscribed(id: album.id, subscribed: !albumState, credential: credential)
                        let after = try await client.subscribedAlbums(credential: credential)
                        report["albumWriteVerified"] = after.contains { $0.id == album.id } == !albumState
                    } catch { report["albumWriteError"] = error.localizedDescription }
                    let currentAlbums = try await client.subscribedAlbums(credential: credential)
                    if currentAlbums.contains(where: { $0.id == album.id }) != albumState {
                        try await client.setAlbumSubscribed(id: album.id, subscribed: albumState, credential: credential)
                    }
                    report["albumRestored"] = try await client.subscribedAlbums(credential: credential).contains { $0.id == album.id } == albumState
                }
            }
        } catch { report["error"] = error.localizedDescription }
        do {
            let directory = URL.applicationSupportDirectory.appendingPathComponent("ArtistReadProbe")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch { NSLog("Artist probe report failed: %@", error.localizedDescription) }
    }
}
#endif
