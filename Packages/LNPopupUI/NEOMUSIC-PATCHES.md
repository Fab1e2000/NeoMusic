# LNPopupUI source baseline

Upstream: https://github.com/LeoNatan/LNPopupUI.git
Revision: `60853564423524c9ed15cc74c5969d3e1ca666f1`.

Only `Sources`, `Package.swift`, and `LICENSE` are vendored from the upstream revision, not a wholesale copy of NeoDizzy's fork.

Local modification: remove the second identical declarations of
`popupOpensOverSplitView` and `popupBarAvoidsSplitViewPrimaryColumn` in
`Sources/LNPopupUI/LNPopupUI.swift`. The original declarations remain unchanged.
Swift rejects the unmodified revision with “invalid redeclaration”. Runtime patches subsequently extracted from NeoDizzy: `PopupItemViewImage` and its image-host adapter retain custom mini artwork; `pendingNativeOpenState` synchronizes interactive native open/close with SwiftUI binding updates. These are the only runtime differences from this upstream baseline.

The local LNPopupController package uses upstream 4.6.1, LNSwiftUIUtils 1.1.5, and
LNSystemMarqueeLabel 0.1.2; the checked-in Package.resolved records their revisions.
