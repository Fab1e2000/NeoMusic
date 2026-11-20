import SwiftUI

/// Value links need a SwiftUI NavigationStack. Destination links use the existing
/// UIKit navigation controller and retain the system row, selection and accessibility.
struct LibraryRouteLink<Label: View>: View {
    let value: LibraryRoute
    var preview: LibraryNavigationPreview? = nil
    @ViewBuilder var label: Label
    @Environment(\.libraryRouteDestination) private var destination
    @Environment(\.openLibraryRoute) private var openRoute
    var body: some View {
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
}

struct LibraryRouteDestination {
    var makePage: ((LibraryRoute) -> AnyView)?
}
extension EnvironmentValues {
    @Entry var libraryRouteDestination = LibraryRouteDestination()
}
