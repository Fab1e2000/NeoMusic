# FrontAM

FrontAM is an Apple Music–inspired native UI kit for iOS 27+ and Swift 6. It provides a tab shell, music browsing pages, a mini-player and a full-screen player. Your app supplies the catalog, playback state, artwork and timed lyrics. FrontAM uses SwiftUI and UIKit, including the native navigation stack and interactive Zoom transition.

The package manifest requires SwiftPM tools 6.2 or newer. Use Xcode with an iOS 27 SDK to build the iPhone example.

## Modules

| Product | Responsibility | Direct FrontAM dependencies |
| --- | --- | --- |
| `FrontAMCore` | Design tokens, artwork and color extraction, ImageIO thumbnail caching, shared controls and read-only track playback state | — |
| `FrontAMPlayer` | Full-screen artwork, Metal backdrop, timed lyrics and editable playback queue | Core |
| `FrontAMPopup` | Persistent mini-player, controls and matched artwork transition | Player, Core |
| `FrontAMNavigation` | Tab ordering, independent navigation stacks, interactive Zoom and player handoff | Core |
| `FrontAMPages` | Home, search, library, collection details, track lists and playlist editing | Navigation, Core |
| `FrontAM` | Umbrella product that reexports all five modules | All five |

- **Browsing and navigation** uses `FrontAMCore`, `FrontAMNavigation` and `FrontAMPages`. Link `FrontAMPages` for the complete MIT line. Its target graph contains Apple frameworks and the other two browsing modules.
- **Playback** uses `FrontAMPlayer` for the full-screen player and `FrontAMPopup` for the mini-player. The popup depends on the player and the vendored LNPopup packages. Link the umbrella product once to the app target when using both lines.

## Add FrontAM to an app

In Xcode, add the local directory containing this `Package.swift`, then choose the product that matches your app. In a Swift package manifest, declare `.package(path: "<relative-path-to-FrontAM>")` and add `.product(name: "FrontAMPages", package: "FrontAM")` for the browsing line.

This SwiftUI view links `FrontAMCore` and uses the default ImageIO artwork provider. Pass a URL to a local image file.

```swift
import FrontAMCore
import SwiftUI

struct CoverTile: View {
    let imageURL: URL

    var body: some View {
        ArtworkView(artwork: .file(imageURL))
            .frame(width: 144, height: 144)
    }
}
```

For the player, wrap your `PlayerPlaybackSource` in `PlayerState` and supply a `PlayerServices` with playback actions, lyrics and artwork. Inject the state into `FrontAMPlayerPopup` and use the same state and services in its `FullScreenPlayerView`. For browsing, use `FrontAMHomeFeedView`, `FrontAMSearchPageView` and `FrontAMLibraryHomeView`. The home and search models carry display items and callbacks. Use `FrontAMTrackItem`, `FrontAMShelfItem` and `FrontAMRoute` for tracks, collections and navigation. Implement `FrontAMPlaylistSource` to connect your playlist store to the library and editing pages. Existing public spellings remain source-compatible.

## Run FrontAMShowcase

Use Xcode with an iOS 27+ iPhone simulator and XcodeGen. Run these commands from the FrontAM package directory.

```sh
cd Examples/FrontAMShowcase
xcodegen generate
open FrontAMShowcase.xcodeproj
```

Select the `FrontAMShowcase` scheme and an iPhone simulator, then run the app. Initial package resolution fetches the two public transitive LNPopup dependencies. The showcase uses fictional catalog entries, original timed lyrics and covers drawn at runtime. Playback is a silent simulation.

- **Home** shows the feed. Tap a song to start playback or a cover to open its detail.
- **Library** has pinned collections, browse categories and recent additions. Open the More menu and choose **编辑置顶** to drag the pinned cards. Open a pinned cover to try Zoom.
- **Search** searches the local demo catalog. Try **月背** or **折纸**.
- The mini-player starts at **未在播放**. Once a song is selected, expand it and switch between artwork, the time-synchronized lyrics and the queue. The queue supports insertion, reordering and removal. The **演示选项** menu on Home and Library can clear the queue and reorder the two movable tabs. Search uses the system-pinned search tab.

## Localization and testing

The five modules ship English and Simplified Chinese resource tables with a Simplified Chinese development fallback. Built-in browsing copy and the mini-player use the selected bundle language. The full-screen player uses these resources for the package-owned controls, such as lyrics, Up Next, repeat mode, volume and audio quality. Attributed upstream player views retain their existing copy. Host-supplied labels and catalog content are supplied in the host’s language.

Open `Package.swift` in Xcode and select an iOS simulator to run the package tests. They cover artwork color math and ImageIO caching, tab ordering and independent storage keys, playlist menu capabilities, and player contracts and volume inertia. NeoMusic’s `FullScreenPlayerTests` target shares the player contract and inertia source files.

## Licenses

- **Browsing and navigation**. [MIT](LICENSE) covers `FrontAMCore`, `FrontAMNavigation` and `FrontAMPages`.
- **Player and popup**. `FrontAMPlayer` includes upstream-derived [GPL-3.0](Sources/FrontAMPlayer/Resources/GPL-3.0.txt) portions. The original popup integration and vendored LNPopup code retain their MIT terms. Linking `FrontAMPopup` or the `FrontAM` umbrella also includes the player and its GPL-3.0 portions.
- The original Showcase code and fixtures are MIT. The Showcase uses the umbrella product.

See the [third-party notices](THIRD_PARTY_NOTICES.md), [player notices](Sources/FrontAMPlayer/Resources/PlayerSourceNotices.txt) and [source manifest](Sources/FrontAMPlayer/Resources/PlayerSourceManifest.json) for provenance and applicable license texts.
