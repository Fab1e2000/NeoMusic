import Foundation

struct LyricsLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: TimeInterval
    let text: String
    var translation: String = ""
}

struct LyricsDocument: Equatable, Sendable {
    var lines: [LyricsLine] = []
    var plainText = ""
    var source = ""
    var isEmpty: Bool { lines.isEmpty && plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func activeLine(at time: TimeInterval) -> Int? {
        lines.last(where: { $0.time <= time })?.id
    }

    private struct ParsedEntry {
        let rawTime: TimeInterval
        let time: TimeInterval
        let text: String
    }

    private struct ParsedLineTokens {
        let times: [TimeInterval]
        let remainder: String
        let metadataOnly: Bool
        let offsetSeconds: Double?
    }

    private static let translationMatchToleranceMS = 50
    private typealias TimedText = (index: Int, ms: Int, text: String)

    /// Parse bracket prefixes rather than interpreting text after the timestamp as markup.
    static func parse(_ text: String) -> Self {
        let parsed = parseEntries(text)
        let lines = parsed.entries.enumerated().map { index, entry in
            LyricsLine(id: index, time: entry.time, text: entry.text)
        }
        return Self(lines: lines, plainText: lines.isEmpty ? parsed.plain.joined(separator: "\n") : lines.map(\.text).joined(separator: "\n"))
    }

    /// Separates an original LRC document from its translation inside one stored file.
    static let storedTranslationMarker = "[neomusic:translation]"

    static func storedText(original: String, translation: String) -> String {
        let translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translation.isEmpty else { return original }
        return original + "\n" + storedTranslationMarker + "\n" + translation
    }

    static func decodeStored(_ text: String) -> Self {
        decodeSingleStream(text, source: "")
    }

    static func merge(original: String, translation: String, source: String = "") -> Self {
        let translated = parse(translation)
        let hasTranslatedLines = translated.lines.contains { !$0.text.isEmpty }
        guard hasTranslatedLines else {
            return decodeSingleStream(original, source: source)
        }
        let base = parse(original)
        guard !base.lines.isEmpty else { return base }
        let lines = attachTranslations(base.lines, from: translated.lines)
        return Self(lines: lines, plainText: lines.map(\.text).joined(separator: "\n"), source: source)
    }

    private static func decodeSingleStream(_ text: String, source: String) -> Self {
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")

        if let markerIndex = rawLines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == storedTranslationMarker
        }) {
            let original = rawLines[..<markerIndex].joined(separator: "\n")
            let translation = rawLines[(markerIndex + 1)...].joined(separator: "\n")
            return merge(original: original, translation: translation, source: source)
        }

        if let split = splitStackedBilingualLines(rawLines) {
            return merge(original: split.original, translation: split.translation, source: source)
        }

        let parsed = parseEntries(normalized)
        if let folded = foldInterleavedTranslations(parsed.entries) {
            return Self(lines: folded, plainText: folded.map(\.text).joined(separator: "\n"), source: source)
        }

