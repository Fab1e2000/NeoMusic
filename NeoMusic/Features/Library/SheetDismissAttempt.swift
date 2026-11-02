import SwiftUI
import UIKit

extension View {
    /// 在禁止下拉关闭的 sheet 里，用户下拉时调用 `action`（例如弹出“放弃更改”确认）。
    ///
    /// SwiftUI 没有公开这个时机。这里找到 sheet 实际的呈现控制器，用一个转发代理包住 SwiftUI 自己的代理：
    /// 只额外接收“尝试关闭”回调，其余回调原样转给 SwiftUI，sheet 的呈现与关闭仍由 SwiftUI 管理。
    /// 需要同时设置 `interactiveDismissDisabled()`，系统才会把下拉当成“尝试关闭”。
    func onSheetDismissAttempt(_ action: @escaping () -> Void) -> some View {
        background(SheetDismissAttemptProbe(action: action).allowsHitTesting(false))
    }
}

private struct SheetDismissAttemptProbe: UIViewRepresentable {
    let action: () -> Void

    func makeCoordinator() -> DismissAttemptProxy { DismissAttemptProxy() }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.proxy = context.coordinator
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.action = action
        view.install()
    }

    static func dismantleUIView(_ view: ProbeView, coordinator: DismissAttemptProxy) {
        coordinator.detach()
    }

    final class ProbeView: UIView {
        weak var proxy: DismissAttemptProxy?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            install()
        }

        /// SwiftUI 可能在更新时重新设置代理，每次布局更新都检查一遍。
        func install() {
            guard window != nil, let proxy, let controller = sheetRootController,
                  let presentation = controller.presentationController else { return }
            proxy.attach(to: presentation)
        }

        /// sheet 的根控制器：沿响应链找到最近的控制器，再沿父控制器向上，直到被呈现的那一个。
        private var sheetRootController: UIViewController? {
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) { responder = current.next }
            var controller = responder as? UIViewController
            while let current = controller {
                if current.presentingViewController != nil, current.parent == nil { return current }
                controller = current.parent
            }
            return nil
        }
    }
}

/// 包住 SwiftUI 的呈现代理：自己只处理“尝试关闭”，其余调用转发给原代理。
private final class DismissAttemptProxy: NSObject, UIAdaptivePresentationControllerDelegate {
    var action: () -> Void = {}
    /// Objective-C 运行时在主线程查询转发目标；这两个查询方法不带隔离，故此处不做隔离检查。
    nonisolated(unsafe) private weak var original: (any UIAdaptivePresentationControllerDelegate)?
    private weak var presentation: UIPresentationController?

    @MainActor func attach(to presentation: UIPresentationController) {
        guard presentation.delegate !== self else { return }
        original = presentation.delegate
        presentation.delegate = self
        self.presentation = presentation
    }

    /// 离开层级时把代理交还给 SwiftUI。
    @MainActor func detach() {
        if let presentation, presentation.delegate === self { presentation.delegate = original }
    }

    @MainActor func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        original?.presentationControllerDidAttemptToDismiss?(presentationController)
        action()
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
