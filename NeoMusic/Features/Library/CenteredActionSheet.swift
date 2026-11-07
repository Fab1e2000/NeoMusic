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
        // 菜单或侧滑还在收起时立刻 present 会被系统丢掉，等这一轮交互结束再弹出。
        DispatchQueue.main.async { topController?.present(alert, animated: true) }
    }

    /// 从喜欢歌曲移除。确认后才执行，并给出触感。
    static func confirmRemoveFromLiked(_ perform: @escaping () -> Void) {
        present(message: "确定要从喜欢歌曲中移除这首歌吗？", actions: [
            .init(title: "从喜欢歌曲移除", isDestructive: true) {
                LibraryHaptics.impact()
                perform()
            }
        ])
    }

    /// 从自己的播放列表移除。确认后才执行，并给出触感。
    static func confirmRemoveFromPlaylist(_ perform: @escaping () -> Void) {
        present(message: "确定要从该播放列表中移除这首歌吗？", actions: [
            .init(title: "移除", isDestructive: true) {
                LibraryHaptics.impact()
                perform()
            }
        ])
    }

    private static var topController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}
