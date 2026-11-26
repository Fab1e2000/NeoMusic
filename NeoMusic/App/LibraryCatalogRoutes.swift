import FrontAMPages

extension LibraryCatalog {
    func handles(_ route: LibraryRoute) -> Bool {
        switch route {
        case .artist(let id), .album(let id), .artistSection(let id, _): CatalogRouteIdentity.isCatalogID(id)
        default: false
        }
    }
}
