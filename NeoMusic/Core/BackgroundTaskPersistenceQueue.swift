import UIKit

@MainActor
final class BackgroundTaskPersistenceQueue {
    private var pending: Task<Void, Never>?
    private var revision = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var isFlushingInBackground = false

    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = pending
        revision += 1
        let current = revision
        pending = Task {
            await previous?.value
            await work()
            if revision == current { pending = nil }
        }
    }

    func startIfIdle(_ work: @escaping @MainActor () async -> Void) {
        guard pending == nil else { return }
        enqueue(work)
    }

    func flush() async {
        while let task = pending { await task.value }
    }

    func saveInBackground(named name: String, schedule: () -> Void) {
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                self?.endBackgroundTask()
            }
        }
        schedule()
        guard !isFlushingInBackground else { return }
        isFlushingInBackground = true
        Task {
            await flush()
            endBackgroundTask()
            isFlushingInBackground = false
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let identifier = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
