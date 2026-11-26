import SwiftUI
import UIKit

@MainActor
public enum CenteredActionSheet {
    public struct Action {
        public let title: String
        public var isDestructive = false
        public let handler: () -> Void
    }

    public static func present(message: String, actions: [Action]) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        for action in actions {
            alert.addAction(UIAlertAction(title: action.title, style: action.isDestructive ? .destructive : .default) { _ in
                action.handler()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        DispatchQueue.main.async { topController?.present(alert, animated: true) }
    }

    public static func confirmRemoveFromLiked(_ perform: @escaping () -> Void) {
        present(message: "确定要从喜欢歌曲中移除这首歌吗？", actions: [
            .init(title: "从喜欢歌曲移除", isDestructive: true) {
                LibraryHaptics.lightImpact()
                perform()
            }
        ])
    }

    public static func confirmRemoveFromPlaylist(_ perform: @escaping () -> Void) {
        present(message: "确定要从该播放列表中移除这首歌吗？", actions: [
            .init(title: "移除", isDestructive: true) {
                LibraryHaptics.lightImpact()
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
