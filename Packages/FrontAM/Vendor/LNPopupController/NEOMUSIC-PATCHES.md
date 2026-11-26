# LNPopupController baseline and minimal patches

Upstream 4.6.3, commit `fe0d1b8ce3c6464a63f0dc5e82d4c1b641adb8cc`.
Source and `LICENSE` copied from upstream; no NeoDizzy project/configuration imported.

Runtime modifications extracted from NeoDizzy current source:
- `LNPopupController/LNPopupController/Private/Titles/_LNPopupTitlesController.m`: custom SwiftUI titles fill available title slot so height and hit testing are correct.
- `LNPopupController/LNPopupController/Private/Titles/_LNPopupTitlesPagingController.m`: disable inactive paging scroll gestures while preserving custom title interaction; restore interaction after cancelled/short drag.

Local presentation correction:
- `LNPopupController/LNPopupController/Private/LNPopupController.mm`: execute nonanimated presentation inside UIKit's
  `performWithoutAnimation` scope so hosted-title and tab-bar layout share its
  animation policy. Complete floating-bar ordering for both animated and immediate
  presentation using the existing native layout operation. The open and close
  animator keeps touch delivery enabled. A new pull that starts while the player
  is still springing back stops that animator where it is and continues the drag,
  so the screen corners stay on and the pan is not rebound under the finger. Attach the dismiss pan to opening content before starting the spring so a new downward gesture can interrupt it. Keep screen corners off while open unless a dismiss drag or open/close animation is actively running, and clear them if a non-dismiss gesture ends without transitioning.
- `LNPopupController/LNPopupController/Private/TransitionAnimators/_LNPopupTransitionAnimator.mm`: carry the mini-player's resolved interface style
  into the sibling glass transition wrapper, so opening and closing retain the
  endpoint appearance even when the page overrides the system style.
- `LNPopupController/LNPopupController/Private/LNPopupBar.mm`: extend the compact custom-title viewport to the artwork edge; the SwiftUI title preserves its resting inset and owns swipe fading. Forward the bar placement trait to the detached SwiftUI toolbar
  hosts at attachment and on trait changes. Buttons can adapt locally without
  resubmitting the popup item or rebuilding the full-screen content.
- `LNPopupController/LNPopupController/Private/UIViewController+LNPopupSupport.mm`: the transition lock no longer drops hits
  or disables the window. Opening and closing still animate and still lock rotation.

Package-only adjustment: omit unused Xcode project from vendor tree and manifest exclude list. All original runtime source outside these six files is unchanged. No external-accessory portal API, global-hook-disable build flag or obsolete native presentation fork is included.
