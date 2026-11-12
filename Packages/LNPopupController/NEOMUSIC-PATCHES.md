# LNPopupController baseline and minimal patches

Upstream 4.6.1, commit `18847353e7cbec66e53a89edb1aec6d00967281c`.
Source and LICENSE copied from upstream; no NeoDizzy project/configuration imported.

Runtime modifications extracted from NeoDizzy current source:
- `_LNPopupTitlesController.m`: custom SwiftUI titles fill available title slot so height and hit testing are correct.
- `_LNPopupTitlesPagingController.m`: disable inactive paging scroll gestures while preserving custom title interaction; restore interaction after cancelled/short drag.

Local presentation correction:
- `LNPopupController.mm`: execute nonanimated presentation inside UIKit's
  `performWithoutAnimation` scope so hosted-title and tab-bar layout share its
  animation policy. Complete floating-bar ordering for both animated and immediate
  presentation using the existing native layout operation. The open and close
  animator keeps touch delivery enabled. A new pull that starts while the player
  is still springing back stops that animator where it is and continues the drag,
  so the screen corners stay on and the pan is not rebound under the finger.
- `_LNPopupTransitionAnimator.mm`: carry the mini-player's resolved interface style
  into the sibling glass transition wrapper, so opening and closing retain the
  endpoint appearance even when the page overrides the system style.
- `LNPopupBar.mm`: forward the bar placement trait to the detached SwiftUI toolbar
  hosts at attachment and on trait changes. Buttons can adapt locally without
  resubmitting the popup item or rebuilding the full-screen content.
- `UIViewController+LNPopupSupport.mm`: the transition lock no longer drops hits
  or disables the window. Opening and closing still animate and still lock rotation.

Package-only adjustment: omit unused Xcode project from vendor tree and manifest exclude list. All original runtime source outside these six files is unchanged. No external-accessory portal API, global-hook-disable build flag or obsolete native presentation fork is included.
