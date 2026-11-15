// Ported from youshen2/MeloX (GPL-3.0), commit 1fe5fbab3f554e8529c4847fc54281a472b7b61a.
import CoreGraphics

struct LyricsScrollInterfaceVisibilityTracker {
    private var downwardDistance: CGFloat = 0
    private var isInterfaceVisible = true

    mutating func begin(isInterfaceVisible: Bool) {
        downwardDistance = 0
        self.isInterfaceVisible = isInterfaceVisible
    }

    mutating func update(
        offsetDelta: CGFloat,
        hideThreshold: CGFloat
    ) -> Bool? {
        guard offsetDelta.isFinite, hideThreshold.isFinite else { return nil }
        if offsetDelta < 0 {
            downwardDistance = 0
            guard !isInterfaceVisible else { return nil }
            isInterfaceVisible = true
            return true
        }

        guard offsetDelta > 0, isInterfaceVisible else { return nil }
        downwardDistance += offsetDelta
        guard downwardDistance >= max(hideThreshold, 1) else { return nil }

        downwardDistance = 0
        isInterfaceVisible = false
        return false
    }

    mutating func end() {
        downwardDistance = 0
    }
}
