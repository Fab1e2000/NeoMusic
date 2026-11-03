import SwiftUI

@main
struct NeoMusicApp: App {
    init() { ArtworkImagePipeline.configureMemoryCache() }
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LocalLibrary.app
                .task { await LocalLibrary.runtime.refresh() }
                .onChange(of: scenePhase) { previous, phase in
                    // Initial activation is already covered by the task above.
                    if previous == .background, phase != .background {
                        Task { await LocalLibrary.runtime.refresh() }
                    }
                }
        }
    }
}
