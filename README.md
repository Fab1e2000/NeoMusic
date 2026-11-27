# NeoMusic

面向 iPhone（iOS 27+）的原生 SwiftUI / UIKit 音乐客户端，支持本地音乐与网易云音乐。

## 环境要求

- iOS 27.0+ iPhone
- Xcode 27.1+、Swift 6、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

## 从源码构建

```sh
brew install xcodegen
xcodegen generate
open NeoMusic.xcodeproj
```

`project.yml` 为工程配置唯一来源。选择 `NeoMusic` scheme 与 iPhone 模拟器即可构建运行；真机运行需自行配置签名。

## 仓库结构

```text
NeoMusic/
  App/                          # 应用入口、运行时容器、标签导航与领域装配
  Core/                         # 本地资料库、扫描、歌词、播放引擎与网易云业务
  Features/                     # 主页、资料库、搜索、账户与播放器宿主
  Resources/                    # 图标、资源与来源声明
Packages/                       # FrontAM（含 LNPopup）、AudioStreaming、AudioTags
FullScreenPlayerTests/          # FrontAMPlayer 单元测试
NeoMusicTests/                  # 应用单元测试
NeoMusicNavigationUITests/      # 导航与交互 UI 测试
NeoMusicFunctionalParityTests/  # 功能对照 UI 测试
docs/architecture.md            # 项目架构说明
scripts/                        # 边界检查、本机 CI、推送门禁与打包脚本
```

## 本机验证

日常改动运行 `python3 scripts/check-module-boundaries.py`，并按影响范围选择测试。推送代码前使用 `bash scripts/ci.sh`，脚本会检查模块边界与第三方来源声明、运行脚本回归与 AudioStreaming / FrontAM 包测试、验证 `FrontAMShowcase` 构建、重新生成工程，并在 iPhone 模拟器运行 Release 配置的 `NeoMusicTests` 和 `FullScreenPlayerTests`。

## 文档

- [架构说明](docs/architecture.md)
- [Uneed2no · 标签栏与迷你播放器配色同步的排查经验](docs/Uneed2no.md)
- [项目规范](AGENTS.md)

## 免责声明与许可

- NeoMusic 为个人开发的非官方第三方客户端，与网易云音乐及 Apple 无隶属或授权关系。
- 本项目不托管或分发音乐内容，不运行服务端，不收集用户数据。
- 代码采用 [GNU GPL v3.0](LICENSE) 授权；第三方依赖与来源声明见：
  - [播放器来源声明](NeoMusic/Features/Player/Resources/PlayerSourceNotices.txt)与[导入清单](NeoMusic/Features/Player/Resources/PlayerSourceManifest.json)
  - [网易云协议来源声明](NeoMusic/Resources/NeteaseSourceNotices.txt)
  - [第三方许可](NeoMusic/Features/Player/ThirdPartyLicenses.txt)、[GPL-3.0](NeoMusic/Features/Player/Resources/GPL-3.0.txt)、[Nuke 许可](NeoMusic/Features/Player/Resources/Nuke-LICENSE.txt)
  - [AudioStreaming 声明](Packages/AudioStreaming/NOTICE.md)、[AudioTags 来源](Packages/AudioTags/PROVENANCE.md)
  - [FrontAM 第三方许可与来源](Packages/FrontAM/THIRD_PARTY_NOTICES.md)
  - [LNPopupUI 修改说明](Packages/FrontAM/Vendor/LNPopupUI/NEOMUSIC-PATCHES.md)、[LNPopupController 修改说明](Packages/FrontAM/Vendor/LNPopupController/NEOMUSIC-PATCHES.md)
