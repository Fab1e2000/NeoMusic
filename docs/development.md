# 开发指南

## 环境与工程

- Xcode 27.1 或更新版本；当前本机为 Xcode 27.2（27B52），模拟器 runtime 为 iOS 27.0。
- Swift 6、iOS 27.0+，当前以 iPhone 为开发与验收目标。
- XcodeGen：`brew install xcodegen`。

唯一正式应用 target 与主 scheme 均为 `NeoMusic`，Bundle ID 为 `com.elsterlee.NeoMusic`。`NeoMusicTests` 是单元测试；`NeoMusicNavigationUITests` 是交互测试。`NeoMusicFunctionalParity` scheme 用于已有基线与当前正式应用的专项对照，不是另一份应用实现。

修改 `project.yml` 后运行 `xcodegen generate`，将生成的工程变更一起提交。不要手工修改生成的工程来替代源配置，也不要将本机签名信息写入共享配置。

## 依赖与来源

| 依赖 | 当前版本或基线 | 位置 |
| --- | --- | --- |
| LNPopupUI | `60853564423524c9ed15cc74c5969d3e1ca666f1`，含已记录的本地修改 | `Packages/LNPopupUI` |
| LNPopupController | 4.6.1，含已记录的本地修改 | `Packages/LNPopupController` |
| Nuke | 13.2.0 | Swift Package Manager |
| LNSwiftUIUtils | 1.1.5 | Swift Package Manager |
| LNSystemMarqueeLabel | 0.1.2 | Swift Package Manager |

远程依赖版本由 `project.yml` 和工程内的 `Package.resolved` 锁定，首次构建需要解析远程包。播放器来源、导入基线与哈希保留在 [来源清单](../NeoMusic/Features/Player/Resources/PlayerSourceManifest.json)；其哈希记录上游导入来源，不是当前文件完整性校验值。

## 正式运行路径

- **应用启动**：`NeoMusicApp` 立即显示 `LocalLibrary` 装配的 `AppShell`，资料库标题、顶部按钮、分类入口与系统标签栏先出现。`LocalLibraryRuntime` 将恢复已存状态与核对音乐目录分开：在缓存 actor 读取曲目索引、歌单与队列，再发布到界面；恢复期间歌曲与封面留空，新建歌单和分类导航禁用。歌单和队列保留暂未解析的歌曲标识，缓存缺失或引用不完整时也能先结束恢复，随后扫描补齐；已知旧标识修复仍在解析持久化引用前完成。后台扫描失败或取消保留已显示内容，未变化的内容跳过发布与重写，回到前台继续刷新资料库。
- **启动呈现**：页面完成首次显示且状态恢复后，整块置顶区作为一行插入原生列表，推动分类与最近添加向下移动；页面显示状态来自 UIKit 的 `viewDidAppear`，返回资料库保留置顶布局。内容填入不替换导航容器。各标签页面通过原生 `UITab` 内容提供闭包按需创建。
- **启动缓存与封面**：`tracks.json` 是唯一曲目索引，只保存元数据、封面键与背景色；`tracks.json.startup` 保存按内容去重的原始封面文件。既有启动索引首次导入后移除，原来内嵌的封面在缓存 actor 中分离；背景色继续复用 `artwork-backdrops.json`，新封面才计算。界面通过文件 URL 引用封面，按实际显示尺寸用 ImageIO 在后台生成缩略图，并共享内存缓存；播放器适配直接使用同一文件。后台扫描修复缺失的派生封面。这些缓存均可重建，音乐文件、歌单与队列的格式保持不变。
- **播放**：`NowPlayingModel` 拥有队列与播放状态，恢复时仅还原队列、进度和暂停状态并注册系统媒体动作；首次播放才创建 `LocalPlaybackEngine` 和加载音频。系统媒体封面异步读取，取消旧请求后更新；相邻封面预取在播放或展开播放器时启动。`ReferencePlayerState` 只适配这个真实模型，不维护第二份演示队列或模拟时钟。
- **界面**：`Features/Library` 管理资料库；`Features/Player/Imported` 保留已接入的播放器与歌词展示代码，`Features/Player/Support` 连接真实状态、动作及歌词存储。保留 `Reference` 类型名与来源标记不代表这些组件仍是预览功能。
- **导航**：资料库继续使用现有 UIKit 导航与原生 zoom，顶部滚动边缘效果、栏位配色和播放器呈现沿用现有接线。
- **歌词与动作**：歌词适配连接 `LyricsReader`；收藏、加入歌单与页面跳转由资料库注入。测试输入只存在于测试 target。

