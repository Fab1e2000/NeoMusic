import Foundation

/// 最近添加按加入资料库的时间从新到旧排列。单曲卡片不指向专辑。
enum LibraryRecentAdditions {
    /// 本地文件用加入时间的 Unix 秒数作为 `addedOrder`；更小的值只表示相对顺序。
    static let datedOrderThreshold = 1_000_000_000

    static func ordered(collections: [(LibraryShelfItem, Date?)], songs: [(LibrarySongItem, Date?)]) -> [LibraryShelfItem] {
        var ranked: [(item: LibraryShelfItem, date: Date?, order: Int)] = collections.map { item, date in
            (item, date, item.addedOrder)
        }
        var songsByID: [String: (song: LibrarySongItem, addedAt: Date?)] = [:]
        for (song, addedAt) in songs {
            let previous = songsByID[song.id]
            let latestAddedAt = [previous?.addedAt, addedAt].compactMap { $0 }.max()
            let preferredSong: LibrarySongItem
            if !song.isFavorite, let previous, previous.song.isFavorite {
                preferredSong = previous.song
            } else {
                preferredSong = song
            }
            songsByID[song.id] = (preferredSong, latestAddedAt)
        }
        for (song, date) in songsByID.values {
            let item = songShelfItem(song, date: date)
            ranked.append((item, date, item.addedOrder))
        }
        return ranked.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            case (nil, nil) where lhs.order != rhs.order: return lhs.order > rhs.order
            default: return lhs.item.id < rhs.item.id
            }
        }.map(\.item)
    }

    static func date(forAddedOrder order: Int) -> Date? {
        guard order >= datedOrderThreshold else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(order))
    }

    private static func songShelfItem(_ song: LibrarySongItem, date: Date?) -> LibraryShelfItem {
        LibraryShelfItem(id: "recent-song:\(song.id)", title: song.title, subtitle: song.artist, artwork: song.artwork,
                         isFavorite: song.isFavorite, addedOrder: date.map { Int($0.timeIntervalSince1970) } ?? 0, songID: song.id)
    }
}
