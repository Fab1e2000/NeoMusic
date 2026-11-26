# FrontAM third-party notices

The [FrontAM MIT license](LICENSE) covers original FrontAM work, including the Showcase source and its fictional fixtures. Showcase covers are rendered by the app from original geometric designs. The upstream portions below retain their respective licenses.

The standalone Showcase links the local FrontAM umbrella product. LNPopup resolves the two public SwiftPM dependencies below. The revisions in the table identify the dependency versions used for development.

| Component | Upstream and license | Local changes |
| --- | --- | --- |
| LNPopupUI | [LeoNatan/LNPopupUI](https://github.com/LeoNatan/LNPopupUI), revision `60853564423524c9ed15cc74c5969d3e1ca666f1`, [MIT](Vendor/LNPopupUI/LICENSE) | Duplicate declaration removal, custom artwork hosting, open/close binding synchronization, SwiftUI transaction forwarding and custom-title accessibility metadata. See [patch notes](Vendor/LNPopupUI/NEOMUSIC-PATCHES.md). |
| LNPopupController | [LeoNatan/LNPopupController](https://github.com/LeoNatan/LNPopupController), 4.6.3 at `fe0d1b8ce3c6464a63f0dc5e82d4c1b641adb8cc`, [MIT](Vendor/LNPopupController/LICENSE) | Title layout and gesture coordination, native presentation and interruption, artwork transition appearance and bar placement trait forwarding. See [patch notes](Vendor/LNPopupController/NEOMUSIC-PATCHES.md). |
| LNSwiftUIUtils | [LeoNatan/LNSwiftUIUtils](https://github.com/LeoNatan/LNSwiftUIUtils/tree/181a95b992f84d99a14c562c86e8ebef3cbcdca9), 1.1.5, MIT | SwiftPM dependency of LNPopupUI. The host project pins this revision through its package resolution. |
| LNSystemMarqueeLabel | [LeoNatan/LNSystemMarqueeLabel](https://github.com/LeoNatan/LNSystemMarqueeLabel/tree/a87c80c36e8cc84f05a691da33c838a8e93015f6), 0.1.2, MIT | SwiftPM dependency of LNPopupController. The host project pins this revision through its package resolution. |
| FrontAMPlayer and FrontAMPopup | Imported from NeoDizzy at `bccecb66d32030ea55a564fe06fe0bda5598202b` with local worktree changes. The player presentation includes code derived from [MeloX / MeloX_Modified](https://github.com/youshen2/MeloX), including revision `b8bc60f`. Imported GPL portions retain [GPL-3.0](Sources/FrontAMPlayer/Resources/GPL-3.0.txt). | The player uses source-neutral state and injected artwork and lyrics services. FrontAMPopup extracts the existing mini-player presentation and receives artwork, expanded content, and diagnostics from its caller. See the [player notice](Sources/FrontAMPlayer/Resources/PlayerSourceNotices.txt) and [source manifest](Sources/FrontAMPlayer/Resources/PlayerSourceManifest.json). |

## LNSwiftUIUtils

MIT License

Copyright (c) 2023 Léo Natan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## LNSystemMarqueeLabel

MIT License

Copyright (c) 2025 Léo Natan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
