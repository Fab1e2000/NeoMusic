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
| AudioTags / TagLib | TagLib 2.3.2 的 MP3／FLAC 标签封装 | `Packages/AudioTags` |

远程依赖版本由 `project.yml` 和工程内的 `Package.resolved` 锁定，首次构建需要解析远程包。播放器来源、导入基线与哈希保留在 [来源清单](../NeoMusic/Features/Player/Resources/PlayerSourceManifest.json)；其哈希记录上游导入来源，不是当前文件完整性校验值。

## 正式运行路径

- **应用启动**由 `NeoMusicApp` 持有账户和在线资料库、主页、艺人、搜索、下载装配实例，并立即显示 `LocalLibrary` 装配的界面。本地缓存恢复后预热首屏封面并释放资料库显示，账号缓存与历史独立恢复。迷你播放器在已读取的账号身份和本地队列就绪后恢复暂停进度。随后并行扫描目录、加载其余在线缓存、验证账号及准备在线封面。恢复中的稳定引用继续保留，后台扫描失败或取消保留已显示内容，回到前台继续扫描与账户重验。
- **网易云账户**：`NeoMusicApp` 持有唯一 `NeteaseAccount`，初始化时读取已保存的最大 192 px 头像显示快照，供首帧使用；Keychain 恢复与网络校验继续异步执行，与本地资料库恢复并行。读取 Keychain 后发布账户资料，核对快照所属用户，并后台刷新头像；同一用户的头像 URL 变化时保留现有显示，直到新图加载成功。从后台返回时重新校验账户。`LibraryAppTabs` 与资料库导航创建 SwiftUI hosting root 时显式传递同一账户实例；五个主标签的头像共用账户状态。恢复和校验独立于账户页面是否打开。
- **启动呈现**：页面完成首次显示且状态恢复后，整块置顶区作为一行插入原生列表，推动分类与最近添加向下移动；页面显示状态来自 UIKit 的 `viewDidAppear`，返回资料库保留置顶布局。内容填入不替换导航容器。各标签页面通过原生 `UITab` 内容提供闭包按需创建。
- **启动缓存与封面**：`tracks.json` 是唯一曲目索引，只保存元数据、封面键与背景色；`tracks.json.startup` 保存按内容去重的原始封面文件。既有启动索引首次导入后移除，原来内嵌的封面在缓存 actor 中分离；背景色继续复用 `artwork-backdrops.json`，新封面才计算。界面通过文件 URL 引用封面，按实际显示尺寸用 ImageIO 在后台生成缩略图，并共享内存缓存；播放器适配直接使用同一文件。后台扫描修复缺失的派生封面。这些缓存均可重建，音乐文件、歌单与队列的格式保持不变。
- **在线装配**通过 `OnlineMusicIntegration`、`HomeMusicIntegration`、`ArtistMusicIntegration`、`SearchMusicIntegration` 和 `DownloadMusicIntegration` 连接既有页面、资料库及播放器。网络、凭据、请求与账号状态归 `Core/Netease`。页面缓存按账号与资源键保存到 SQLite，封面管线合并请求并按账号隔离。本地持久化恢复后发布在线镜像，保留按账号保存的整理偏好。
- **混合引用**将在线歌曲保存为 `netease:<账号 ID>:<歌曲 ID>`，临时音源 URL 在播放前解析。本地歌单可引用在线歌曲。在线歌单曲目保持只读，歌曲喜欢及歌单、艺人、专辑收藏通过业务入口同步网易云。本应用的置顶及文件夹归属另行保存，本地扫描只清理本地引用。
- **下载与离线播放**由 `NeteaseDownloadStore` 管理原生后台传输和记录，`DownloadBackgroundDelegate` 接收系统后台会话事件。完成文件校验、NCM 解码及标签写入后保存到“音乐／网易云”，下载装配发布状态并连接通用离线资源解析。已下载文件在退出账号后继续可用，移除下载保留歌单和队列引用。
- **播放**：`NowPlayingModel` 拥有队列与播放状态，恢复时仅还原队列、进度和暂停状态并注册系统媒体动作；首次播放才创建 `LocalPlaybackEngine` 和加载音频。系统媒体封面异步读取，取消旧请求后更新；相邻封面预取在播放或展开播放器时启动。`ReferencePlayerState` 只适配这个真实模型，不维护第二份演示队列或模拟时钟。
- **界面**：`Features/Library` 管理资料库；`Features/Player/Imported` 保留已接入的播放器与歌词展示代码，`Features/Player/Support` 连接真实状态、动作及歌词存储。保留 `Reference` 类型名与来源标记不代表这些组件仍是预览功能。
- **导航**：资料库继续使用现有 UIKit 导航与原生 zoom，顶部滚动边缘效果、栏位配色和播放器呈现沿用现有接线。
- **歌词与动作**：歌词适配连接 `LyricsReader`；收藏、加入歌单与页面跳转由资料库注入。测试输入只存在于测试 target。

