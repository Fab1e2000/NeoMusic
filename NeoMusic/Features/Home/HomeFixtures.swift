import Foundation

enum HomeArtworkSource: Sendable {
    case image(String)
    case favorites
    case newMusic
    case station(Int)
    case collage(Int)
    case mood(HomeMood)
}

enum HomeMood: String, CaseIterable, Sendable {
    case happy, heart, love, night, focus, relax
    var title: String {
        switch self {
        case .happy: "开心能量棒"
        case .heart: "心碎"
        case .love: "爱情"
        case .night: "深夜放松"
        case .focus: "凝神专注"
        case .relax: "乐享悠闲"
        }
    }
}

struct HomeItem: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artwork: HomeArtworkSource
    var eyebrow: String? = nil
}

struct HomeSection: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [HomeItem]
    var largeCards = false
}

/// Fixed local content keeps scroll positions and visual comparisons repeatable.
/// These are presentation fixtures, independent of the library and playback models.
enum HomeFixtures {
    private static let albums: [(String, String)] = [
        ("我的流动", "晴空乐队"), ("月初日暮", "夜航"), ("生息", "远山"),
        ("空想劇", "空想音楽室"), ("Koyoricollection4", "koyori"), ("依如初见", "春日来信"),
        ("塌陷于 38°C 的蓝", "46"), ("切札", "Virtual Notes"), ("情绪之花终将盛开", "花谱"),
        ("色彩", "深夜电台"), ("Starlit Whispers", "Luminous"), ("BREATHE", "Sora"),
        ("[Others]", "After Hours"), ("Nanakorobi Nanaoki", "Nanashi"), ("Colors of the Rain", "雨の音"),
        ("Eternal Journey", "Sound Horizon"), ("NEW ROMANCER", "RIM"), ("Our Days", "晴れの日"),
        ("消えるまで", "夜明け"), ("ASU", "ASU"), ("We Call It the Deity", "Rei"),
        ("CosmoNote 7th", "CosmoNote"), ("Horologium Florae", "花時計")
    ]

    private static func album(_ number: Int) -> HomeItem {
        let metadata = albums[number - 1]
        return HomeItem(id: "album-\(number)", title: metadata.0, subtitle: metadata.1,
                        artwork: .image(String(format: "AlbumSample%02d", number)))
    }

    private static func shelf(_ id: String, _ title: String, _ numbers: [Int]) -> HomeSection {
        HomeSection(id: id, title: title, items: numbers.map(album))
    }

    static let sections: [HomeSection] = [
        HomeSection(id: "featured", title: "专属精选推荐", items: [
            HomeItem(id: "favorites", title: "喜爱歌曲", subtitle: "所有激励你追逐梦想的歌曲。", artwork: .favorites, eyebrow: "由你制作"),
            HomeItem(id: "recent-album", title: "NEW ROMANCER", subtitle: "RIM", artwork: .image("AlbumSample17"), eyebrow: "最近添加"),
            HomeItem(id: "personal-station", title: "Elster Lee 的电台", subtitle: "你的音乐，你的专属频道。", artwork: .station(0), eyebrow: "为你推荐"),
            HomeItem(id: "artist-station", title: "晴空乐队与类似艺人", subtitle: "", artwork: .collage(0), eyebrow: "晴空乐队参与的作品"),
            HomeItem(id: "night-station", title: "宵夜 Mpa 与类似艺人", subtitle: "", artwork: .collage(1), eyebrow: "宵夜 Mpa 参与的作品")
        ], largeCards: true),
        shelf("recent", "最近播放", [17, 7, 1, 8, 20, 19]),
        shelf("jpop", "J-Pop", [4, 20, 14, 18, 21, 22]),
        HomeSection(id: "playlists", title: "专属推荐歌单", items: [
            HomeItem(id: "new-music", title: "音乐新发现", subtitle: "梦限大みゅーたいぷ、BEMA、Technopop Organic Synthesizer-Chan、Azsagawa 和以及其他", artwork: .newMusic)
        ], largeCards: true),
        shelf("fans", "宵夜 Mpa 的粉丝喜爱的内容", [17, 9, 23, 18, 10, 12]),
        HomeSection(id: "stations", title: "专属电台推荐", items: [
            HomeItem(id: "personal", title: "Elster Lee 的电台", subtitle: "广播电台", artwork: .station(0)),
            HomeItem(id: "discovery", title: "探索电台", subtitle: "广播电台", artwork: .station(1)),
            HomeItem(id: "sunny", title: "晴空乐队与类似艺人", subtitle: "广播电台", artwork: .collage(0)),
            HomeItem(id: "night", title: "宵夜 Mpa 与类似艺人", subtitle: "广播电台", artwork: .collage(1)),
            HomeItem(id: "rim", title: "RIM 与类似艺人", subtitle: "广播电台", artwork: .image("AlbumSample17")),
            HomeItem(id: "asu", title: "ASU 与类似艺人", subtitle: "广播电台", artwork: .image("AlbumSample20"))
        ]),
        HomeSection(id: "moods", title: "心情主场", items: HomeMood.allCases.map {
            HomeItem(id: $0.rawValue, title: $0.title, subtitle: "广播电台", artwork: .mood($0))
        }),
        shelf("chinese-rock", "华语摇滚", [23, 9, 18, 13, 2, 6]),
        shelf("mandarin", "国语流行", [10, 5, 12, 1, 6, 3]),
        shelf("vocaloid", "Vocaloid 代表专辑", [8, 22, 16, 4, 5, 21]),
        shelf("2000s", "2000 年代", [17, 16, 19, 13, 12, 14]),
        shelf("anime", "二次元音乐", [21, 15, 11, 8, 20, 22]),
        shelf("games", "电子游戏音乐", [9, 23, 4, 11, 15, 16]),
        shelf("jrock", "日语摇滚", [8, 13, 20, 17, 19, 18]),
        shelf("2010s", "2010 年代", [14, 18, 12, 21, 10, 7])
    ]
}
