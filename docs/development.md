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
- **网易云账户**：`NeoMusicApp` 持有唯一 `NeteaseAccount`，初始化时读取已保存的最大 192 px 头像显示快照，供首帧使用；Keychain 恢复与网络校验继续异步执行，与本地资料库恢复并行。读取 Keychain 后发布账户资料，核对快照所属用户，并后台刷新头像；同一用户的头像 URL 变化时保留现有显示，直到新图加载成功。从后台返回时重新校验账户。`LibraryAppTabs` 与资料库导航创建 SwiftUI hosting root 时显式传递同一账户实例；五个主标签的头像共用账户状态。恢复和校验独立于账户页面是否打开。
- **启动呈现**：页面完成首次显示且状态恢复后，整块置顶区作为一行插入原生列表，推动分类与最近添加向下移动；页面显示状态来自 UIKit 的 `viewDidAppear`，返回资料库保留置顶布局。内容填入不替换导航容器。各标签页面通过原生 `UITab` 内容提供闭包按需创建。
- **启动缓存与封面**：`tracks.json` 是唯一曲目索引，只保存元数据、封面键与背景色；`tracks.json.startup` 保存按内容去重的原始封面文件。既有启动索引首次导入后移除，原来内嵌的封面在缓存 actor 中分离；背景色继续复用 `artwork-backdrops.json`，新封面才计算。界面通过文件 URL 引用封面，按实际显示尺寸用 ImageIO 在后台生成缩略图，并共享内存缓存；播放器适配直接使用同一文件。后台扫描修复缺失的派生封面。这些缓存均可重建，音乐文件、歌单与队列的格式保持不变。
- **在线装配**：`OnlineMusicIntegration` 将账户业务结果转换为通用歌曲、歌单与异步播放资源，在线网络与凭据始终由 `Core/Netease` 持有。本地持久化恢复完成后才发布在线镜像，避免覆盖按账号保存的整理偏好。`NeteaseMusicStore` 在账户恢复、重验及切换／退出时加载或清理资料；JSON 与封面缓存按账号隔离。
- **混合引用**：在线歌曲保存 `netease:<账号 ID>:<歌曲 ID>`，临时音源 URL 只在播放前解析；本地扫描只清理本地引用。在线歌单是只读镜像，本应用的置顶、喜爱及文件夹归属另行保存。本地歌单可以保存在线歌曲引用。
- **播放**：`NowPlayingModel` 拥有队列与播放状态，恢复时仅还原队列、进度和暂停状态并注册系统媒体动作；首次播放才创建 `LocalPlaybackEngine` 和加载音频。系统媒体封面异步读取，取消旧请求后更新；相邻封面预取在播放或展开播放器时启动。`ReferencePlayerState` 只适配这个真实模型，不维护第二份演示队列或模拟时钟。
- **界面**：`Features/Library` 管理资料库；`Features/Player/Imported` 保留已接入的播放器与歌词展示代码，`Features/Player/Support` 连接真实状态、动作及歌词存储。保留 `Reference` 类型名与来源标记不代表这些组件仍是预览功能。
- **导航**：资料库继续使用现有 UIKit 导航与原生 zoom，顶部滚动边缘效果、栏位配色和播放器呈现沿用现有接线。
- **歌词与动作**：歌词适配连接 `LyricsReader`；收藏、加入歌单与页面跳转由资料库注入。测试输入只存在于测试 target。

独立播放器预览 target、zoom 实验入口及已无调用的旧播放器展示分支已移除。历史设计差分保留在 `design/`，不属于应用资源。

## 主页展示

`Features/Home` 移植自 `NeoMusic_Experiment/OrangeCardDemo` 的 `HomeFeedView.swift`、`HomeFixtures.swift` 和 `HomeArtwork.swift`，保留 15 个栏目及固定展示数据。它不读写本地资料库，也不提供在线推荐、播放或详情服务。主页标签接入原有 `UITabBarController`，底部继续使用真实播放器；标题和头像使用 `NavigationStack`、`inlineLarge` 与统一的 `AccountToolbar`，导航滚动采用资料库的原生策略。

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

上述关闭签名的命令适用于注入凭据存储的账户单元测试。验证正式账户入口及真实 Keychain 读写时，模拟器构建须启用代码签名，移除 `CODE_SIGNING_ALLOWED=NO`；本轮已通过签名模拟器构建确认 Keychain 读取正常。

导航 UI 测试需要既有的模拟器资料库。例如 `testNativeAlbumRowPlaybackMenusAndSwipes` 使用“塌陷于38°C的蓝”专辑及“湖畔、二人歌”；部分置顶测试需要 Sunrise 专辑。音乐文件不随仓库提供，全新模拟器不能直接视为具备这些测试条件。功能对照 scheme 还需要另外安装基线应用。测试时不要删除或替换用户的真机资料库。

不运行测试、只需要模拟器构建时：

