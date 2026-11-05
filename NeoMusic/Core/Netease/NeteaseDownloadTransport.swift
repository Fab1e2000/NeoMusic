import Foundation

/// The system owns transfer scheduling, connectivity waiting and background resumption.
@MainActor
final class NeteaseDownloadTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(UUID, Double), waiting(UUID), completed(UUID, URL), failed(UUID, String, cancelled: Bool)
    }
    static let identifier = "com.elsterlee.NeoMusic.downloads"
    private static var backgroundCompletion: (() -> Void)?
    static func handleEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.identifier else { completion(); return }
        backgroundCompletion = completion
    }

    var onEvent: ((Event) -> Void)?
    var onFinishedEvents: (() async -> Void)?
    nonisolated let spool: URL
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    private struct CancellationBatch {
        var remaining: Set<Int>
        let continuation: CheckedContinuation<Void, Never>
    }
    private var cancellationBatches: [UUID: CancellationBatch] = [:]

    init(spool: URL, configuration: URLSessionConfiguration? = nil) {
        self.spool = spool
        let value = configuration ?? URLSessionConfiguration.background(withIdentifier: Self.identifier)
        value.isDiscretionary = false
        value.sessionSendsLaunchEvents = true
        value.httpMaximumConnectionsPerHost = 3
        value.timeoutIntervalForResource = 7 * 24 * 60 * 60
        self.configuration = value
        super.init()
    }

    func activeIDs() async -> Set<UUID> {
        Set(await session.allTasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
    }

    func start(id: UUID, url: URL, allowsCellular: Bool) {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = allowsCellular
        let task = session.downloadTask(with: request)
        task.taskDescription = id.uuidString
        task.resume()
    }

    func cancel(ids: Set<UUID>) async {
        let tasks = await session.allTasks.filter {
            $0.state != .completed && $0.taskDescription.flatMap(UUID.init(uuidString:)).map(ids.contains) == true
        }
        guard !tasks.isEmpty else { return }
        await withCheckedContinuation { continuation in
            cancellationBatches[UUID()] = .init(remaining: Set(tasks.map(\.taskIdentifier)), continuation: continuation)
            for task in tasks { task.cancel() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                               totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)), totalBytesExpectedToWrite > 0 else { return }
        let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        Task { @MainActor [weak self] in self?.onEvent?(.progress(id, progress)) }
    }

    nonisolated func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        Task { @MainActor [weak self] in self?.onEvent?(.waiting(id)) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        // This temporary URL expires when this delegate method returns.
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { throw NeteaseDownloadError.invalidFile }
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            let file = spool.appendingPathComponent(id.uuidString + ".transfer")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            try FileManager.default.moveItem(at: location, to: file)
            Task { @MainActor [weak self] in self?.onEvent?(.completed(id, file)) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.onEvent?(.failed(id, message, cancelled: false)) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let id = task.taskDescription.flatMap(UUID.init(uuidString:)), taskID = task.taskIdentifier
        let message = error?.localizedDescription
        let cancelled = (error as? URLError)?.code == .cancelled
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let id, let message { self.onEvent?(.failed(id, message, cancelled: cancelled)) }
            for id in Array(self.cancellationBatches.keys) {
                self.cancellationBatches[id]?.remaining.remove(taskID)
                if self.cancellationBatches[id]?.remaining.isEmpty == true {
                    self.cancellationBatches.removeValue(forKey: id)?.continuation.resume()
                }
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            await self?.onFinishedEvents?()
            let completion = Self.backgroundCompletion
            Self.backgroundCompletion = nil
            completion?()
        }
    }
}
