import Foundation

struct LyricsLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct LyricsDocument: Equatable, Sendable {
    var lines: [LyricsLine] = []
    var plainText = ""
    var source = ""
    var isEmpty: Bool { lines.isEmpty && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func activeLine(at time: TimeInterval) -> Int? {
        lines.last(where: { $0.time <= time })?.id
    }

    /// Parse bracket prefixes rather than interpreting text after the timestamp as markup.
    static func parse(_ text: String) -> Self {
        var offset = 0.0
        var timed: [(Double, String)] = []
        var plain: [String] = []
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            var remainder = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var times: [Double] = []
            var metadataOnly = false
            while remainder.first == "[", let end = remainder.firstIndex(of: "]") {
                let token = String(remainder[remainder.index(after: remainder.startIndex)..<end])
                let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0].lowercased() == "offset", let value = Double(parts[1].trimmingCharacters(in: .whitespaces)) {
                    offset = value / 1000
                    metadataOnly = true
                } else if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]), minutes >= 0, seconds >= 0, seconds < 60 {
                    times.append(minutes * 60 + seconds)
                } else if parts.count == 2, ["ar", "al", "ti", "by", "length"].contains(parts[0].lowercased()) {
                    metadataOnly = true
                } else { break }
                remainder = String(remainder[remainder.index(after: end)...]).trimmingCharacters(in: .whitespaces)
            }
            if !times.isEmpty { timed.append(contentsOf: times.map { ($0, remainder) }) }
            else if !metadataOnly && !remainder.isEmpty { plain.append(remainder) }
        }
        let sorted = timed.enumerated().sorted { a, b in a.element.0 == b.element.0 ? a.offset < b.offset : a.element.0 < b.element.0 }
        let lines = sorted.enumerated().map { index, entry in LyricsLine(id: index, time: max(0, entry.element.0 + offset), text: entry.element.1) }
        return Self(lines: lines, plainText: lines.isEmpty ? plain.joined(separator: "\n") : lines.map(\.text).joined(separator: "\n"))
    }
}
