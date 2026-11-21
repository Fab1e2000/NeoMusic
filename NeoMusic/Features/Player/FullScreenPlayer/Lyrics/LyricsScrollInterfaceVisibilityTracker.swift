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
            return nil
        }

        guard offsetDelta > 0, isInterfaceVisible else { return nil }
        downwardDistance += offsetDelta
        guard downwardDistance >= max(hideThreshold, 1) else { return nil }

        downwardDistance = 0
        isInterfaceVisible = false
        return false
    }

    mutating func shouldRevealOnEndDragging(
        velocityY: CGFloat,
        revealVelocityThreshold: CGFloat = 0.35
    ) -> Bool {
        guard !isInterfaceVisible, velocityY.isFinite,
              velocityY <= -max(revealVelocityThreshold, 0.05) else {
            return false
        }
        downwardDistance = 0
        isInterfaceVisible = true
        return true
    }

    mutating func end() {
        downwardDistance = 0
    }
}
