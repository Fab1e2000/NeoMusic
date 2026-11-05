#if DEBUG
import Foundation

/// Explicit single-download device validation. The report contains no account or music identities.
@MainActor enum NeteaseDownloadReadProbe {
    private static var hasRun = false

    static func run(store: NeteaseDownloadStore) async {
        guard ProcessInfo.processInfo.arguments.contains("-downloadReadProbe"), !hasRun else { return }
        hasRun = true
        var report: [String: Any] = ["phase": "selecting", "hasSession": store.userID != nil,
                                   "candidateCount": 0, "enqueuedCount": 0, "completed": false,
                                   "requestedQuality": store.quality.rawValue]
        write(report)
        do {
            let candidate = try await store.readProbeCandidate { count in
                report["candidateCount"] = count; write(report)
            }
            report["sourceDeclaredFormat"] = candidate.declaredType
            report["phase"] = "enqueuing"; write(report)
            let observer = CompletionObserver(store: store, songID: candidate.id) { state in
                switch state {
                case .queued: report["phase"] = "queued"
                case .waiting: report["phase"] = "waiting"
                case .downloading(let value):
                    report["phase"] = "downloading"
                    report["progressPercent"] = Int(value * 100)
                case .processing: report["phase"] = "processing"
                case .downloaded: report["phase"] = "verifying"
                case .failed: report["phase"] = "failed"
                }
                write(report)
            }
            defer { observer.detach() }
            try await store.enqueue(songIDs: [candidate.id])
            report["enqueuedCount"] = 1
            switch await observer.wait(timeout: .seconds(90)) {
            case .completed:
                guard let file = store.resource(songID: candidate.id), let record = store.records[candidate.id] else {
                    throw NeteaseDownloadError.invalidFile
                }
                let tags = try await DownloadedAudioTags.read(file)
                let input = try FileHandle(forReadingFrom: file)
                defer { try? input.close() }
                let bytes = try input.read(upToCount: 8) ?? Data()
                let format: String
                if bytes.starts(with: Data("fLaC".utf8)) { format = "flac" }
                else if bytes.starts(with: Data("ID3".utf8)) ||
                    (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0) { format = "mp3" }
                else { format = "unknown" }
                report["completed"] = true; report["phase"] = "complete"
                report["detectedOutputFormat"] = format
                report["formatMatchesExtension"] = file.pathExtension.lowercased() == format
                report["actualQuality"] = record.quality.rawValue
                report["bytes"] = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                report["titleMatches"] = tags.title == record.song.title
                report["artistMatches"] = tags.artist == record.song.artist
                report["albumMatches"] = tags.album == record.song.album
                report["hasEmbeddedCover"] = tags.artwork?.isEmpty == false
                report["hasEmbeddedLyrics"] = tags.lyrics?.isEmpty == false
                report["hasLyricSidecar"] = store.lyricsURL(songID: candidate.id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                report["filePreserved"] = true
            case .failed:
                report["phase"] = "failed"; report["error"] = "download_failed"
            case .timeout:
                report["phase"] = "timeout"; report["error"] = "completion_timeout"
                report["downloadContinues"] = true
            case .cancelled:
                report["phase"] = "cancelled"; report["error"] = "probe_cancelled"
            }
        } catch {
            report["phase"] = "failed"
            // NSError descriptions can contain request URLs and filesystem names; keep only type and numeric code.
            report["errorType"] = String(reflecting: type(of: error))
            report["errorCode"] = (error as NSError).code
        }
        write(report)
    }

    private static func write(_ report: [String: Any]) {
        do {
            let directory = URL.applicationSupportDirectory.appending(path: "DownloadReadProbe", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: directory.appending(path: "result.json"), options: .atomic)
        } catch { print("DownloadReadProbe: report write failed") }
    }

    @MainActor private final class CompletionObserver {
        enum Outcome { case completed, failed, timeout, cancelled }
        private weak var store: NeteaseDownloadStore?
        private let songID: Int64
        private let previous: (() -> Void)?
        private let progress: (NeteaseDownloadState) -> Void
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var outcome: Outcome?
        private var timeoutTask: Task<Void, Never>?
        private var attached = true
        private var lastState: NeteaseDownloadState?

        init(store: NeteaseDownloadStore, songID: Int64, progress: @escaping (NeteaseDownloadState) -> Void) {
            self.store = store; self.songID = songID; self.progress = progress
            previous = store.onChange
            store.onChange = { [weak self] in
                guard let self else { return }
                self.previous?(); self.observe()
            }
            observe()
        }
        func wait(timeout: Duration) async -> Outcome {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let outcome { continuation.resume(returning: outcome); return }
                    self.continuation = continuation
                    timeoutTask = Task { [weak self] in
                        do { try await Task.sleep(for: timeout) }
                        catch { return }
                        self?.finish(.timeout)
                    }
                    observe()
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(.cancelled) }
            }
        }
        func detach() {
            guard attached else { return }
            attached = false; store?.onChange = previous
            timeoutTask?.cancel(); timeoutTask = nil
            if outcome == nil { finish(.cancelled) }
        }
        private func observe() {
            guard let state = store?.states[songID], state != lastState else { return }
            lastState = state; progress(state)
            switch state {
            case .downloaded: finish(.completed)
            case .failed: finish(.failed)
            default: break
            }
        }
        private func finish(_ value: Outcome) {
            guard outcome == nil else { return }
            outcome = value; timeoutTask?.cancel(); timeoutTask = nil
            continuation?.resume(returning: value); continuation = nil
        }
    }
}
#endif
