import Foundation

struct NeteaseDailySnapshot: Codable, Sendable, Identifiable {
    let id: String
    let date: String
    let songs: [NeteaseMusicSong]

    init(date: String, songs: [NeteaseMusicSong], id: String = UUID().uuidString) {
        self.id = id; self.date = date; self.songs = songs
    }
    private enum CodingKeys: String, CodingKey { case id, date, songs }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(String.self, forKey: .date)
        songs = try values.decode([NeteaseMusicSong].self, forKey: .songs)
        id = try values.decodeIfPresent(String.self, forKey: .id) ?? date
    }
}
