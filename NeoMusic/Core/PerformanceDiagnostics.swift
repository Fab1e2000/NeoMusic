import os

/// Native Instruments intervals; payloads never contain account or media identities.
enum PerformanceDiagnostics {
    typealias Interval = OSSignpostIntervalState
    private static let signposter = OSSignposter(subsystem: "com.elsterlee.NeoMusic", category: "Performance")

    private static let restorationLogger = Logger(subsystem: "com.elsterlee.NeoMusic", category: "PlaybackRestoration")

    /// Stages and aggregate state only; callers must not include account or song identities.
    static func restoration(_ stage: String) {
        restorationLogger.notice("\(stage, privacy: .public)")
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
