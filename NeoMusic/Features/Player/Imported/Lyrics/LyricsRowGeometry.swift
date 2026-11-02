import Foundation
import Observation

/// Scroll positions are sampled by the focus task, not rendered. Keep them out
/// of observable state; only the focused line's height affects viewport layout.
@Observable
final class LyricsRowGeometry {
    nonisolated struct Measurement: Equatable, Sendable {
        let height: CGFloat
        let top: CGFloat
    }

    @ObservationIgnored private var heights: [Int: CGFloat] = [:]
    @ObservationIgnored private var tops: [Int: CGFloat] = [:]
    @ObservationIgnored private var focusedID: Int?
    private(set) var focusedHeight: CGFloat?

    func height(for id: Int?) -> CGFloat? {
        // Subscribe even before onChange selects a newly active line. Read its
        // cached height immediately instead of reusing the previous line's.
        let currentHeight = focusedHeight
        guard let id else { return nil }
        return id == focusedID ? currentHeight : heights[id]
    }

    func focus(on id: Int?) {
        focusedID = id
        focusedHeight = id.flatMap { heights[$0] }
    }

    func record(_ measurement: Measurement, for id: Int) {
        guard measurement.height.isFinite, measurement.height > 0,
              measurement.top.isFinite else { return }
        if heights[id] != measurement.height {
            heights[id] = measurement.height
        }
        tops[id] = measurement.top
        if id == focusedID, focusedHeight != measurement.height {
            focusedHeight = measurement.height
        }
    }

    func top(for id: Int) -> CGFloat? { tops[id] }

    func discardPosition(for id: Int) {
        // An offscreen lazy row's last viewport position is stale. Its height
        // remains a useful estimate until it is measured after a distant seek.
        tops.removeValue(forKey: id)
    }
}
