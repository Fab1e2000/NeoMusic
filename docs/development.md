# 开发指南

## 环境与工程

- Xcode 27.1 或更新版本；当前本机为 Xcode 27.2（27B52），模拟器 runtime 为 iOS 27.0。
- Swift 6、iOS 27.0+，当前以 iPhone 为开发与验收目标。
- XcodeGen：`brew install xcodegen`。

唯一正式应用 target 与主 scheme 均为 `NeoMusic`，Bundle ID 为 `com.elsterlee.NeoMusic`。`FullScreenPlayer` 是仅依赖 Apple 框架的内部 framework，`FullScreenPlayerTests` 独立验证组件接口与资源。`NeoMusicTests` 是应用及接入测试；`NeoMusicNavigationUITests` 是交互测试。`NeoMusicFunctionalParity` scheme 用于已有基线与当前正式应用的专项对照，不是另一份应用实现。

修改 `project.yml` 后运行 `xcodegen generate`，将生成的工程变更一起提交。不要手工修改生成的工程来替代源配置，也不要将本机签名信息写入共享配置。

## 依赖与来源

| 依赖 | 当前版本或基线 | 位置 |
| --- | --- | --- |
| LNPopupUI | `60853564423524c9ed15cc74c5969d3e1ca666f1`，含已记录的本地修改 | `Packages/LNPopupUI` |
| LNPopupController | 4.6.1，含已记录的本地修改 | `Packages/LNPopupController` |
| Nuke | 13.2.0 | Swift Package Manager |
| LNSwiftUIUtils | 1.1.5 | Swift Package Manager |
| LNSystemMarqueeLabel | 0.1.2 | Swift Package Manager |
| AudioStreaming（播放试验） | 上游 1.2.8，MeloX `3b937b3` 的准确定位修订；来源与许可见包内 NOTICE | `Packages/AudioStreaming` |
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
- **播放**：`NowPlayingModel` 拥有队列与播放状态，恢复时仅还原队列、进度和暂停状态并注册系统媒体动作；首次播放才创建 `LocalPlaybackEngine` 和加载音频。系统媒体封面异步读取，取消旧请求后更新；相邻封面预取在播放或展开播放器时启动。`NeoMusicPlaybackSource` 通过组件的 `PlayerState` 向界面提供这个真实模型，不维护第二份演示队列或模拟时钟。
- **界面**：`Features/Library` 管理资料库；`Features/Player/FullScreenPlayer` 独立编译全屏播放器、歌词和共享控件，`Features/Player/Integration` 接入实际播放、歌词存储、封面服务和 LNPopup 容器。
- **导航**：资料库继续使用现有 UIKit 导航与原生 zoom，顶部滚动边缘效果、栏位配色和播放器呈现沿用现有接线。
- **歌词与动作**：歌词适配连接 `LyricsReader`；收藏、加入歌单与页面跳转由资料库注入。测试输入只存在于测试 target。

独立播放器预览 App target、zoom 实验入口及已无调用的旧播放器展示分支已移除。历史设计差分保留在 `design/`，不属于应用资源。

## 全屏播放器组件

`FullScreenPlayer` 的源码、Metal 着色器与许可证集中在 [组件目录](../NeoMusic/Features/Player/FullScreenPlayer)。NeoMusic 将其作为 framework 链接和嵌入；组件 target 不链接 App、Nuke 或 LNPopup。未来可将该目录作为 framework target 加入其他 iOS 27+ 工程，资源随 framework 构建，无需带走 NeoMusic 业务代码。

公开入口为 `FullScreenPlayerView(player:services:initialPage:isActive:onDismiss:)`。默认从封面页开始，使用 `EmptyModifier` 作为封面转场修饰器；宿主可通过另一个带 `artworkTransition:` 参数的初始化方法接入容器转场。播放器退出时调用宿主回调，未传回调时使用 SwiftUI 的 dismiss。可见性由宿主的 `isActive` 和系统 scene phase 共同决定。

| 接口 | 宿主职责 |
| --- | --- |
| `PlayerPlaybackSource` → `PlayerState` | 使用 Observation 提供当前歌曲、进度、播放与队列状态；处理播放、切歌、重排及模式动作。读取直达宿主，组件不复制播放队列或创建计时器。歌曲 ID 为不透明字符串，队列 occurrence ID 为独立 UUID。 |
| `PlayerActions` | 提供喜欢状态、收藏／歌单动作、专辑与艺人导航、音质和设置入口；把 `PlayerNotice` 转换为宿主提示并提供触感。 |
| `PlayerLyricsSource` | 按歌曲 ID 返回已解析的 `PlayerLyrics`；可选提供文件导入。`contentRevision` 从宿主读取，导入和解析由宿主保存及处理。 |
| `PlayerArtworkProvider` | 按请求中的 URL、像素尺寸及缩放模式读取缓存、异步加载和预取 `UIImage`；处理尚未就绪的封面标识。加载应响应任务取消。 |
| `PlayerServices` | 组合动作、歌词、图片提供者和可选诊断回调。组件内的歌词请求、封面显示及背景渲染共用该上下文。 |

