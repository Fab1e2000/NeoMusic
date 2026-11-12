import SwiftUI

/// 内容就绪时立即显示，导航和背景保持原生生命周期。
extension View {
    func pageContentReveal(isReady: Bool = true) -> some View {
        modifier(PageContentReveal(isReady: isReady))
    }
}

private struct PageContentReveal: ViewModifier {
    let isReady: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isReady ? 1 : 0)
            .allowsHitTesting(isReady)
            .accessibilityHidden(!isReady)
            .transaction(value: isReady) { $0.animation = nil; $0.disablesAnimations = true }
    }
}
