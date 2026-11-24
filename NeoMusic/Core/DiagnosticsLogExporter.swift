import Foundation

enum DiagnosticsLogExporter {
    struct Entry: Sendable {
        let date: Date
        let category: String
        let level: String
        let message: String
    }

    @concurrent static func report(window: TimeInterval = 15 * 60, limit: Int = 500) async throws -> String {
        try Task.checkCancellation()
        let end = Date()
        let interval = window.isFinite ? min(max(0, window), 24 * 60 * 60) : 0
        let start = end.addingTimeInterval(-interval)
        let maximum = min(max(0, limit), 2_000)
        let logs = maximum > 0 ? try recentEntries(from: start, through: end, limit: maximum) : []
        let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        var lines = [
            "NeoMusic diagnostics v1",
            "from=\(iso.format(start)) through=\(iso.format(end)) records=\(logs.count) limit=\(maximum)"
        ]
        for entry in logs {
            try Task.checkCancellation()
            lines.append("\(iso.format(entry.date)) [\(singleLine(entry.category))] \(entry.level) \(singleLine(entry.message))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func singleLine(_ value: String) -> String {
        sanitize(value).components(separatedBy: .newlines).joined(separator: " ")
    }

    private static let redactions = [
        // Headers may contain several short cookie values or folded continuation lines.
        #"(?i)\b(?:set-cookie|cookie|proxy-authorization|authorization)["']?[ \t]*[:=][^\r\n]*(?:(?:\r\n|\r|\n)[ \t]+[^\r\n]*)*"#,
        #"(?i)(?<![\w/])(?:file:(?:\\?/){2})?(?:\\?/)(?:Users|home|Volumes|private|var|tmp|Applications|Library)(?:\\?/)[^\r\n]*"#,
        #"(?i)\b[a-z][a-z0-9+.-]*(?::(?:\\?/){2}|%3a(?:%2f){2})[^\r\n]*"#,
        #"(?i)(?<![\w-])(?:music_u|__csrf|nmtid|access[_-]?token|refresh[_-]?token|id[_-]?token|token|password|passwd|secret|email|phone|mobile)["']?[ \t]*[:=][ \t]*(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;}&]+)?"#,
        #"(?i)\b(?:bearer|basic)[ \t]+[a-z0-9_.+/=-]+"#,
        #"(?i)[a-z0-9.!#$%&'*+/=?^_{}|~-]+@[a-z0-9.-]+\.[a-z]{2,}"#,
        #"(?<![\w.])\+?(?:\(?[0-9]\)?[ \t.-]*){6,14}[0-9](?![\w.])"#,
        #"(?<![a-zA-Z0-9_+/=-])[a-zA-Z0-9_+/=-]{24,}(?![a-zA-Z0-9_+/=-])"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func sanitize(_ value: String) -> String {
        redactions.reduce(value) { result, rule in
            rule.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                          withTemplate: "[REDACTED]")
        }
    }
}
