# LNPopupController baseline and minimal patches

Upstream 4.6.1, commit `18847353e7cbec66e53a89edb1aec6d00967281c`.
Source and LICENSE copied from upstream; no NeoDizzy project/configuration imported.

Runtime modifications extracted from NeoDizzy current source:
- `_LNPopupTitlesController.m`: custom SwiftUI titles fill available title slot so height and hit testing are correct.
- `_LNPopupTitlesPagingController.m`: disable inactive paging scroll gestures while preserving custom title interaction; restore interaction after cancelled/short drag.

Package-only adjustment: omit unused Xcode project from vendor tree and manifest exclude list. All original runtime source outside the two files is unchanged. No external-accessory portal API, global-hook-disable build flag or obsolete native presentation fork is included.