```sh
xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

边界检查覆盖全部 Swift 与 Objective-C 源文件，限制网易云网络和凭据代码归属 `Core/Netease`、WebKit 认证界面归属 `Features/Account`；App 只负责装配。通用播放器与本地资料库不得引用网易云类型或承担账户请求，网易云业务不得访问本地资料库和播放状态。既有播放器依赖继续按目录限制。

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

公开构建包含正式账户入口，不带个人素材、已登录会话或签名凭据；IPA 需自行签名后安装。流程不提供 App Store / TestFlight 发布，也不改变当前私有取色实现。源码及依赖版本与对应标签一起保留，第三方许可和来源清单随应用打包。

## 本地数据与签名

音乐目录保持为应用 Documents 下的“音乐”，歌单、队列、歌词和偏好沿用既有路径、格式及键。可重建的曲目缓存采用上述轻量索引和独立封面文件。安装沿用既有 Bundle ID，保留用户文件和持久化键。

真机构建时在 Xcode 的 `NeoMusic` target → Signing & Capabilities 中选择本机开发团队，使用该团队可用的签名配置；也可在命令行传入本机签名设置。现有手机体验包使用的安装身份由本机打包步骤处理，不固化到共享工程。签名包、设备标识和个人音乐不能入库。

本地歌单作者显示“我”，不把开发者的个人姓名作为所有用户的默认作者。

## 网易云账户与隔离预览

首轮账户业务位于 `Core/Netease`，以原生 EAPI 查询真实资料；Keychain actor 在后台读写 NeoMusic 专用记录，构造账户实例不触发网络或凭据读取。账户所有者管理恢复、重验、候选登录、退出和头像任务，取消后等待任务收尾再替换会话。协议来源见 [账户来源声明](../NeoMusic/Resources/NeteaseSourceNotices.txt)。

头像使用专用原生 `URLCache` 按头像 URL 保存磁盘缓存，并按系统 HTTP 缓存策略刷新。`NeteaseAvatarSnapshotStore` 另将当前头像用 ImageIO 缩为最大 192 px PNG，保存到 Caches 的单条二进制显示快照；文件仅含用户 ID、头像 URL 和图片，不含昵称或凭据。账户初始化同步读取这一大小受限的文件，读取上限为 256 KiB；缩略图生成与原子写入由 `@concurrent` 在后台执行。Keychain 读出相同用户且仍有头像时保留初图，凭据缺失、用户变化或头像变为空时清除旧快照。

头像恢复与账户网络校验并行，显示快照的保存归属已有头像任务。网易云会为同一用户、同一张图片轮换 CDN 地址；同一用户的 URL 更新保留当前头像，取消并等待旧请求收尾后按新 URL 刷新，新图成功返回后替换显示。请求与结果发布仍严格核对会话、用户 ID 和完整 URL，旧 URL 的迟到结果丢弃。成功切换至其他用户、退出、明确鉴权失效或头像变为空时清理缓存与快照；切换或退出失败保留原缓存。

账户页面位于 `Features/Account`，正式构建中从主页、新发现、广播、资料库、搜索五个主标签的右上角头像进入。各入口使用同一 `AccountToolbar`，以资料库现有位置和 36 pt 头像样式为准。未登录先显示账户页，点身份卡后在临时 WebKit 页面完成网易云官网认证；已登录显示真实昵称和头像，账户设置提供切换及退出。会话保存在 NeoMusic 专用 Keychain 项，切换成功后替换原账户，取消或失败保留原账户。退出只清理本机 NeoMusic 会话，本地音乐和歌单保持独立。

未登录、已登录、账户设置三态原生效果已获用户确认。Debug 仍可通过启动参数查看隔离的内存状态：

```sh
xcrun simctl launch <模拟器 UUID> com.elsterlee.NeoMusic -neteaseAccountPreview signed-out
xcrun simctl launch <模拟器 UUID> com.elsterlee.NeoMusic -neteaseAccountPreview signed-in
xcrun simctl launch <模拟器 UUID> com.elsterlee.NeoMusic -neteaseAccountPreview settings
```

每次切换状态先结束上一次应用进程。隔离预览使用合成账户资料，登录和切换入口不发起认证，不访问真实 Keychain 或网络。正常启动进入正式应用，并执行账户恢复和前台重验。

定向回归按影响选择 `NeteaseAccountTests`、`NeteaseAvatarSnapshotTests`、`NeteaseAvatarClientTests`、`NeteaseAccountClientTests` 与 `NeteaseCredentialStoreTests`；边界规则回归运行 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests`。

账户相关累计 63 项回归已有通过结果：最新 32 项账户回归通过，复用显示快照 7 项结果，本轮共 39 项；另复用头像客户端 9 项、账户客户端 8 项及凭据存储 7 项的通过结果。21 项入口／导航回归复用既有通过结果，覆盖 109 个源文件的模块边界扫描及 6 项边界规则回归通过，0 失败、0 跳过。回归覆盖 Keychain 等待期间的原生头像渲染、快照身份核对、192 px 缩略图持久化、退出／切换等待快照写入，以及同用户 CDN 地址轮换时保留头像、加载失败后的重试和旧 URL 迟到结果丢弃。显示快照版已通过真机 Release 构建、验签、覆盖安装和启动；App Launch 记录显示 75,227 字节快照在首帧前读取，读取耗时约 0.22 ms。前后各一次采样的系统初始化至首帧区间为 203.51 ms 和 196.14 ms，证据位于忽略目录 `build/netease-avatar-startup-20261103/`。

## 当前限制与后续准备

- 网易云账户首轮已按用户确认收尾并本地提交，包含真实账户闭环、启动头像恢复及同用户 CDN 地址轮换时的连续显示。歌单、推荐、搜索、在线播放及下载属于后续范围。
- 五个主标签头像统一已接入，主页栏目与内容保持原样，新发现、广播及搜索的主体内容仍为占位。2 项定向 UI 回归与模块边界检查通过，原生截图已核对，真机 Release 包已覆盖安装；本轮待用户体验验收。
- 专辑封面取色仍包含私有 `MPArtworkColorAnalyzer` 实验；本次整理不修改其实现，也不代表完成 App Store 发布验收。
- 播放器连续交互、不同封面可读性及完整系统媒体能力仍按 [roadmap](roadmap.md) 的状态验收。
- 首次公开从清理后的当前快照开始，旧开发历史仅保留在本地归档分支，不推送到公开仓库；根许可证为 [GPL-3.0](../LICENSE)。
- 创建仓库及提交代码不代表完整发布体验验收；正式版本通过上述 Release 草稿流程另行发布。
