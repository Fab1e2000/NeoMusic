import Foundation

struct PlaybackTimelineAnchor: Equatable, Sendable {
    let baseElapsed: Double
    let hostTimestamp: TimeInterval
    let rate: Double
    let duration: Double

    init(
        baseElapsed: Double,
        hostTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        rate: Double,
        duration: Double
    ) {
        self.baseElapsed = baseElapsed.isFinite ? max(0, baseElapsed) : 0
        self.hostTimestamp = hostTimestamp
        self.rate = rate.isFinite ? max(0, rate) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
    }

    static let zero = PlaybackTimelineAnchor(baseElapsed: 0, hostTimestamp: 0, rate: 0, duration: 0)

    func elapsed(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard rate > 0 else { return clamped(baseElapsed) }
        let delta = max(0, uptime - hostTimestamp)
        return clamped(baseElapsed + delta * rate)
    }

    private func clamped(_ value: Double) -> Double {
        let safe = value.isFinite ? max(0, value) : 0
        return duration > 0 ? min(safe, duration) : safe
    }
}
