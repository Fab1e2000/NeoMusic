import SwiftUI
import UIKit

/// 屏幕正中的确认框：没有标题，说明在正文，带取消。
/// 不用操作表，避免提示从按钮或列表行边上冒出来。
@MainActor
enum CenteredActionSheet {
    struct Action {
        let title: String
        var isDestructive = false
        let handler: () -> Void
    }

    static func present(message: String, actions: [Action]) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        for action in actions {
            alert.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) { _ in
                action.handler()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        topController?.present(alert, animated: true)
    }

    private static var topController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
