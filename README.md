<div align="center">
  <img src="docs/images/app-icon.png" width="144" height="144" alt="NeoMusic 图标">
  <h1>NeoMusic</h1>
  <p>面向网易云音乐的 iOS 音乐播放器，以 Apple 原生交互为基调，同时支持本地音乐。</p>
</div>

[![CI](https://github.com/Fab1e2000/NeoMusic/actions/workflows/ci.yml/badge.svg)](https://github.com/Fab1e2000/NeoMusic/actions/workflows/ci.yml)

**网易云账户已接入；当前音乐播放支持本地文件。** 项目正在开发，尚未发布正式版本。

## 当前能力

| 功能 | 状态 |
| --- | --- |
| 本地资料库 | 目录扫描、专辑与艺人浏览、资料库搜索、喜爱与置顶 |
| 播放列表 | 创建、编辑、封面选择及文件夹管理 |
| 播放与队列 | 迷你／全屏播放器、插播与排序、循环与随机、进度和队列恢复 |
| 歌词 | 本地歌词读取、导入与同步显示 |
| 网易云账户 | 官网登录、真实头像与昵称、会话恢复、失效处理、切换账号与退出；启动时恢复已缓存头像 |
| 网易云音乐 | 歌单、推荐、搜索、在线播放及下载尚未接入 |

网易云音乐是唯一在线来源，本地音乐作为补充能力保留。主页、新发现、广播、资料库、搜索五个主标签的右上角头像共用同一账户入口，本地音乐不依赖网易云登录。项目不承担旧项目的数据、账号或偏好迁移。当前阶段与验收状态见 [roadmap](docs/roadmap.md)。

## 添加本地音乐

1. 启动应用，在“文件”App 中打开“我的 iPhone → NeoMusic → 音乐”；也可以通过 Mac 访达的文件共享导入。
2. 将音乐放入该文件夹，返回应用或下拉资料库刷新。

每个直接包含歌曲的文件夹对应一张专辑，子文件夹独立。支持系统可解码的 MP3、AAC/M4A、ALAC、FLAC、WAV、AIFF。优先读取内嵌封面，也支持同目录的 `cover`／`folder` 图片。移动或重命名音乐文件会被识别为删除后新增。

## 构建

面向 **iOS 27+、iPhone**，使用 Swift 6、Xcode 27.1 或更新版本及 XcodeGen。最近验证环境、依赖版本和完整测试说明见 [开发指南](docs/development.md)。

```sh
brew install xcodegen
xcodegen generate
open NeoMusic.xcodeproj
```

选择 `NeoMusic` scheme 和 iPhone 模拟器即可运行。真机签名由开发者自行配置。

参与开发前请阅读 [项目规范](AGENTS.md)。`project.yml` 是工程配置的唯一编辑来源；生成工程、测试资料和账户预览说明集中在开发指南中。

[CI](https://github.com/Fab1e2000/NeoMusic/actions/workflows/ci.yml) 自动检查模块边界并运行正式测试 target。[Release 工作流](https://github.com/Fab1e2000/NeoMusic/actions/workflows/release.yml) 可手动生成未签名 IPA；版本标签生成 Release 草稿，检查后再发布。未签名 IPA 需要自行签名才能安装，流程说明见 [开发指南](docs/development.md#ci-与-release)。

## 来源与许可

播放器前端从 NeoDizzy 适配，包含源自 MeloX / MeloX_Modified 的 **GPL-3.0** 代码。项目同时使用 LNPopupUI、LNPopupController、Nuke 等依赖，保留各自的 MIT 许可与改动说明。

- [播放器来源声明](NeoMusic/Features/Player/Resources/PlayerSourceNotices.txt)与[导入清单](NeoMusic/Features/Player/Resources/PlayerSourceManifest.json)
- [网易云账户协议与认证来源声明](NeoMusic/Resources/NeteaseSourceNotices.txt)
- [GPL-3.0 全文](NeoMusic/Features/Player/Resources/GPL-3.0.txt)、[第三方声明](NeoMusic/Features/Player/ThirdPartyLicenses.txt)与[Nuke 许可](NeoMusic/Features/Player/Resources/Nuke-LICENSE.txt)
- [LNPopupUI 改动说明](Packages/LNPopupUI/NEOMUSIC-PATCHES.md)与[LNPopupController 改动说明](Packages/LNPopupController/NEOMUSIC-PATCHES.md)

NeoMusic 采用 [GNU GPL v3.0](LICENSE)；上述第三方代码继续保留各自的版权与许可声明。NeoMusic 是独立项目，与网易云音乐或 Apple 没有官方隶属关系。