        let lines = parsed.entries.enumerated().map { index, entry in
            LyricsLine(id: index, time: entry.time, text: entry.text)
        }
        return Self(
            lines: lines,
            plainText: lines.isEmpty ? parsed.plain.joined(separator: "\n") : lines.map(\.text).joined(separator: "\n"),
            source: source
        )
    }

    private static func parseEntries(_ text: String) -> (entries: [ParsedEntry], plain: [String]) {
        var offsetSeconds = 0.0
        var timedLines: [(time: TimeInterval, text: String)] = []
        var plain: [String] = []
        for raw in text.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            let parsed = parseLineTokens(raw)
            if let offset = parsed.offsetSeconds { offsetSeconds = offset }
            if !parsed.times.isEmpty {
                timedLines.append(contentsOf: parsed.times.map { ($0, parsed.remainder) })
            } else if !parsed.metadataOnly && !parsed.remainder.isEmpty {
                plain.append(parsed.remainder)
            }
        }
        let sortedLines = timedLines.enumerated().sorted { lhs, rhs in
            if lhs.element.time == rhs.element.time {
                return lhs.offset < rhs.offset
            }
            return lhs.element.time < rhs.element.time
        }
        // Keep the original timing if the offset would put any line outside the
        // representable range. Validate the greatest time because the shift is monotonic.
        if let last = sortedLines.last, milliseconds(max(0, last.element.time - offsetSeconds)) == nil {
            offsetSeconds = 0
        }
        let entries = sortedLines.map { _, entry in
            // Positive LRC offsets advance lyrics; negative offsets delay them.
            ParsedEntry(rawTime: entry.time, time: max(0, entry.time - offsetSeconds), text: entry.text)
        }
        return (entries, plain)
    }

    private static func parseLineTokens(_ raw: String) -> ParsedLineTokens {
        var remainder = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var times: [TimeInterval] = []
        var metadataOnly = false
        var offsetSeconds: Double?
        while remainder.first == "[", let end = remainder.firstIndex(of: "]") {
            let token = String(remainder[remainder.index(after: remainder.startIndex)..<end])
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "offset" {
                if let value = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                   Int(exactly: value.rounded()) != nil {
                    offsetSeconds = value / 1000
                }
                metadataOnly = true
            } else if parts.count == 2, let timestamp = parseTimestamp(minutesPart: parts[0], secondsPart: parts[1]) {
                times.append(timestamp)
            } else if parts.count == 2, ["ar", "al", "ti", "by", "length"].contains(parts[0].lowercased()) {
                metadataOnly = true
            } else { break }
            remainder = String(remainder[remainder.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        return ParsedLineTokens(times: times, remainder: remainder, metadataOnly: metadataOnly, offsetSeconds: offsetSeconds)
    }

    private static func parseTimestamp(minutesPart: String, secondsPart: String) -> TimeInterval? {
        guard let minutes = Double(minutesPart), minutes >= 0, minutes.isFinite else { return nil }
        let seconds: Double
        if let value = Double(secondsPart) {
            seconds = value
        } else {
            let subparts = secondsPart.split(separator: ":", omittingEmptySubsequences: false)
            guard subparts.count == 2,
                  !subparts[0].isEmpty, !subparts[1].isEmpty, subparts[1].count <= 3,
                  subparts[0].allSatisfy({ $0.isASCII && $0.isNumber }),
                  subparts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Double("\(subparts[0]).\(subparts[1])") else { return nil }
            seconds = value
        }
        guard seconds >= 0, seconds < 60 else { return nil }
        let time = minutes * 60 + seconds
        return milliseconds(time) == nil ? nil : time
    }

    private static func milliseconds(_ time: TimeInterval) -> Int? {
        Int(exactly: (time * 1000).rounded())
    }

    private static func timedText(_ lines: [LyricsLine]) -> [TimedText] {
        lines.enumerated().compactMap { index, line in
            guard !line.text.isEmpty, let ms = milliseconds(line.time) else { return nil }
            return (index, ms, line.text)
        }
    }

    /// Parsed lines are ordered by timestamp. Limit matching to the tolerance
    /// window while retaining order and allowing equal-distance ties.
    private static func nearbyText(in lines: [TimedText], at ms: Int) -> ArraySlice<TimedText> {
        var lower = 0
        var upper = lines.count
        let earliest = ms - translationMatchToleranceMS
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if lines[middle].ms < earliest {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        // Compare a difference so the upper bound cannot overflow near Int.max.
        return lines[lower...].prefix { $0.ms - ms <= translationMatchToleranceMS }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func attachTranslations(_ baseLines: [LyricsLine], from translatedLines: [LyricsLine]) -> [LyricsLine] {
        var exactByMS: [Int: [String]] = [:]
        let nonEmptyTranslated = timedText(translatedLines)
        for line in nonEmptyTranslated {
            exactByMS[line.ms, default: []].append(line.text)
        }

        var matchedByBaseIndex: [[String]] = Array(repeating: [], count: baseLines.count)
        var matchedMS = Set<Int>()
        for (index, line) in baseLines.enumerated() {
            guard let ms = milliseconds(line.time) else { continue }
            let exact = exactByMS[ms, default: []].filter { !$0.isEmpty && $0 != line.text }
            if !exact.isEmpty {
                matchedByBaseIndex[index] = deduplicated(exact)
                matchedMS.insert(ms)
            }
        }

        let unmatchedTranslated = nonEmptyTranslated.filter { !matchedMS.contains($0.ms) }
        if !unmatchedTranslated.isEmpty {
            let eligibleBase = timedText(baseLines).filter { matchedByBaseIndex[$0.index].isEmpty }
            for item in unmatchedTranslated {
                var bestIndex: Int?
                var bestDistance = translationMatchToleranceMS + 1
                var ambiguous = false
                for candidate in nearbyText(in: eligibleBase, at: item.ms) where candidate.text != item.text {
                    let distance = abs(candidate.ms - item.ms)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = candidate.index
                        ambiguous = false
                    } else if distance == bestDistance {
                        ambiguous = true
                    }
                }
                if let bestIndex, !ambiguous, !matchedByBaseIndex[bestIndex].contains(item.text) {
                    matchedByBaseIndex[bestIndex].append(item.text)
                }
            }
        }

        return baseLines.enumerated().map { index, line in
            LyricsLine(
                id: line.id,
                time: line.time,
                text: line.text,
                translation: matchedByBaseIndex[index].joined(separator: "\n")
            )
        }
    }

    private static func splitStackedBilingualLines(_ rawLines: [String]) -> (original: String, translation: String)? {
        let tokenized = rawLines.map(parseLineTokens)
        var maxSeenEarliest: TimeInterval?
        var timedLinesSeen = 0
        var candidateSplits: [Int] = []

        for (index, token) in tokenized.enumerated() {
            guard let earliest = token.times.min() else { continue }
            if let previousMax = maxSeenEarliest, timedLinesSeen >= 1, earliest < previousMax - 0.001 {
                var splitStart = index
                while splitStart > 0 {
                    let previous = tokenized[splitStart - 1]
                    if previous.times.isEmpty && (previous.metadataOnly || previous.remainder.isEmpty) {
                        splitStart -= 1
                    } else {
                        break
                    }
                }
                if candidateSplits.last != splitStart {
                    candidateSplits.append(splitStart)
                }
            }
            maxSeenEarliest = max(maxSeenEarliest ?? earliest, earliest)
            timedLinesSeen += 1
        }

        for splitStart in candidateSplits {
            let firstText = rawLines[..<splitStart].joined(separator: "\n")
            let secondText = rawLines[splitStart...].joined(separator: "\n")
            let base = parse(firstText)
            let second = parse(secondText)
            let baseNonEmpty = timedText(base.lines)
            let secondNonEmpty = timedText(second.lines)
            guard !baseNonEmpty.isEmpty, !secondNonEmpty.isEmpty else { continue }

            var matched = 0
            var nonZeroMatched = 0
            for candidate in secondNonEmpty {
                if nearbyText(in: baseNonEmpty, at: candidate.ms).contains(where: { $0.text != candidate.text }) {
                    matched += 1
                    if candidate.ms > 0 { nonZeroMatched += 1 }
                }
            }

            let baseUniqueNonEmptyTimes = Set(baseNonEmpty.map(\.ms)).count
            let qualifies = matched * 4 >= secondNonEmpty.count * 3
                && (nonZeroMatched >= 2 || (nonZeroMatched == 1 && secondNonEmpty.count == 1 && baseUniqueNonEmptyTimes == 1))
            if qualifies {
                return (firstText, secondText)
            }
        }
        return nil
    }

    private static func foldInterleavedTranslations(_ entries: [ParsedEntry]) -> [LyricsLine]? {
        guard entries.count >= 2 else { return nil }
        struct Group {
            let rawMS: Int
            let time: TimeInterval
            var texts: [String]
        }
        var groups: [Group] = []
        groups.reserveCapacity(entries.count)
        for entry in entries {
            guard let rawMS = milliseconds(entry.rawTime) else { continue }
            if let lastIndex = groups.indices.last, groups[lastIndex].rawMS == rawMS {
                groups[lastIndex].texts.append(entry.text)
            } else {
                groups.append(Group(rawMS: rawMS, time: entry.time, texts: [entry.text]))
            }
        }

        var nonZeroNonEmptyGroups = 0
        var nonZeroPairedGroups = 0
        let distinctTextsPerGroup: [[String]] = groups.map { group in
            let distinct = deduplicated(group.texts.filter { !$0.isEmpty })
            if group.rawMS > 0, !distinct.isEmpty {
                nonZeroNonEmptyGroups += 1
                if distinct.count >= 2 { nonZeroPairedGroups += 1 }
            }
            return distinct
        }

        let qualifies = nonZeroPairedGroups >= 2
            || (nonZeroPairedGroups == 1 && nonZeroNonEmptyGroups == 1)
        guard qualifies else { return nil }

        return groups.enumerated().map { index, group in
            let distinct = distinctTextsPerGroup[index]
            let primary = distinct.first ?? ""
            let translation = distinct.dropFirst().joined(separator: "\n")
            return LyricsLine(id: index, time: group.time, text: primary, translation: translation)
        }
    }
}
