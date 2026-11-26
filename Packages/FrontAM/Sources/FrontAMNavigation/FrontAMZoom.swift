import SwiftUI

extension EnvironmentValues {
    @Entry public var libraryZoomNamespace: Namespace.ID?
}

public extension View {
    @ViewBuilder
    func libraryZoomSource<ID: Hashable>(_ id: ID, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }

    @ViewBuilder
    func libraryZoomTransition<ID: Hashable>(_ id: ID, in namespace: Namespace.ID?) -> some View {
        if let namespace { navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }
}
