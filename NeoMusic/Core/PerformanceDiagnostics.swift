import os

enum AppLogger {
    fileprivate static let subsystem = "com.elsterlee.NeoMusic"

    static let playback = Logger(subsystem: subsystem, category: "Playback")
    static let playbackRestoration = Logger(subsystem: subsystem, category: "PlaybackRestoration")
    static let queueScroll = Logger(subsystem: subsystem, category: "QueueScroll")
    static let library = Logger(subsystem: subsystem, category: "Library")
    static let account = Logger(subsystem: subsystem, category: "Account")
    static let navigation = Logger(subsystem: subsystem, category: "Navigation")
    static let ui = Logger(subsystem: subsystem, category: "UI")
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
