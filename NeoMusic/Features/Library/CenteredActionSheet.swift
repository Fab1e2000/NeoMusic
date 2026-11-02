import SwiftUI
import UIKit

/// 页面中间弹出的选择框：说明文字左对齐、按钮纵向排列并带“取消”。
/// SwiftUI 的确认框在 iPhone 上会从挂载的视图以气泡弹出，这里改用不指定来源的 UIKit 操作表，与 Apple Music 一致。
@MainActor
enum CenteredActionSheet {
    struct Action {
        let title: String
        var isDestructive = false
        let handler: () -> Void
    }

    static func present(message: String, actions: [Action]) {
        let sheet = UIAlertController(title: nil, message: message, preferredStyle: .actionSheet)
        for action in actions {
            sheet.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) { _ in
                action.handler()
            })
        }
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        topController?.present(sheet, animated: true)
    }

    private static var topController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
