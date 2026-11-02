import SwiftUI

/// 已就绪的内容直接显示；首次加载时保持隐藏，就绪后以 0.5 秒淡入。
/// 背景和导航栏按钮照常显示，不展示等待提示器。
extension View {
    func pageContentReveal(isReady: Bool = true) -> some View {
        modifier(PageContentReveal(isReady: isReady))
    }
}

private struct PageContentReveal: ViewModifier {
    let isReady: Bool
    @State private var visible: Bool

    init(isReady: Bool) {
        self.isReady = isReady
        // Seed once per page identity: cached/local content must be visible in
        // its first navigation frame. Later readiness changes use the task below.
        _visible = State(initialValue: isReady)
    }

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(isReady && visible)
            .accessibilityHidden(!isReady || !visible)
            .task(id: isReady) {
                guard isReady else {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { visible = false }
                    return
                }
                guard !visible else { return }
                // The loading state already committed the transparent frame.
                // Reveal the stable container once, after its content is ready.
                guard !Task.isCancelled else { return }
                var transaction = Transaction(animation: .easeOut(duration: 0.5))
                transaction.disablesAnimations = false
                withTransaction(transaction) { visible = true }
            }
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
