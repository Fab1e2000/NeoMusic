# FrontAM

FrontAM is an Apple Music–inspired native UI kit for iOS 27+ and Swift 6. It provides a tab shell, music browsing pages, a mini-player and a full-screen player. Your app supplies the catalog, playback state, artwork and timed lyrics. FrontAM uses SwiftUI and UIKit, including the native navigation stack and interactive Zoom transition.

The package manifest requires SwiftPM tools 6.2 or newer. Use Xcode with an iOS 27 SDK to build the iPhone example.

## Modules

| Product | Responsibility | Direct FrontAM dependencies |
| --- | --- | --- |
| `FrontAMCore` | Design tokens, artwork and color extraction, ImageIO thumbnail caching, shared controls and read-only track playback state | — |
| `FrontAMPlayer` | Full-screen artwork, Metal backdrop, timed lyrics and editable playback queue | Core |
| `FrontAMPopup` | Persistent mini-player, controls and matched artwork transition | Player, Core |
| `FrontAMNavigation` | Tab ordering, independent navigation stacks, interactive Zoom and player handoff | Popup, Core |
| `FrontAMPages` | Home, search, library, collection details, track lists and playlist editing | Navigation, Core |
| `FrontAM` | Umbrella product that reexports all five modules | All five |

`FrontAMPopup` uses the vendored LNPopup packages. Add the umbrella product once to the app target when using the complete shell.

## Add FrontAM to an app

In Xcode, add the local directory containing this `Package.swift`, then link the `FrontAM` product to your app target. In a Swift package manifest, declare `.package(path: "<relative-path-to-FrontAM>")` and add `.product(name: "FrontAM", package: "FrontAM")` to your target dependencies.

This SwiftUI view uses the default ImageIO artwork provider. Pass a URL to a local image file.

```swift
import FrontAM
import SwiftUI

struct CoverTile: View {
    let imageURL: URL

    var body: some View {
        ArtworkView(artwork: .file(imageURL))
            .frame(width: 144, height: 144)
    }
}
```

For the player, wrap your `PlayerPlaybackSource` in `PlayerState` and supply a `PlayerServices` with playback actions, lyrics and artwork. Inject the state into `FrontAMPlayerPopup` and use the same state and services in its `FullScreenPlayerView`. For browsing, `HomeContentModel` and `SearchPageModel` carry display items and action callbacks. Implement `FrontAMPlaylistSource` to connect your playlist store to the library and editing pages.

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

## Licenses

- [MIT](LICENSE) covers original FrontAM work and the original Showcase code and fixtures.
- The vendored LNPopupUI and LNPopupController code and their two transitive LN dependencies retain their MIT licenses.
- The upstream-derived player portions retain [GPL-3.0](Sources/FrontAMPlayer/Resources/GPL-3.0.txt). [Player source notices](Sources/FrontAMPlayer/Resources/PlayerSourceNotices.txt) and the [source manifest](Sources/FrontAMPlayer/Resources/PlayerSourceManifest.json) identify their provenance. The umbrella product includes those portions. Distributions that include them must comply with the applicable GPL terms.

See [third-party notices](THIRD_PARTY_NOTICES.md) for the upstream revisions, notices and local changes.