独立播放器预览 target、zoom 实验入口及已无调用的旧播放器展示分支已移除。历史设计差分保留在 `design/`，不属于应用资源。

## 主页与搜索

`Features/Home` 沿用 `NeoMusic_Experiment/OrangeCardDemo` 的已确认布局，由 `HomeMusicIntegration` 将真实账号内容发布为 `HomeContentModel`。正式入口包含每日推荐、热歌、心动模式、私人雷达、私人漫游和相似歌曲，以及服务端实际提供的推荐歌单、排行榜、关注艺人新动向等栏目。最近播放记录本应用内成功播放的集合。未登录可浏览公共内容，需登录的播放通过统一账户入口续接。私人漫游接近队尾时请求后续批次。

快捷入口、大卡和三行歌曲推荐使用 Apple 的 `scrollTargetLayout` 与 `scrollTargetBehavior(.viewAligned)`，方形栏目采用自由横向滚动。主页保留 248×330 pt 大卡、161 pt 专辑封面及 20 pt 边距，导航、封面 zoom 和底部真实播放器共用正式应用入口。[Apple 滚动对齐 API](https://developer.apple.com/documentation/swiftui/view/scrolltargetbehavior(_:))

`Features/Search` 通过 `SearchMusicIntegration` 使用网易云搜索业务，提供分类歌单、最近搜索、输入联想及歌曲／艺人／专辑／歌单结果，也支持资料库范围查询。分类和搜索结果分页、缓存、去重、最近查询及账号隔离归业务层，页面复用正式详情、播放与歌曲菜单。

`Resources/HomeAssets.xcassets` 保留实验主页图标和封面样本，供既有隔离预览使用。样本来自用户提供截图的裁切，作品版权归原权利人。正式内容封面使用真实资源，电台和心情图案由 SwiftUI 绘制。

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

**CI** 在推送 `main`、提交 PR 或手动运行时依次执行脚本回归、模块边界检查、XcodeGen 工程生成及 `NeoMusicTests` 的 Release 测试，开启 `ENABLE_TESTABILITY`。脚本回归覆盖边界规则、推送门禁、CI 记录及 Release 草稿保护，使用临时仓库与隔离命令替身。测试本身完成编译。纯文档、设计参考与许可证改动跳过自动 CI，手动运行不受此限制。日志、`.xcresult` 和 `source-state.json` 保存 7 天。

CI 使用 iOS 27.0 的标准 iPhone 模拟器，不运行依赖外置音乐和基线应用的 UI 测试；Metal 和系统 zoom 用例按实际环境报告跳过，不能视为体验验收。

推送代码、脚本或工程变更时，仓库里的 `pre-push` 钩子运行 `scripts/ci.sh`。每个需要 CI 的待推 ref 都须指向当前 HEAD，附注标签先解析到提交。工作区须已保存全部已跟踪和未跟踪修改，忽略的构建产物可保留。一次推送多个代码 ref 时要求它们指向同一 HEAD，文档 ref 可指向其他提交。检查失败时先保存修改或切换到待推提交，再重新推送。

路径判断分别检查每个 ref，关闭重命名检测以保留源码删除路径。没有已知共同基线时检查目标提交的完整树，覆盖首次推送和合并提交。只含说明文档、`design/` 或许可证时跳过，与 Actions 的 `paths-ignore` 一致。开始 CI 前，钩子将已有结果包与来源记录分别保存为 `TestResults.previous.xcresult` 和 `source-state.previous.json`。

本机安装一次：

```sh
cp scripts/git-hooks/pre-push .git/hooks/pre-push
chmod +x .git/hooks/pre-push scripts/pre-push.sh
```

也可以手动运行：

```sh
bash scripts/ci.sh
bash scripts/release.sh
```

默认输出分别为 `build/ci/`、`build/release/` 和 `dist/`。可用 `NEOMUSIC_DERIVED_DATA` 指定已有构建目录。`build/ci/source-state.json` 记录提交 ID、开始和结束时的 dirty 标志、UTC 时间、退出码及通过／失败状态。手动运行 CI 可检查未提交工作，来源记录保留对应 dirty 状态。推送门禁要求干净 HEAD。直接再跑 `scripts/ci.sh` 时先移走旧的结果包及来源记录，保留它们的对应关系。

**Release** 的使用方式：

1. 修改 `project.yml` 中的 `MARKETING_VERSION`，更新 `CURRENT_PROJECT_VERSION`，运行 XcodeGen，并编写 `docs/releases/vX.Y.Z.md`。
2. 提交代码并确认 CI 通过。
3. 在 Actions 手动运行 Release 可先检查打包结果；它只上传 IPA 与 SHA-256 校验文件，不创建标签或发布版本。
4. 为确认好的提交创建并推送 `vX.Y.Z` 标签。标签须与工程版本一致，流程会生成未签名 IPA 和 Release 草稿。
5. 在 GitHub Releases 检查草稿、附件与更新说明，决定是否标为预发布，再点击发布。

标签工作流重跑时先查询 Release 草稿状态。已有草稿可重新上传附件并保持草稿，已发布版本拒绝更新。只有明确的 HTTP 404 才创建新草稿，查询失败立即停止。发布及 Latest 状态由用户在审阅后决定。

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

账户页面位于 `Features/Account`，正式构建中从主页、资料库、搜索以及挂到标签栏的资料库页面右上角头像进入。各入口使用同一 `AccountToolbar`，以资料库现有位置和 36 pt 头像样式为准。未登录先显示账户页，点身份卡后在临时 WebKit 页面完成网易云官网认证；已登录显示真实昵称和头像，账户设置提供切换及退出。账户页里的「标签页」用系统列表调整显示和顺序：默认是主页和资料库，搜索固定在末尾；喜爱歌曲、普通歌单、播放列表、专辑、艺人和歌曲可以添加或移除。普通歌单挂上后不显示页面标题。连同搜索最多 5 个。会话保存在 NeoMusic 专用 Keychain 项，切换成功后替换原账户，取消或失败保留原账户。退出只清理本机 NeoMusic 会话，本地音乐和歌单保持独立。

未登录、已登录、账户设置三态原生效果已获用户确认。Debug 仍可通过启动参数查看隔离的内存状态：

```sh
xcrun simctl launch <模拟器 UUID> com.elsterlee.NeoMusic -neteaseAccountPreview signed-out
xcrun simctl launch <模拟器 UUID> com.elsterlee.NeoMusic -neteaseAccountPreview signed-in
xcrun simctl launch <模拟器 UUID> com.elsterlee.NeoMusic -neteaseAccountPreview settings
```

每次切换状态先结束上一次应用进程。隔离预览使用合成账户资料，登录和切换入口不发起认证，不访问真实 Keychain 或网络。正常启动进入正式应用，并执行账户恢复和前台重验。

`NeteaseAssessmentReadProbe` 在带 `DEBUG` 编译条件的签名构建中提供真实账号只读核查。使用现有主页隔离预览的 `-homeRecommendationPreview guest -assessmentReadProbe` 启动参数，直接通过 Keychain 和正式 Client 读取。报告保存至 Application Support 下的 `AssessmentReadProbe/result.json`，只包含计数、布尔值、枚举和错误码。真机核查使用原应用与 Keychain 签名身份，正常 Release 编译条件为空。

定向回归按影响选择 `NeteaseAccountTests`、`NeteaseAvatarSnapshotTests`、`NeteaseAvatarClientTests`、`NeteaseAccountClientTests` 与 `NeteaseCredentialStoreTests`；边界规则回归运行 `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests`。

账户相关累计 63 项回归已有通过结果：最新 32 项账户回归通过，复用显示快照 7 项结果，本轮共 39 项；另复用头像客户端 9 项、账户客户端 8 项及凭据存储 7 项的通过结果。21 项入口／导航回归复用既有通过结果，覆盖 109 个源文件的模块边界扫描及 6 项边界规则回归通过，0 失败、0 跳过。回归覆盖 Keychain 等待期间的原生头像渲染、快照身份核对、192 px 缩略图持久化、退出／切换等待快照写入，以及同用户 CDN 地址轮换时保留头像、加载失败后的重试和旧 URL 迟到结果丢弃。显示快照版已通过真机 Release 构建、验签、覆盖安装和启动；App Launch 记录显示 75,227 字节快照在首帧前读取，读取耗时约 0.22 ms。前后各一次采样的系统初始化至首帧区间为 203.51 ms 和 196.14 ms，证据位于忽略目录 `build/netease-avatar-startup-20261103/`。

## 当前限制与后续准备

- 网易云账户、歌单、推荐、艺人／专辑、搜索、在线播放及下载已接入正式入口，整体处于用户体验验收阶段。各功能的真机、真实账号及待验收范围以 [roadmap](roadmap.md) 为准。
- 主页、资料库、搜索的头像入口已接入。挂到标签栏的喜爱歌曲、普通歌单、播放列表、专辑、艺人和歌曲，在作为根页面时也使用同一头像入口。普通歌单作为标签根页面时不显示标题。新发现和广播不再出现在底部标签栏。搜索主体仍随现有搜索页。显示哪些标签以及顺序，在账户页的「标签页」里调整。
- 专辑封面取色仍包含私有 `MPArtworkColorAnalyzer` 实验；本次整理不修改其实现，也不代表完成 App Store 发布验收。
- 播放器连续交互、不同封面可读性及完整系统媒体能力仍按 [roadmap](roadmap.md) 的状态验收。
- 首次公开从清理后的当前快照开始，旧开发历史仅保留在本地归档分支，不推送到公开仓库；根许可证为 [GPL-3.0](../LICENSE)。
- 创建仓库及提交代码不代表完整发布体验验收；正式版本通过上述 Release 草稿流程另行发布。
