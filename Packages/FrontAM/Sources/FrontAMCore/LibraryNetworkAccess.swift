import Foundation

/// Checks only for a known missing path. An unknown or on-demand path permits a request.
@MainActor
public struct LibraryNetworkAccess {
    private let unavailable: @MainActor @Sendable () -> Bool
    private let reportOffline: @MainActor @Sendable () -> Void

    public init(isOffline: @escaping @MainActor @Sendable () -> Bool,
                reportOffline: @escaping @MainActor @Sendable () -> Void) {
        unavailable = isOffline
        self.reportOffline = reportOffline
    }

    @TaskLocal public static var override: Self?
    private static var live = Self(isOffline: { false }, reportOffline: {})
    private static var active: Self { override ?? live }
    public static var isOffline: Bool { active.unavailable() }

    public static func allowOnlineAction() -> Bool {
        guard isOffline else { return true }
        active.reportOffline()
        return false
    }

    public static func configure(isOffline: @escaping @MainActor @Sendable () -> Bool, toasts: LibraryToastCenter) {
        live = Self(isOffline: isOffline, reportOffline: {
            toasts.show(.error(coreText("无网络连接，请联网后重试")))
        })
    }
}
