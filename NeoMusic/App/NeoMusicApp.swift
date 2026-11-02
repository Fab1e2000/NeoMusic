import SwiftUI

@main
struct NeoMusicApp: App {
    init() { ArtworkImagePipeline.configureMemoryCache() }
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryStartupContent()
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

/// Keep the task's owner stable when the prepared app replaces the launch background.
private struct LibraryStartupContent: View {
    var body: some View {
        if LocalLibrary.runtime.isInitialLibraryReady {
            LocalLibrary.app
        } else {
            // Library, playlists and playback appear together without a staged reveal.
            Color(uiColor: .systemBackground).ignoresSafeArea()
        }
    }
}
