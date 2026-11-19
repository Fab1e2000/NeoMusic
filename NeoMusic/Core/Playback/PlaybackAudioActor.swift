import Foundation

/// Dedicated serial execution domain for all CoreAudio, AVAudioEngine,
/// AVAudioFile, and AudioStreaming operations so playback backend work
/// never contends with `@MainActor` UI animations.
@globalActor
actor PlaybackAudioActor {
    static let shared = PlaybackAudioActor()

    private let executor = PlaybackAudioSerialExecutor()

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
}

private final class PlaybackAudioSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchSerialQueue(
        label: "com.neomusic.playback.audio",
        qos: .userInitiated
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        queue.async {
            unowned.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