NeoMusic 的 [接入层](../NeoMusic/Features/Player/Integration) 将 `NowPlayingModel`、`LyricsReader`、Nuke 与上述接口连接。`ReferenceNowPlayingView` 是宿主组装入口；`NeoMusicArtworkTransition` 在组件提供的封面位置应用 LNPopup 的转场标记。迷你播放器继续归宿主所有，并复用组件公开的按钮、标题滑动和图标。容器的手势协调使用 `PlayerInteraction.trackSwipeGestureName`；音量 HUD 更新使用 `playerVolumeHUDRefreshID` 环境值。

组件内的布局和动画仍按现有参照渲染。Metal 与 SwiftUI shader 显式从 framework bundle 加载。来源清单保留上游基线，组件附带 GPL-3.0 许可与来源说明；Nuke、LNPopup 的说明保留在宿主。

`FullScreenPlayer` scheme 可单独构建和运行 `FullScreenPlayerTests`，其测试 target 不依赖 NeoMusic。公开接口消费者示例见 [组件测试](../FullScreenPlayerTests/PlayerContractTests.swift)。应用内三页截图、队列与手势测试继续在 `NeoMusicTests`、`NeoMusicNavigationUITests` 验证同一份正式组件。`scripts/ci.sh` 包含组件与应用单元测试。

## 主页与搜索

`Features/Home` 沿用 `NeoMusic_Experiment/OrangeCardDemo` 的已确认布局，由 `HomeMusicIntegration` 将真实账号内容发布为 `HomeContentModel`。正式入口包含每日推荐、热歌、心动模式、私人雷达、私人漫游和相似歌曲，以及服务端实际提供的推荐歌单、排行榜、关注艺人新动向等栏目。最近播放记录本应用内成功播放的集合。未登录可浏览公共内容，需登录的播放通过统一账户入口续接。私人漫游接近队尾时请求后续批次。

