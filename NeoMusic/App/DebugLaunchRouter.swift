#if DEBUG
import SwiftUI

/// Centralizes debug preview launch routing and read-probe triggers outside the production app entry point.
@MainActor
enum DebugLaunchRouter {
    static var isPreviewLaunch: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        let directPreviews = [
            "-frontendReviewPreview",
            "-searchPreview",
            "-downloadsPreview",
            "-homeFeedPreview"
        ]
        return directPreviews.contains(where: arguments.contains)
            || homePreviewMode != nil
            || onlinePreviewPage != nil
            || accountPreviewState != nil
    }

    @ViewBuilder
    static func previewRoot(account: NeteaseAccount) -> some View {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-frontendReviewPreview") {
            FrontendReviewPreview().environment(account)
        } else if arguments.contains("-searchPreview") {
            SearchPreviewRoot().environment(account)
        } else if arguments.contains("-downloadsPreview") {
            DownloadsPreview()
        } else if arguments.contains("-homeFeedPreview") {
            HomeFeedPreview().environment(account)
        } else if let mode = homePreviewMode {
            HomeRecommendationPreview(mode: mode)
                .environment(account)
        } else if let page = onlinePreviewPage {
            if page == "quality" {
                OnlineLibraryPreviewRoot()
            } else {
                OnlineLibraryShellPreview(initialPage: page).environment(account)
            }
        } else if let state = accountPreviewState {
            AccountPreviewRoot(state: state)
        }
    }

    private static var homePreviewMode: HomeRecommendationPreview.Mode? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-homeRecommendationPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        return HomeRecommendationPreview.Mode(rawValue: arguments[index + 1])
    }

    private static var onlinePreviewPage: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-onlineLibraryPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        let page = arguments[index + 1]
        return ["playlists", "favorites", "detail", "queue", "quality"].contains(page) ? page : nil
    }

    private static var accountPreviewState: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-neteaseAccountPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        let state = arguments[index + 1]
        return ["signed-out", "signed-in", "settings"].contains(state) ? state : nil
    }
}
#endif
