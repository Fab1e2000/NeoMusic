import SwiftUI
import UIKit

extension View {
    public func onSheetDismissAttempt(_ action: @escaping () -> Void) -> some View {
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

        func install() {
            guard window != nil, let proxy, let controller = sheetRootController,
                  let presentation = controller.presentationController else { return }
            proxy.attach(to: presentation)
        }

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

private final class DismissAttemptProxy: NSObject, UIAdaptivePresentationControllerDelegate {
    var action: () -> Void = {}
    nonisolated(unsafe) private weak var original: (any UIAdaptivePresentationControllerDelegate)?
    private weak var presentation: UIPresentationController?

    @MainActor func attach(to presentation: UIPresentationController) {
        guard presentation.delegate !== self else { return }
        original = presentation.delegate
        presentation.delegate = self
        self.presentation = presentation
    }

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
