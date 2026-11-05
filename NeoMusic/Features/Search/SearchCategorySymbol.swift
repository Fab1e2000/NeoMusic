import SwiftUI

/// Apple SF Symbols, with one shared weight, rendering mode and placement.
struct SearchCategorySymbol: View {
    let category: String

    private var symbol: String {
        switch category {
        case "流行", "快乐", "兴奋", "综艺", "KTV", "榜单": "sparkles"
        case "摇滚", "金属", "朋克", "游戏": "bolt"
        case "民谣", "乡村", "英伦": "mountain.2"
        case "吉他": "music.note"
        case "电子", "舞曲", "说唱", "雷鬼", "拉丁": "waveform"
        case "轻音乐", "钢琴", "古典", "器乐": "pianokeys"
        case "夜晚", "孤独", "安静", "伤感", "思念": "moon.stars"
        case "学习", "工作", "校园": "book.closed"
        case "运动", "驾车", "地铁": "figure.run"
        case "怀旧", "爵士", "蓝调", "R&B/Soul", "经典", "翻唱", "70后", "80后", "90后": "opticaldisc"
        case "清新", "散步", "下午茶", "Bossa Nova", "New Age": "leaf"
        case "治愈", "放松", "清晨", "午休", "浪漫", "感动": "sun.horizon"
        case "旅行", "世界音乐", "民族": "globe"
        default: "mic"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.light)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white.opacity(0.4))
            .frame(width: 68, height: 68)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
