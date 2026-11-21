import Foundation

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