独立播放器预览 target、zoom 实验入口及已无调用的旧播放器展示分支已移除。历史设计差分保留在 `design/`，不属于应用资源。

## 主页展示

`Features/Home` 移植自 `NeoMusic_Experiment/OrangeCardDemo` 的 `HomeFeedView.swift`、`HomeFixtures.swift` 和 `HomeArtwork.swift`，保留 15 个栏目及固定展示数据。它不读写本地资料库，也不提供在线推荐、播放或详情服务。主页标签接入原有 `UITabBarController`，底部继续使用真实播放器；账户入口复用现有账户效果稿。

横排使用 Apple 的 [`scrollTargetLayout` 与 `scrollTargetBehavior(.viewAligned)`](https://developer.apple.com/documentation/swiftui/view/scrolltargetbehavior(_:))，由系统处理手势、减速和卡片对齐。主页浅色外观及 248×330 pt 大卡、161 pt 专辑封面、20 pt 边距沿用实验页面。

`Resources/HomeAssets.xcassets` 包含实验主页图标与 23 张封面样本。封面来自实验项目中用户提供截图的裁切，作品版权归原权利人；电台和心情图案由 SwiftUI 绘制。

## 图标与资源

正式图标源为 [NeoMusicIcon.icon](../NeoMusic/Resources/AppIcons/NeoMusicIcon.icon)，使用已确认的 F6 黑色方案。默认外观四层采用黑色填充，以不透明度形成灰阶；深色反白、Mono 使用白色遮罩供系统着色，这组差分也已获确认。白底、圆角、玻璃与阴影由 Icon Composer 管理，形状和层次在各外观下保持一致。工程中的 App Icon 名称为 `NeoMusicIcon`。

README 图片从正式图标导出，不从旧样稿另画：

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  NeoMusic/Resources/AppIcons/NeoMusicIcon.icon --export-image \
  --output-file docs/images/app-icon.png --platform iOS --rendition Default \
  --width 512 --height 512 --scale 1 --design-generation 27
```

原生 `.icon` 接入及外观定制参照 [Apple Icon Composer 指南](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。当前默认、深色、着色与清透外观已用自带渲染器导出检查；静态预览不替代真机动态材质的体验验收。

## 构建与测试

先运行边界检查并生成工程：

```sh
python3 scripts/check-module-boundaries.py
xcodegen generate
xcodebuild -showdestinations -project NeoMusic.xcodeproj -scheme NeoMusic
```

将以下目的地中的 UUID 换成本机已有的 iPhone 模拟器。Release 定向测试会构建应用，不需要再单独重复编译：

```sh
xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Release \
  -destination 'platform=iOS Simulator,id=<模拟器 UUID>' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -only-testing:NeoMusicTests test
```

按修改范围缩小到具体测试类即可。重包装的重点是播放器适配、队列、歌词、资料库恢复、持久化及导航；原预览 target 的有效测试已迁入 `NeoMusicTests`，直接使用正式组件。单元测试的歌曲和图片在测试中生成，部分 Metal 与系统 zoom 用例有运行环境要求。

导航 UI 测试需要既有的模拟器资料库。例如 `testNativeAlbumRowPlaybackMenusAndSwipes` 使用“塌陷于38°C的蓝”专辑及“湖畔、二人歌”；部分置顶测试需要 Sunrise 专辑。音乐文件不随仓库提供，全新模拟器不能直接视为具备这些测试条件。功能对照 scheme 还需要另外安装基线应用。测试时不要删除或替换用户的真机资料库。

不运行测试、只需要模拟器构建时：

```sh
xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

边界检查覆盖当前正式源码的导入归属，允许既有播放器依赖；网易云接入开始时再补相应来源边界。它不是对尚不存在的网易云服务或账号隔离的验收。

## CI 与 Release

GitHub Actions 使用 `xcode-27` 托管 runner 与 Xcode 27.1，版本依据 [GitHub runner 软件清单](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)。该 runner 仍处于预览期。

**CI** 在推送 `main`、提交 PR 或手动运行时执行：模块边界检查、XcodeGen 工程生成，以及 `NeoMusicTests` 的 Release 测试，开启 `ENABLE_TESTABILITY`。测试本身完成编译，不另做重复构建。纯文档、设计参考与许可证改动跳过自动 CI；手动运行不受此限制。日志与 `.xcresult` 保存 7 天。

CI 使用 iOS 27.0 的标准 iPhone 模拟器，不运行依赖外置音乐和基线应用的 UI 测试；Metal 和系统 zoom 用例按实际环境报告跳过，不能视为体验验收。

本地运行同一套流程：

```sh
bash scripts/ci.sh
bash scripts/release.sh
```

默认输出分别为 `build/ci/`、`build/release/` 和 `dist/`。可用 `NEOMUSIC_DERIVED_DATA` 指定已有构建目录；重复测试前另行保存或移走旧 `build/ci/TestResults.xcresult`，脚本不会覆盖已有测试证据。

**Release** 的使用方式：

1. 修改 `project.yml` 中的 `MARKETING_VERSION`，更新 `CURRENT_PROJECT_VERSION`，运行 XcodeGen，并编写 `docs/releases/vX.Y.Z.md`。
2. 提交代码并确认 CI 通过。
3. 在 Actions 手动运行 Release 可先检查打包结果；它只上传 IPA 与 SHA-256 校验文件，不创建标签或发布版本。
4. 为确认好的提交创建并推送 `vX.Y.Z` 标签。标签须与工程版本一致，流程会生成未签名 IPA 和 Release 草稿。
5. 在 GitHub Releases 检查草稿、附件与更新说明，决定是否标为预发布，再点击发布。

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

公开构建不启用账户效果稿、不带个人素材或签名凭据；IPA 需自行签名后安装。流程不提供 App Store / TestFlight 发布，也不改变当前私有取色实现。源码及依赖版本与对应标签一起保留，第三方许可和来源清单随应用打包。

## 本地数据与签名

音乐目录保持为应用 Documents 下的“音乐”，歌单、队列、歌词和偏好沿用既有路径、格式及键。可重建的曲目缓存采用上述轻量索引和独立封面文件。安装沿用既有 Bundle ID，保留用户文件和持久化键。

真机构建时在 Xcode 的 `NeoMusic` target → Signing & Capabilities 中选择本机开发团队，使用该团队可用的签名配置；也可在命令行传入本机签名设置。现有手机体验包使用的安装身份由本机打包步骤处理，不固化到共享工程。签名包、设备标识和个人音乐不能入库。

## 账户效果稿例外

用户要求暂时保留已确认的头像和账户页面，直至真实网易云账户接入。这是界面效果稿，不具备在线账户能力。

- Debug 使用 `-accountReferencePreview` 启动参数，读取应用临时目录下的 `AccountReference`。
- 私人 Release 体验包保留 `ACCOUNT_REFERENCE_PREVIEW` 编译条件，并在签名前放入外置 `AccountReference` 文件夹。
- 文件夹中的 `profile.json`、`photo.png` 和 `account-symbol.png` 来自本机外部素材，不进入公开仓库。默认 Release 构建没有该编译条件或个人素材。

本地歌单作者显示“我”，不把开发者的个人姓名作为所有用户的默认作者。

## 当前限制与后续准备

- 网易云尚未接入。登录、浏览、搜索、播放和下载的具体范围需通过下一阶段调研确定，本轮不预建服务或注册框架。
- 专辑封面取色仍包含私有 `MPArtworkColorAnalyzer` 实验；本次整理不修改其实现，也不代表完成 App Store 发布验收。
- 播放器连续交互、不同封面可读性及完整系统媒体能力仍按 [roadmap](roadmap.md) 的状态验收。
- 首次公开从清理后的当前快照开始，旧开发历史仅保留在本地归档分支，不推送到公开仓库；根许可证为 [GPL-3.0](../LICENSE)。
- 创建仓库及提交代码不代表完整发布体验验收；正式版本通过上述 Release 草稿流程另行发布。
