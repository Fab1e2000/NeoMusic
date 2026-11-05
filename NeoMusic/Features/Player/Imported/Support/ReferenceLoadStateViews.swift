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


// Exact lyrics-only branch of NeoDizzy ContentSkeleton; unrelated page layouts omitted.
enum ContentSkeletonLayout { case lyrics }
struct ContentSkeleton: View {
    var layout: ContentSkeletonLayout = .lyrics
    var count = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<count, id: \.self) { _ in
                Text("等待音乐里的故事").font(.system(size: 36, weight: .bold))
                    .redacted(reason: .placeholder)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
