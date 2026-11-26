import FrontAMCore
import SwiftUI

extension View {
    public func libraryToasts(_ center: LibraryToastCenter) -> some View {
        modifier(LibraryToastNavigation(center: center))
    }
}

private struct LibraryToastNavigation: ViewModifier {
    let center: LibraryToastCenter
    @Environment(\.openLibraryRoute) private var openRoute
    func body(content: Content) -> some View {
        content.frontAMLibraryToasts(center) { destination in
            openRoute(destination.libraryRoute)
        }
    }
}

extension FrontAMToastDestination {
    var libraryRoute: LibraryRoute {
        switch self {
        case .playlist(let id): .playlist(id)
        case .folder(let id): .playlistFolder(id)
        }
    }
}