快捷入口、大卡和三行歌曲推荐使用 Apple 的 `scrollTargetLayout` 与 `scrollTargetBehavior(.viewAligned)`，方形栏目采用自由横向滚动。主页保留 248×330 pt 大卡、161 pt 专辑封面及 20 pt 边距，导航、封面 zoom 和底部真实播放器共用正式应用入口。[Apple 滚动对齐 API](https://developer.apple.com/documentation/swiftui/view/scrolltargetbehavior(_:))

`Features/Search` 通过 `SearchMusicIntegration` 使用网易云搜索业务，提供分类歌单、最近搜索、输入联想及歌曲／艺人／专辑／歌单结果，也支持资料库范围查询。分类和搜索结果分页、缓存、去重、最近查询及账号隔离归业务层，页面复用正式详情、播放与歌曲菜单。

`Resources/HomeAssets.xcassets` 保留实验主页图标和封面样本，供既有隔离预览使用。样本来自用户提供截图的裁切，作品版权归原权利人。正式内容封面使用真实资源，电台和心情图案由 SwiftUI 绘制。

## 触控反馈（Haptics）规范

全应用触控反馈遵循 [Apple HIG — Playing haptics](https://developer.apple.com/cn/design/human-interface-guidelines/playing-haptics) 的预设模式语义、全局一致性及克制使用原则。统一通过高层 API（`LibraryHaptics` 预热发生器或 SwiftUI `.sensoryFeedback`）触发，自动遵循系统「触感反馈」开关且不干扰音频播放。

### 触感类型与场景映射表

| 触感类型 | 系统 API / 统一入口 | 适用交互与业务场景 |
| --- | --- | --- |
| **成功 (Success)** | `LibraryHaptics.success()` / `.sensoryFeedback(.success)` | 1. **喜爱与取消喜爱**：曲目、专辑、歌单、艺人的喜爱切换（含菜单、左滑爱心、艺人页星标、播放器星标取消喜欢）<br>2. **收藏入库**：专辑、网易云歌单、艺人最新发行的圆形「`+`」收藏按钮<br>3. **置顶切换**：歌单或专辑的「置顶 / 取消置顶」<br>4. **加入歌单完成**：选单收起后弹出「已添加 N 首歌曲」Toast |
| **错误 (Error)** | `.sensoryFeedback(.error)` | 操作失败、未登录拦截或加载异常弹出红色感叹号 `LibraryToast.error` 时 |
| **柔型冲击 (Soft 0.6)** | `LibraryHaptics.impact()` / `.sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6))` | 1. **直接播放主入口**：主页三张直接播放卡（心动模式、私人漫游、相似歌曲），以及专辑／歌单详情页顶部的「播放」「随机播放」大按钮<br>2. **队列编排提示**：「插播（下个播放）」「添加到队列（最后播放）」Toast 弹出时<br>3. **下载控制**：详情页下载按钮、详情右上角菜单、卡片长按菜单、曲目行状态圈及左滑的「下载 / 停止下载 / 重试下载」 |
| **轻型冲击 (Light)** | `LibraryHaptics.lightImpact()` / `UIImpactFeedbackGenerator(style: .light)` | 1. **轻量移除确认**：居中弹窗确认「从喜欢歌曲移除」或「从播放列表移除」单曲；系统弹窗确认「移除下载」本机文件<br>2. **播放器队列停靠**：全屏队列列表(`NowPlayingQueueList`)滚动经过或吸附到顶部两个停靠锚点（头部完整露出／刚好收起） |
| **中型冲击 (Medium)** | `LibraryHaptics.mediumImpact()` | **整单／整辑删除确认**：系统弹窗确认「从资料库删除」整个播放列表或专辑 |
| **选择 (Selection)** | `ReferenceTrackSwipeFeedback.selection()` (`UISelectionFeedbackGenerator`) | **横向滑动切歌**：全屏封面或迷你播放条横向拖动跨过切歌阈值（38%），回退至 22% 内重新武装 |
| **无额外触感 (None)** | 仅依赖视觉动画或系统原生控件自带触感 | 普通点击歌曲行播放、推页/Zoom 导航卡片、全屏/迷你常规播放控制按钮、进度条与音量条按住缩放及甩滑 |

### 开发与维护约束

- **禁止双重触发**：已在按钮或菜单点击瞬间直接触发 `LibraryHaptics` 的操作（如喜爱、取消喜爱、置顶、取消置顶），在 `LibraryToastFeedback` 中必须排除对应的 Toast 震动，确保一次操作只产生一次触感。
- **确认后再触发破坏性触感**：涉及二次确认弹窗的操作（移除喜欢歌曲、从歌单移除曲目、移除本机下载、删除整个歌单/专辑），触感只在用户点击弹窗的最终确认按钮时触发，弹出确认框前不额外触发。
- **发生器预热**：手势驱动或高频点按的触感（切歌拖动、队列滚动停靠、`LibraryHaptics` 静态发生器）需在手势开始或触发后调用 `prepare()`，降低 Taptic Engine 唤醒延迟。

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

按修改范围缩小到具体测试类即可。主要覆盖播放器适配、队列、歌词、资料库恢复、持久化及导航；原预览 target 的有效测试已迁入 `NeoMusicTests`，直接使用正式组件。单元测试的共享歌曲、图片、音频会话及窗口场景辅助集中在 `NeoMusicTests/TestFixtures.swift`；静音音频按每个用例所需时长独立生成并沿用用例内清理。部分 Metal 与系统 zoom 用例有运行环境要求。

上述关闭签名的命令适用于注入凭据存储的账户单元测试。验证正式账户入口及真实 Keychain 读写时，模拟器构建须启用代码签名，移除 `CODE_SIGNING_ALLOWED=NO`；

导航 UI 测试需要既有的模拟器资料库。例如 `testNativeAlbumRowPlaybackMenusAndSwipes` 使用“塌陷于38°C的蓝”专辑及“湖畔、二人歌”；部分置顶测试需要 Sunrise 专辑。音乐文件不随仓库提供，全新模拟器不能直接视为具备这些测试条件。功能对照 scheme 还需要另外安装基线应用。测试时不要删除或替换用户的真机资料库。

全屏播放器性能专项使用 `FullScreenPlayerPerformanceTests`，启动参数为 `-frontendReviewPreview player-performance`。该入口仅在 `DEBUG` 编译条件下存在，自动生成 30 首本地静音歌曲及每首 200 行歌词，复用正式播放引擎、弹出容器和全屏组件。使用 Release 优化并额外启用 `DEBUG` 条件，通过本机 xcconfig 为应用与测试 runner 指定独立 Bundle ID 和开发签名；账号、音乐与测试播放记录相互隔离。运行时设置 `TEST_RUNNER_NEOMUSIC_PLAYER_PERFORMANCE=1`，普通测试默认跳过此专项。

`testAutomaticScenario` 自动执行三轮测量（另有 XCTest 预热轮），覆盖切页、队列与歌词滚动、歌词跳转、切歌、进度拖动和收起展开，记录 CPU、内存与卡顿指标；`testPageToggleMatchesNativeButton` 以同系统原生按钮的动作次数为参照，验证双击及再次点击的切页行为；`testSteadyStateResources` 分别停留在播放、暂停、收起和后台状态。需要 Instruments 时设置 `TEST_RUNNER_NEOMUSIC_TRACE_DELAY`，在日志出现 `PLAYER_PERFORMANCE_READY` 后附加当前测试 App 进程。对比使用相同设备、构建条件和操作脚本，记录工具类型及实际覆盖区间，原始结果保存在忽略的 `build/`。双击对照当前保留待修回归，状态见 [路线图](roadmap.md)。

不运行测试、只需要模拟器构建时：

```sh
xcodebuild -project NeoMusic.xcodeproj -scheme NeoMusic -configuration Release \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

边界检查覆盖全部 Swift 与 Objective-C 源文件，限制网易云网络和凭据代码归属 `Core/Netease`、WebKit 认证界面归属 `Features/Account`；App 只负责装配。通用播放器与本地资料库不得引用网易云类型或承担账户请求，网易云业务不得访问本地资料库和播放状态。既有播放器依赖继续按目录限制。

## 本机验证与 Release

项目验证统一在本机执行，入口为 `bash scripts/ci.sh`。

完整检查依次执行脚本回归、模块边界检查、XcodeGen 工程生成及 `NeoMusicTests` 的 Release 测试，开启 `ENABLE_TESTABILITY`。脚本回归覆盖边界规则、推送门禁、验证记录及 Release 草稿保护，使用临时仓库与隔离命令替身。测试本身完成编译，日志、`.xcresult` 和 `source-state.json` 保存在本机忽略目录。

完整检查使用 iOS 27.0 的标准 iPhone 模拟器。依赖外置音乐和基线应用的 UI 测试按专项范围另行运行。Metal 和系统 zoom 用例按实际环境报告通过、失败或跳过，真机与交互体验按对应阶段验收。

推送代码、脚本或工程变更时，仓库里的 `pre-push` 钩子运行 `scripts/ci.sh`。每个需要完整检查的待推 ref 都须指向当前 HEAD，附注标签先解析到提交。工作区须已保存全部已跟踪和未跟踪修改，忽略的构建产物可保留。一次推送多个代码 ref 时要求它们指向同一 HEAD，文档 ref 可指向其他提交。检查失败时先保存修改或切换到待推提交，再重新推送。

路径判断分别检查每个 ref，关闭重命名检测以保留源码删除路径。没有已知共同基线时检查目标提交的完整树，覆盖首次推送和合并提交。只含说明文档、`design/` 或许可证时跳过完整检查。开始检查前，钩子将已有结果包与来源记录分别保存为 `TestResults.previous.xcresult` 和 `source-state.previous.json`。

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

默认输出分别为 `build/ci/`、`build/release/` 和 `dist/`。可用 `NEOMUSIC_DERIVED_DATA` 指定已有构建目录。`build/ci/source-state.json` 记录提交 ID、开始和结束时的 dirty 标志、UTC 时间、退出码及通过／失败状态。手动检查可覆盖未提交工作，来源记录保留对应 dirty 状态。推送门禁要求干净 HEAD。直接再跑 `scripts/ci.sh` 时先移走旧的结果包及来源记录，保留它们的对应关系。

GitHub Actions 的 Release 工作流使用 `xcode-27` runner 与 Xcode 27.1。Release 的使用方式如下。

1. 修改 `project.yml` 中的 `MARKETING_VERSION`，更新 `CURRENT_PROJECT_VERSION`，运行 XcodeGen，并编写 `docs/releases/vX.Y.Z.md`。
2. 提交代码并完成本机完整检查。
3. 在 Actions 手动运行 Release 可先检查打包结果；它只上传 IPA 与 SHA-256 校验文件，不创建标签或发布版本。
4. 为确认好的提交创建并推送 `vX.Y.Z` 标签。标签须与工程版本一致，流程会生成未签名 IPA 和 Release 草稿。
5. 在 GitHub Releases 检查草稿、附件与更新说明，决定是否标为预发布，再点击发布。

标签工作流重跑时先查询 Release 草稿状态。已有草稿可重新上传附件并保持草稿，已发布版本拒绝更新。只有明确的 HTTP 404 才创建新草稿，查询失败立即停止。发布及 Latest 状态由用户在审阅后决定。

```sh
git tag vX.Y.Z
git push origin vX.Y.Z
```

公开构建包含正式账户入口，不带个人素材、已登录会话或签名凭据；IPA 需自行签名后安装。流程不提供 App Store / TestFlight 发布，源码及依赖版本与对应标签一起保留，第三方许可和来源清单随应用打包。

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

## 状态与追溯

当前能力、验收与已知缺口统一见 [路线图](roadmap.md)。历史验证数和采样记录按需查阅路线图中的证据入口；本指南只维护开发方法。
