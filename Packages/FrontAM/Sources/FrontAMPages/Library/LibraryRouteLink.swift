import FrontAMCore
import SwiftUI

public struct LibraryRouteLink<Label: View>: View {
    public let value: LibraryRoute
    public var preview: LibraryNavigationPreview? = nil
    @ViewBuilder public var label: Label
    @Environment(\.libraryRouteDestination) private var destination
    @Environment(\.openLibraryRoute) private var openRoute
    public var body: some View {
        if destination.makePage != nil {
            Button {
                if let preview {
                    openRoute(value, preview: preview, sourceProvider: { nil })
                } else {
                    openRoute(value)
                }
            } label: {
                HStack {
                    label
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
        } else { NavigationLink(value: value) { label } }
    }

    public init(value: LibraryRoute,
                preview: LibraryNavigationPreview? = nil,
                @ViewBuilder label: () -> Label) {
        self.value = value
        self.preview = preview
        self.label = label()
    }
}

public struct LibraryRouteDestination {
    public var makePage: ((LibraryRoute) -> AnyView)?

    public init(makePage: ((LibraryRoute) -> AnyView)? = nil) {
        self.makePage = makePage
    }
}
extension EnvironmentValues {
    @Entry public var libraryRouteDestination = LibraryRouteDestination()
}
