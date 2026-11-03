import SwiftUI
import Observation

enum HomeContentStyle { case artwork, favorites, daily }

struct HomeContentItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let artwork: Artwork
    let route: LibraryRoute
    var style: HomeContentStyle = .artwork
    var eyebrow: String? = nil
}

@MainActor @Observable final class HomeContentModel {
    var featured: [HomeContentItem] = []
    var recent: [HomeContentItem] = []
    var recommendations: [HomeContentItem] = []
    var isGuest = true
    var featuredError: String?
    var recommendationsError: String?
    var login: () -> Void = {}
    var retryFeatured: () -> Void = {}
    var retryRecommendations: () -> Void = {}
}
