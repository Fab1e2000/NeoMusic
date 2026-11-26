import FrontAMNavigation
import SwiftUI

public struct FrontAMPageToolbarAccessory {
    private let makeView: @MainActor () -> AnyView

    public init<Content: View>(@ViewBuilder _ content: @escaping @MainActor () -> Content) {
        makeView = { AnyView(content()) }
    }

    @MainActor func callAsFunction() -> AnyView { makeView() }
}

extension EnvironmentValues {
    @Entry public var frontAMLinkedPlaylistProvider = pageText("在线")
    @Entry public var frontAMPageToolbarAccessory: FrontAMPageToolbarAccessory? = nil
}

struct FrontAMPageToolbar: ToolbarContent {
    @Environment(\.frontAMPageToolbarAccessory) private var accessory

    var body: some ToolbarContent {
        if let accessory {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) { accessory() }
        }
    }
}

extension View {
    func libraryRootAccountButton() -> some View { modifier(FrontAMRootToolbar()) }
}

private struct FrontAMRootToolbar: ViewModifier {
    @Environment(\.libraryNavigationChrome) private var chrome

    func body(content: Content) -> some View {
        content.toolbar { if chrome?.isRoot == true { FrontAMPageToolbar() } }
    }
}
