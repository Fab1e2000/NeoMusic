import Foundation

/// Filters music production credits, NetEase JSON metadata rows, and copyright
nonisolated enum LyricsCreditFilter {
    static func creditLineIndices(in lines: [PlayerLyricLine]) -> Set<Int> {
        let texts = lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return creditLineIndices(inTexts: texts)
    }

    static func filterPlainText(_ text: String) -> String {
        let rawLines = text.components(separatedBy: .newlines)
        let trimmed = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let credits = creditLineIndices(inTexts: trimmed)
        let kept = rawLines.enumerated().compactMap { index, line in
            credits.contains(index) ? nil : line
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func creditLineIndices(inTexts texts: [String]) -> Set<Int> {
        guard !texts.isEmpty else { return [] }
        var credits: Set<Int> = []

        for index in texts.indices {
            let text = texts[index]
            if text.isEmpty { continue }
            if isCreditLine(text, strictOnly: false) {
                credits.insert(index)
            } else {
                break
            }
        }

        for index in texts.indices.reversed() {
            let text = texts[index]
            if text.isEmpty { continue }
            if isCreditLine(text, strictOnly: false) {
                credits.insert(index)
            } else {
                break
            }
        }

        // 3. Middle fallback: only strip unambiguous structured metadata, copyright notices,
        for index in texts.indices where !credits.contains(index) {
            let text = texts[index]
            if !text.isEmpty, isCreditLine(text, strictOnly: true) {
                credits.insert(index)
            }
        }

        return credits
    }

    static func isCreditLine(_ rawText: String, strictOnly: Bool) -> Bool {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        if text.hasPrefix("{"), text.hasSuffix("}"),
           text.contains("\"tx\"") || text.contains("\"c\"") {
            return true
        }

        // Copyright / platform boilerplate notices
        let lower = text.lowercased()
        if copyrightMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        if matchesRoleCredit(text, strictOnly: strictOnly) {
            return true
        }

        return false
    }

    private static func matchesRoleCredit(_ text: String, strictOnly: Bool) -> Bool {
        guard let (rolePart, valuePart) = splitRoleAndValue(text) else { return false }
        guard !valuePart.isEmpty else { return false }
        let normalizedRole = rolePart.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedRole.isEmpty else { return false }

        if isRecognizedRole(normalizedRole, strictOnly: strictOnly) {
            return true
        }

        let separators = CharacterSet(charactersIn: "/／、&+·,，")
        let tokens = normalizedRole
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return false }
        return tokens.allSatisfy { isRecognizedRole($0, strictOnly: strictOnly) }
    }

    private static func splitRoleAndValue(_ text: String) -> (role: String, value: String)? {
        let colonDelimiters: [Character] = ["：", ":"]
        if let index = text.firstIndex(where: { colonDelimiters.contains($0) }) {
            let role = String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(text[text.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty, role.count <= 28 {
                return (role, value)
            }
        }

        let lower = text.lowercased()
        if let range = lower.range(of: " by ") {
            let role = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty, role.count <= 28 {
                return (role, value)
            }
        }

        return nil
    }

    private static func isRecognizedRole(_ role: String, strictOnly: Bool) -> Bool {
        if strictRoles.contains(role) { return true }
        if !strictOnly && edgeRoles.contains(role) { return true }
        return false
    }

    private static let copyrightMarkers: [String] = [
        "未经著作权人许可",
        "未经许可",
        "未经授权",
        "不得翻唱",
        "不得以任何方式",
        "本歌曲来自",
        "版权所有",
        "版权归",
        "纯音乐，请欣赏",
        "此歌曲为没有填词的纯音乐",
        "all rights reserved"
    ]

    private static let strictRoles: Set<String> = [
        "作词", "作曲", "编曲", "词曲", "作词人", "作曲人", "编曲人",
        "制作人", "制作", "联合制作人", "执行制作人", "配唱制作人", "音乐制作", "音乐制作人",
        "监制", "执行监制", "总监制", "音乐总监", "艺术总监", "制作统筹", "艺人统筹", "项目统筹", "统筹",
        "出品", "出品人", "出品方", "发行", "发行方", "企划", "总策划", "策划", "文案", "宣发", "宣传", "营销", "推广",
        "录音", "录音师", "录音室", "录音棚", "人声录音", "人声录音师", "人声录音室",
        "混音", "混音师", "混音室", "混音棚", "混音工程", "混音工程师",
        "母带", "母带师", "母带处理", "母带工程", "母带工程师", "母带后期", "母带后期处理",
        "和声", "和声编写", "和声演唱", "和声设计", "合声", "合声编写", "伴唱", "配唱",
        "人声编辑", "音频编辑", "修音", "声乐指导",
        "弦乐", "弦乐编写", "弦乐监制", "弦乐团", "管弦乐", "管乐", "铜管",
        "吉他", "电吉他", "木吉他", "箱琴", "贝斯", "电贝斯", "鼓", "架子鼓", "打击乐",
        "钢琴", "键盘", "合成器", "大提琴", "小提琴", "中提琴", "低音提琴",
        "笛子", "箫", "古筝", "二胡", "琵琶", "唢呐", "萨克斯", "小号", "长号", "手风琴", "口琴",
        "采样", "程序编写", "编程",
        "视觉", "视觉设计", "封面", "封面设计", "平面设计", "美工",
        "版权", "词曲版权", "版权运营", "鸣谢", "特别鸣谢",
        "翻译", "歌词翻译", "歌词制作", "滚动歌词", "lrc", "lrc制作", "op", "sp", "op/sp",
        "lyrics", "lyric", "lyricist", "words",
        "composer", "composed", "composition", "music",
        "arranger", "arranged", "arrangement",
        "producer", "produced", "executive producer", "co-producer", "vocal producer",
        "mix", "mixed", "mixing", "mixing engineer",
        "master", "mastered", "mastering", "mastering engineer",
        "recording", "recorded", "recording engineer", "recording studio", "studio",
        "vocals", "vocal", "backing vocals", "background vocals", "chorus",
        "written", "writer", "songwriter",
        "guitar", "electric guitar", "acoustic guitar", "bass", "drums", "percussion",
        "piano", "keyboard", "keyboards", "synth", "synthesizer", "strings", "cello", "violin",
        "artwork", "cover", "cover design", "credit", "credits",
        "copyright", "publisher", "publishing", "label", "distributor"
    ]

    private static let edgeRoles: Set<String> = [
        "词", "曲", "编", "唱", "演唱", "原唱", "翻唱", "歌手", "艺人",
        "歌名", "歌曲", "专辑", "合音", "主唱",
        "singer", "artist", "song", "album", "title", "by"
    ]
}
