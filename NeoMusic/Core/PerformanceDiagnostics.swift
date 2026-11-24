import Foundation
import os
import OSLog

enum AppLogger {
    fileprivate static let subsystem = "com.elsterlee.NeoMusic"

    static let playback = Logger(subsystem: subsystem, category: "Playback")
    static let playbackRestoration = Logger(subsystem: subsystem, category: "PlaybackRestoration")
    static let queueScroll = Logger(subsystem: subsystem, category: "QueueScroll")
    static let library = Logger(subsystem: subsystem, category: "Library")
    static let download = Logger(subsystem: subsystem, category: "Download")
    static let account = Logger(subsystem: subsystem, category: "Account")
    static let navigation = Logger(subsystem: subsystem, category: "Navigation")
    static let ui = Logger(subsystem: subsystem, category: "UI")

    // Error descriptions and userInfo can contain file paths, URLs, or server text.
    static func failure(_ logger: Logger, _ event: StaticString, error: any Error) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        let kind = switch error {
        case is URLError: "network"
        case is CocoaError: "file"
        case is DecodingError: "decoding"
        case is EncodingError: "encoding"
        default: "other"
        }
        logger.error("\(event.description, privacy: .public) kind=\(kind, privacy: .public) code=\((error as NSError).code)")
    }
}

enum PerformanceDiagnostics {
    typealias Interval = OSSignpostIntervalState
    private static let signposter = OSSignposter(subsystem: AppLogger.subsystem, category: "Performance")

    static func restoration(_ stage: String) {
        AppLogger.playbackRestoration.notice("\(stage, privacy: .public)")
    }

    static func queueScroll(_ message: () -> String) {
        guard AppLogger.queueScroll.isEnabled(type: .debug) else { return }
        let text = message()
        AppLogger.queueScroll.debug("\(text, privacy: .public)")
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    static func beginAnimation(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID(), "isAnimation=YES")
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}


extension DiagnosticsLogExporter {
    static func recentEntries(from start: Date, through end: Date, limit: Int) throws -> [Entry] {
        guard limit > 0, start <= end else { return [] }
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start))
        var retained: [Entry] = []
        retained.reserveCapacity(limit)
        var next = 0
        for case let entry as OSLogEntryLog in entries {
            try Task.checkCancellation()
            guard entry.subsystem == AppLogger.subsystem, (start...end).contains(entry.date) else { continue }
            let level = switch entry.level {
            case .debug: "debug"
            case .info: "info"
            case .notice: "notice"
            case .error: "error"
            case .fault: "fault"
            case .undefined: "undefined"
            @unknown default: "unknown"
            }
            let record = Entry(date: entry.date, category: entry.category, level: level, message: entry.composedMessage)
            if retained.count < limit {
                retained.append(record)
            } else {
                retained[next] = record
                next = (next + 1) % limit
            }
        }
        return Array(retained[next...]) + retained[..<next]
    }
}
