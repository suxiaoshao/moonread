# 架构与数据约定

本文记录已采用的技术与共同契约。功能现状从[开发文档入口](../README.md)进入，未完成范围统一见[后续计划](../roadmap.md)。当前存储与统一文件夹书架设计见[数据专题](../data/README.md)，iCloud Documents/CloudKit 分工见[同步设计](../data/sync.md)，代码接入与云端验证边界见[接入实施](../data/sync.md)。

## 平台与职责

首个平台是 iOS，后续可能增加 Android。每条业务规则有一个明确归属方，按语义、数据权威与平台依赖选择 Rust 或 Swift，见下方规则归属表；Swift 同时负责 iOS 界面、原生排版和平台适配。当前通过 `MoonreadCoreBindings` 的 UniFFI 接口连接；#270 的 Swift GRDB 池是正文、索引、任务和用户阅读数据的本机权威。发布版 SwiftData 的阅读库只作为迁入源，禁止保存和旧 CloudKit 镜像。

| 部分 | 当前实现与职责 |
| --- | --- |
| Rust 文本核心 | `crates/moonread-core`：`encoding_rs` 解码、规范化、字素分块、SHA-256、章节扫描、`regex` 单书搜索 |
| Swift 索引与任务 | `DataSession` 的 GRDB 池保存正文、自动章节、来源索引与导入任务；Rust 接收有界值并计算，不打开正文索引库 |
| Swift 用户数据 | 当前账户 user.sqlite 保存事实、批注候选、小说信息、配色及正式位置，通过 CKSyncEngine 同步。设备偏好独立 |
| Swift 关系库迁入 | `MoonreadData/DataSession.swift` 管理按环境分开的 `Data/v3`，用一个 GRDB 池挂载正文索引及本机或账户用户库。完成迁入后才挂载正常 App 根界面。页面与备份使用同一权威。`MoonreadData/ReadingDataLayoutUpgrade.swift` 负责原子接管已发布的关系库和经核实的账户键换算 |
| Swift 平台适配 | `Data/AppDataService.swift`、`Library/Sources/LibraryService.swift`：目录授权、bookmark、扫描准入、目录变动通知、生命周期和异步工作调度；真实文件协调见 `MoonreadLibrary/LibraryFileOperations.swift` |
| 页面状态 | `Library/LibraryModel/LibraryModel.swift` 与领域扩展保存书架和文件任务；`App/AppShellModel.swift` 保存各标签导航栈、搜索和唯一设置会话（任务路径、配色草稿与预览）；`MoonreadReader/Session/ReaderSession/ReaderSession.swift` 与同类型领域扩展保存现有阅读会话状态与任务 |
| SwiftUI 页面 | `Library/Browsing/LibraryView.swift`、`MoonreadReader/UI/ReaderScreen/ReaderPage.swift`、`MoonreadReader/UI/Presentation/ReaderLibrarySheet.swift` / `ReaderSearchContent.swift` / `NoteEditor.swift`：书架、阅读、工具面板与编辑器呈现 |
| 原生正文 | `MoonreadReader/Rendering/ReadingView.swift` 适配原 UIKit 控制器，`ReadingPagination.swift` / `ReadingTextDecorations.swift` 使用 TextKit 1；`MoonreadReader/Rendering/Text/TextCoordinates.swift` 映射 UTF-8 / UTF-16，处理局部滚动、分页与选字 |
| Swift AI | Providers / Agent / Data / Tools / UI 分层；Swift AI SDK 承担协议与工具循环，本机 SwiftData 保存对话；读取工具经 AppDataService 读取不可变投影，书目匹配由 Swift LibraryQueryRules 统一 |
| 后续平台 | Android 可复用 Rust 正文与计算核心；不预先增加平台依赖 |

依赖及版本以[根 Cargo.toml](../../../Cargo.toml)、[核心 Cargo.toml](../../../crates/moonread-core/Cargo.toml)和[锁文件](../../../Cargo.lock)为准。当前单书正文搜索直接使用 Rust `regex`，不启动 `rg` 子进程，也未采用 `grep-searcher`。具体搜索语法和限额见[阅读工具](../reader/tools.md#搜索先找到上下文再决定跳转)。

TextKit 1 的显式字形范围和文本容器用于两种阅读模式。Swift 只持有邻近正文，不一次布局整本；是否迁移 TextKit 2 取决于实际排版、选区和性能需要。Rust 不承担 iOS 字体度量。用户阅读数据由 Swift 的 GRDB 用户库持久化；AI 会话使用独立的本机 SwiftData。

## 规则归属表

每条独立规则只在一处实现；调用层只测边界及自身状态。表中“后续”项登记待收敛的现存副本，不将它们写成已经单源。Rust 路径前缀为 `crates/moonread-core/src/`，Swift 主 App 前缀为 `ios/Moonread/`。

| 独立规则 | 唯一归属方 / 文件 | 理由与其他层边界 | 现状 / 边界 |
| --- | --- | --- | --- |
| 封面显示优先级、预设分配与排版 | Swift 共享 `SystemIntegrationShared/SystemReadingCard.swift` 的 `SystemBookCover`；`SystemPresetBookCover.swift` 负责预设绘制 | `SystemBookCover` 唯一决定用户图片优先、否则预设／无 SHA 文字兜底；App 的 `BookCoverView` 只订阅既有 `CoverImageLoader`，小组件只读取共享缩略图，Spotlight 用同一视图生成缩略图，阅读扉页也复用；统计查询从现有资料投影带回作者及封面。固定六款按完整 content_sha256 取余6；主 App/小组件共享竖排、横排、作者、固定字色、书脊与有界缩略缓存；宋体仅用已安装字款，缓存包含实际字款；无身份文字封面使用固定暖灰纸/墨色；不重算身份、不写用户封面事实。扩展对传入 SHA 拼写作防御性校验，主 App 沿用 Rust 身份校验 | 显示规则及读取接线共用；不新增用户数据格式 |
| 小说信息交换格式、归档与诊断 | Rust `metadata/`，共用 `storage/maintenance/archive_limits.rs` | JSON/JSONL/ZIP、版本/必需能力、流式解析与诊断、路径与资源预算；每次下传一个规范记录或诊断 | 新增单源 |
| 小说信息包文件与预检索引 | Swift `MetadataImportDocument` / GRDB | Swift 提供有界文件读写，管理归档成员、封面、诊断输出与一次性 inspection.sqlite；同一事务暂存规范记录，按 SHA 和行 ID 分页，释放时删除暂存。 | 只处理本机可丢弃暂存 |
| 小说信息编辑与交换 | Swift `Books/BookMetadata.swift`、`MetadataExchangeRows`、`UserValueRows.putMetadata` | 预览和资料导出在同一 GRDB 快照匹配索引、全库副本与 current 引用；保留正式库逐 SHA 兼容屏障及 pending 整对象。单书和资料包共用事务 writer，批量预取选中键的全部设备时钟与兼容状态。封面在事务外准备，候选、附件与 current 一次提交。资料包后台任务在批闸门内复核原配置、用户库归属与确认后的逐书删除状态；唯一来源改名仍独立，并核对正文身份 | 资料交换已切关系库；页面详情及其他消费者另批接入 |
| 配色草稿字段与保存准入 | Rust `user/themes/palettes.rs` 的 `validate_theme_palette_draft` / `make_theme_palette` 共用名称 trim、Unicode scalar 长度与 RGB 校验；Swift `UserThemes.paletteSaveIssue` | UI 只消费字段原因并定位名称，保存仍由服务按当前事实检查 64 个上限与编辑目标；已存配色解码不重新规范化 | 单源字段规则／服务事实 |
| 配色专属纹理支持、descriptor/混合参数、独立开关及发布迁移 | Rust `user/themes/textures.rs`（descriptor），`preferences.rs`（偏好与迁移），`resolve.rs`（校验/解析） | 分层资源、锚点/尺度限制与混合参数单源；按最终有效内置配色 ID 解析；运行时区分不支持、关闭、启用，关闭仍保留图案说明；本机 version 1 map；旧 1.3 两槽播种同明暗全部支持项，缺 key 新默认开；App/官网共用 descriptor，不再维护通用纹理/强度/Lr/tile 运行契约 | 单源 |
| 导入字体资源身份、引用与清单格式/校验 | Rust `user/reader_fonts.rs` 与 `reading/layout.rs` | 复用 Swift `SourceIdentityProbe.rawSha256` 与 Rust raw hash 步进 标识原字节；Swift `ReaderFontLibrary` 负责协调复制与 Core Text 注册，`ReaderBuiltinFonts` 管已知 Apple 宋体/圆体的按需下载与可用性，已安装字款与中文字形验证共用 Swift 共享 `SystemInstalledFont`；封面只读可用性，不调用下载，Rust 将已存偏好解析为内置字款或导入引用与兜底字款；`ReadingTypography` 唯一处理平台可用性及正文/预览回退；资源/face 可用性改变使排版缓存失效 | 单源与平台接线 |
| 字号、行距、段间距的默认值、范围与控件步长 | Rust `reading/layout.rs` | `reader_typography_controls` 同时供设置校验、Swift Stepper 和官网导出器使用；原生/浏览器字体度量各自归平台 | 单源 |
| 阅读设置当前值、连续修改与串行保存 | Swift `MoonreadReader/Preferences/ReaderSettingsStore.swift`，App 级可观察环境对象 | `ReaderSession` 和设置页共用同一实例，不持有可写副本或各自排队；`AppDataService` 仍负责既有 UserDefaults 编解码和持久化，Rust 校验范围不变 | 单一 owner |
| 纹理偏好本机保存/回滚 | Swift `UserThemes` / `ThemeStore` | 原 UserDefaults key，缺 key 与已有坏数据分开；不可读不能被默认覆盖；不改 Palette、CloudKit 或备份 | 平台边界 |
| 正文几何、叶页分组、活动叶及原文选区恢复 | Swift `MoonreadReader/Rendering/ReadingController` / `PageController` / `ReadingViewport` | 原生字体度量与硬件保留区归平台；一个 pager、一份统计输入，源范围用 Rust UTF-8 坐标。`ReadingContainerRegions` 单源拆分保留区；`ReadingTypography.prepare` 单源装配 `PreparedReadingText`（映射、富文本与当次版本），分页/滚动/预览只消费及派生配套结果，不新增缓存；TextCoordinates 和 Rust 语义不变。正文占满本阅读窗口，sheet/键盘/工具路径不参与几何，不为工具让位；真实窗口或排版改变才按锚点排版。宽>高且每叶满足最小行宽自动双页，保留无效 canvas 与转场检查；几何变化不写阅读事实。正文滚动文本已有固定头部，创建时关闭系统额外顶部滚动边缘模糊，避免交互返回取消残层遮挡首行 | 平台排版 |
| 阅读呈现意图与原生占用 | Swift `MoonreadReader/UI/ReaderScreen/ReaderPage.swift` 保存阅读状态、生命周期与原生呈现，`ReaderScreen+Content.swift` / `+Controls.swift` 只组合原内容；`ReaderPresentationState` / `ReaderPresentationProjection` / `ReaderPresentationHost`；`ReaderToolSession` 保留编辑对象引用，批注权威仍为 `ReaderSession` | selection、有类型 path、exposure 与栏显隐单源；所有尺寸用同一手机工具 sheet/原生任务导航，无 inspector、容量投影或手画页头。完整设置/详情直接绑定同一逻辑路径并在来源栈 push，原生 sheet 释放后交接；系统返回直接生效，不等待原生完成或校验工具代次。工具 sheet 的 opening/token/代次仍隔离旧回调，退出内容仅保留渲染引用。阅读模块在原生返回手势资格通过后临时显示自身导航栏与状态栏并完成公开布局，转场期间由离场阅读页持续声明导航栏；完成或取消时清除临时状态，取消保留原工具状态；源页不设置恢复条件。系统子模态保留父链，窗口变化不改路径/草稿或写偏好 | 单一 owner |
| 系统通知进入界面隔离域 | Swift `Shared/Concurrency/MainActorNotifications.swift` | 非隔离 Sendable 接收入口先安全接住通知，带载荷时在原队列提取 Sendable 值（如 keys/reset）后再调用 MainActor 客户端（后台异步切主、已在主线程即时交付；Combine 则先 receive(on:)）；不可依赖继承 MainActor 的回调体内再检查线程。已有显式主队列 onReceive 与 actor 内 AsyncSequence 维持原交付；锁保护的同步缓存不迁到主线程 | 平台线程边界 |
| App 标签、导航栈、搜索与设置会话 | Swift `AppShellModel` | 根视图绑定外壳状态，书架和系统入口通过同一模型提交导航 | 单源 |
| 书架状态、来源导航与文件任务协调 | Swift `Library/LibraryModel/LibraryModel.swift` 及 `+Navigation.swift` / `+Discovery.swift` / `+Reload.swift` / `+Imports.swift` / `+FileWork.swift` | 同一 MainActor model、同一存储和 generation；书架点击直接提交阅读目标，同一位置的快速连点不叠加阅读页；FileWork 统一拥有执行、等决定、等开书与结束四个阶段，任务与文件选择器各自保持原资源寿命 | 单一 owner |
| 单书会话、窗口与位置/lease 生命周期 | Swift `MoonreadReader/Session/ReaderSession/ReaderSession.swift` 及 `+Loading.swift` / `+Position.swift` / `+Preparation.swift` / `+Browsing.swift` / `+Continuation.swift` / `+Annotations.swift` | 导航后由会话拥有文件准备、进度、失败、重试及取消；AppDataService 协调并校验来源、交付 lease，旧请求不得接收迟到进度或 lease。开书请求、lease、窗口、离页进度由会话阶段配对；扉页与正文 0 分离；正文 frame 与来源、版本、范围及可用边缘配对。听书的播放与跟随独立，采用新位置仍走同一写入交还入口 | 单一 owner |
| AI 单会话执行、审批/取消与顺序持久化 | 本地 Swift 包 `MoonreadAI/Agent/AIAgentRuntime/AIAgentRuntime.swift` 及 `+Run.swift` / `+Persistence.swift` / `+Tools.swift` / `+Context.swift` | 同一 MainActor runtime 以事件游标、当前输出及独立发布阶段归并原 task、generation、审批与 persistenceTail；共享等待、推理和停止仍可与持久化交错，durable head 编码与提交顺序不变 | 单一执行 owner |
| AI 启动准入与封面网页解析 | `AIHost`、`MoonreadAI.AIAvailability`、Rust `moonread-ai-cover` | 只在首次使用相应 AI 入口后建立服务与会话仓储，店面与开关策略保持轻量。封面抓取在包内授权，HTML 解析通过宿主注入封面 crate 的纯函数；正文 core 不含解析依赖 | 单一 owner 与平台适配 |
| 系统开书与未保存修改确认 | Swift `SystemReadingRouter`；dirty 权威为 `PaletteDraft` / `ChapterEditDraft` / `NoteEditorModel` | 普通面板不排队；比较草稿基线，保存中的请求即时提示并消费，不取消写入或排队；同一请求在解析、等确认及打开间转换；解析错误不离书，取消消费请求，晚到确认按请求 token 隔离 | 平台入口与草稿 owner |
| 固定阅读背景合成与原生/预览绘制 | Swift `ThemeSurface` / `ReadingPaperView` / `ReadingPreviewBackdrop` | 彩色 RGBA、固定 sRGB；图块/paper/blend/opacity 准备一次，原生与预览共用 ReadingPaperView/PreparedReadingPaper；尺寸只更新 descriptor 所定的贴边/靠角/cover CGRect；内层分页/滚动透明，不动正文布局或坐标 | 平台绘制 |
| 解码、normalization-v1、正文/原字节 SHA 计算 | Rust `reading/input/text.rs`、`identity/source.rs` 及正文导入共用核心 | 和正文缓存/稳定内容身份一致；Swift 不重算规范正文 | 保持 |
| fileId/bookId/canonical→正式或 pending 阅读键、索引有效性 | Swift `Data/Database/ReaderIndex.swift`、`IndexSources.swift`；Rust `identity/content.rs` 只校验 wire 键 | 当前作用域的导入别名、正文缓存及匹配文件版本的索引身份由同一 writer 维护；页面范围与完整副本裁决留 2c | 2b 写入与任务取数 |
| 待索引集合与书架索引 inventory | Swift `Data/Database/IndexSources.swift` | 同一库快照返回总量/pending；有效关系只认路径索引行当前编码、大小与修改时间 | 单一索引池 |
| 书架同步描述、本机授权绑定和扫描后准入 | Swift `ShelfRecovery.swift`、`UserSyncJSON.swift`、`FullIndex.swift` | 用户库裁决同步描述，local_shelf_recovery 按账户保存本机绑定；平台扫描成功范围限制自动任务，不复制 Rust 查询 | 平台边界 |
| SHA 格式 | Rust `identity/content.rs::parse_sha256` | 身份及资产校验共享严格语法，语义字段仍区分 | 单源 |
| 最近阅读与首页继续阅读 | Swift `RecentReadingRead` 固定查询 / `RecentReadingStore`；Apollo 只生成结果类型 | 同一 main＋usr 快照先读 current、已验证别名和本机偏好并定副本，再读入选书的卡片与章名；首页与完整列表共享观察，页面持有期间保留上一结果，最后一个释放时停读；首页按钮直接打开卡片显示的来源 | 移除最近阅读旧投影入口；单书正文与章节路径另行切换 |
| 页面查询输入与失效 | `MoonreadData` 的固定读、`ReaderIndex` 和 `DataSession` 同池观察；`MoonreadQueries` 提供 Apollo 生成类型 | 读入口明确声明所需列和书键。领域写者在同一事务结算 current；页面按账户和参数持有观察、拒绝迟到的结果，不再拼接 SwiftData 投影或用 TEMP 做候选裁决 | 旧 SwiftData 仅由只读迁入打开 |
| 明确书目标后的正文首帧、当前位置标题与章结构 | `MoonreadData` 的 `ReaderOpeningQuery.swift`、`ReaderWindowRead.swift` 与 `ReaderChapterQuery.swift`；Rust `reading/window_payload.rs` 和 `reading/layout.rs` 做显示计算 | 同一索引/用户快照内按已确定书 ID、当前位置引用、已发布正文与章修正读取；标题、目录与最近卡片共用章修正组合。Swift 只取有界正文和已证实空白，Rust 切片、标记段落，不开库。结构与覆盖分开；覆盖在第 5 步另接 | 阅读会话持有窗口，工具页持有目录结果 |
| 最近打开与后台恢复 | Swift `ReaderSession.bodyDidDisplay`、`ReadingPositionRows`、`RecentReadingRestoration` | 正文真正显示后记录 opened，和位置独立；最近排序与副本归 `RecentReadingRead`。后台只按同一用户库里已提交的正式位置取恢复限额，隐藏在排名前排除，文件准备后复核旧票据；恢复不写 opened/位置或计时 | 同一用户数据权威 |
| 封面资源与静默替换 | Swift `Books/BookMetadata.swift` 的 `CoverResourceLoader`、`CoverImageLoader`、`BookCoverDisplay` | 独立资源 actor 统一 UI/Widget/Spotlight I/O 与派生；按作用域/资源/尺寸合并并有界缓存，ready 不随订阅销毁。同书旧图等新图成功，删除/换书/换账号立即清；系统文字更新复用图像输入版本 | 单一资源 owner |
| 默认阅读中状态 | Swift `Data/Queries` 书架固定查询 | 保留按正式 SHA 的位置事实（含无本机正文的已索引书）及显式状态优先规则 | 旧 Rust 查询已移除 |
| 文件夹列表、计数与封面候选 | `MoonreadData/FolderQuery.swift` / `MoonreadLibrary/FolderStore.swift`；Rust `library/order.rs` 保留原自然行序 | 直系成员和子树在单个读快照中计算；活动和最多四张预览按有效位置时间，不读 opened 时间。经已核实别名合并位置，直接书卡定点补位置/章/作者/封面，只补入选预览的作者/封面。移动选择器按原顺序单次读取文件夹，不补书卡或封面 | 页面各自观察；单次查询不建观察 |
| 书目、名称与标签分组 | `MoonreadData/CatalogueQuery.swift` / `MoonreadLibrary/CatalogueStore.swift`；Rust `library/order.rs` / `catalogue_cards.rs` | 与目录共用已核实身份、位置和窄卡读取；名称模式不读标签，标签模式同快照定点取可见成员。自然顺序和特殊分组沿发布规则，标签通过文件 ID 引用单份卡片，实体副本不合并。换分组保留已显示结果直到新值到达 | 本页观察；目录、名称和标签共用卡片规则 |
| 单书详情、来源与阅读状态 | `MoonreadData/BookInformationQuery.swift` / `MoonreadLibrary/BookInformationModel.swift`，来源行序沿用 Rust `library/order.rs` | 从明确书键读取已结算资料、有效位置与正文/章概况；未读副本按修改时间，已读副本按自然名称、路径、ID，显式文件优先。正式资料隔离禁用编辑并随观察重验；详情不读事实或覆盖，统计仍独立取数 | 页面各自观察；准备编辑和单次消费者复用固定读；`MoonreadLibrary/BookMetadataDraft.swift` 持有编辑草稿，`MoonreadData/BookMetadataEditPlan.swift` 计算写入字段，原 `UserValueRows` 所在事务继续结算 |
| 搜索与筛选按用途取数 | Swift `LibrarySearchQuery.swift` / `FolderQuery.swift` / `LibraryQueryRules.swift`；Apollo 生成固定结果类型 | 筛选取当前作者及标签，选项查询按正文身份一次汇总标签用量；普通搜索按条件选列，匹配在事务外执行，再核对输入并只给命中项补卡。AI 资料搜索保留简介与正式资料兼容屏障。AI 按条件查找沿用普通筛选求值和排序，加同一 AI 读取屏障，复核快照后只给当页的条目补状态与作者。两者沿用写入时结算的 pending 整对象覆盖 | 搜索与选择页按需观察 |
| 标签选择页的浏览分组与顺序 | Swift `Library/Search/BookTagCategories.swift` | 原词查随包词表，按标签使用本数和拼音分组排序。计数复用选项查询，两种入口共享展示规则，查询与存储仍使用原词 | 仅展示，不写用户数据 |
| AI 工具输入/schema/输出契约与执行 | Swift `AI/Tools/Reading/AIReadingToolContracts.swift` / `AIReadingTools.swift` | 只拆契约、执行和 `AppDataService+AIReading.swift` 平台适配的物理文件；引用、SHA、范围与搜索仍调用既有 owner | 单一执行 actor |
| AI 对话筛选建议 | 包内 `AIBookFilterContracts` 与宿主 `AIReadingTools`、`AICommittedResultDecoder` | 候选与手动筛选同源；宿主复用 `BookSearchConfiguration` 校验与查询。建议随成功工具结果保存，用户点击才打开独立搜索。书架 ID 与歧义选择留在本机 | 搜索、排序与虚拟书架由原领域持有 |
| AI 对话固定书单 | 包内 `AIBookFilterContracts`、宿主 `AIReadingReferences`、`AICommittedResultDecoder` | 现有文件与正式正文身份同批解析，只补选中书目；本地封面缩略图、精简状态和引用随工具会话提交，模型仍只接收宿主核实的引用与书目名称。用相同解析检查当前是否可打开，保留历史快照 | 不写书库、不下载正文、共享详情路由与书目行 |
| AI b: 引用协议 | Swift `AI/Tools/Reading/AIReadingReferences.swift` | 工具协议只在 Swift；调用 Rust SHA 校验。外部字符串解码为书或文件引用，准备权限独立；共享准备由 AppDataService 持有，最后一个等待者释放工作 | 共享引用解析 |
| v2 导入、搜索、重建及计时纯计算 | Rust `reading/compute.rs`、`reading/input/text.rs`、`library/tools/search_compute.rs`、`user/statistics/mod.rs` | 每步消费前态。导入共享发布规范化与原文／正文 SHA；搜索按显式范围每步最多 50 条；章节复用发布扫描器。计时新接口拒绝单步超过一天；生产采集调用连续段接口，旧切片入口仅供历史数据和 DEBUG 夹具 | 正文三项已由 Swift 用显式票据调用 |
| v2 文件归属、连接池与本机归户 | `MoonreadData/DataOwnerState.swift` 决定账户目标；Swift `MoonreadData/DataSession.swift`、`LocalScopeImport.swift` 持有实际挂载与迁入 | 唯一会话 owner 决定 `index.sqlite` 和所挂 `usr`；失去账户确认时仍可本机读写、不同步；明确登出使用 local。首次确认启用时冻结后合并目标证据，由目标同事务结算非事实当前值并写完成标记，成功后独立清理源；旧会话代次不得访问另一账户 | 归户后由当前用户库接入同步 |
| 本机书籍与任务记录迁入 | Swift `LegacyIndexImport`、`LegacyUserImport` 和启动准备 | 1.6 的导入来源、明确草稿指针、示例标记及设备作者随索引提交。续读、隐藏、首选文件与书架恢复只迁可确定的用户域。坏记录逐条丢弃，提交后清理发布版旧键 | 单一迁入入口 |
| 本机任务持久化 | Swift `ReaderIndex` 与 `DataSession` 的索引库写入边界 | 导入、全库索引、文件交接、系统提交和小说信息任务不参加阅读数据同步。产品读取只使用最终表 | 单一存储 |
| v2 pending 晋升与索引别名 | Swift `Data/Database/PendingUserPromotion.swift`，位置、打开和批注沿用各领域结算 | 同一 writer 核对当前作用域的已完成导入及可读 SHA。只写 `usr`，候选晋升、重结当前位置/打开和批注 heads、pending 源删除同事务。合并提交后才能独立回收；重启重验仍有完成任务的索引 | 启动恢复与导入收尾共用晋升路径 |
| v2 本机整书删除 | Swift `PendingUserPromotion.swift`、`ReadingDataManagement.swift`、`CacheManagement.swift` | 正式 SHA 与已核实别名只写 `usr` 一次；单删 pending 不扩为整书。身份未确认的其他导入继续运行；其后产生的阅读数据按正常别名晋升。保留全局清除、不明归属记录与源文件；封面只回收可证明无剩余引用的目标资产。提交后独立回收安全别名、按选中的正式 SHA 尝试清理设备正文；保留活跃和任务保护，缓存未清不回滚用户删除。云端删除及出站裁决另接 | 晋升与打开/位置接入；其他 writer 随切换接入 |
| v2 打开、位置与本机续读基线 | Swift `ReadingPositionRows.swift`、`LocalReadingRows.swift`、`UserDataService.swift` | 阅读会话保留当前用户库令牌；写入闸门复核账户归属，writer 在同事务按索引解析当前书键。打开与位置是独立事实；位置沿用 UTF-8 边界，位置与本机基线同事务。隐藏和首选副本随相关动作更新；位置写者同事务维护跨分区位置和正式分区自己的胜出引用；续读定点取本机基线与正式引用，pending 更新或隔离不改变正式引用 | 位置/打开写入、阅读窗口与续读导航均使用新表 |
| v2 批注与书签因果写入 | Swift `AnnotationRows.swift`、`UserDataValues.swift::AnnotationReduction` | 正文选字新建独立批注；高亮详情按单条 ID 编辑或撤销移除。范围编辑入口的编辑包仍按重叠范围与合并关联扩展。普通写入只取代原基线，显式解冲突或批量选中删除重验候选 ID。候选、祖先、关联及旧内容压缩同事务，读取不改库。撤销基于自己的删除候选；未知候选按已知书/标记范围隔离；书签按书/偏移确定键。编辑、选择和撤销保留原用户库归属，进入写者时复核 | 本机与入站写入都重算有效候选 |
| v2 发布库结构迁入 | Swift `LegacyIndexImport`、`LegacyUserImport`；Rust `user/reading_fact.rs` 提供已解析事实列 | 用唯一 Swift pool 读旧索引 v20–23，校验后把完成标记写入副本；不读取私有 SwiftData SQLite schema。旧用户模型导入两个分区后结算非事实当前值，与证据及完成标记同事务 | 事实和书日量一起结算；迁入失败保留旧库、阻止挂载正常 App，重试走原事务 |
| 阅读事实 wire 与查询计算 | Rust `user/reading_fact.rs`（serde）、`user/statistics/`；Swift `UserSyncJSON.bindFact`、`ReadingFactSettlement`、`ReadingHistoryTransport` | 旧库、备份和独立新区 `ReadingFact` 类型共用 Rust 解析及编码；按已存语义身份保留曝光与清除关系，物理删除重结原有 current/day。限制发送为正式可读原始证据，清除掉的贡献不等于物理删除。未知或冲突隔离，不合成为新段 | 传输回执与新区初始化分别见下方规则 |
| v2 阅读事实写入与统计清除入口 | Swift `ReadingSegmentRows.swift`、`ReadingClearRows.swift`、`Statistics/ReadingStatistics.swift` | 采集入口保留开页用户库归属和统计开关代次，进 writer 之前重验；书键在 writer 内解析。旧 fact 清除按范围时间或明确 ID，captured 只用明确成员；新段清除保留独立的已发生前缀证据。两者使用各自身份，不把旧事实合成新段 | 等待已接手的采集写入后，最后快照、clear 和日量同事务；成功才切采集代次 |
| v2 业务当前状态 | Swift `ReadingPositionRows.settleCurrent`、`CurrentUserRows`、`AnnotationRows.settleHeads` | 在证据的同一事务结算受影响的键；领域各自决定隔离范围和来源。位置保持跨分区未知阻断，打开只略过不可读分区；章节按分区裁决后由有效 pending 覆盖；解码、配色和书架引用只读 formal，坏引用不阻断正常提示。资料与标签采用同一胜出对象来源，批注复用因果 reduction 并保留并发及删除 head。整书删除同步清本书当前引用；候选引用在提交时检查 | 供固定查询与观察读取 |
| 连续段采集与载荷 | Rust `user/statistics/segments.rs`，两套采集共用 `ReadingTiming` 计费 | Swift 提供时间、ID 种子及采集作者，Rust 消耗前态，独立返回本步计费和累计快照；15 秒检查点不换 ID，真正边界才封段。Rust 校验载荷版本、精确裁剪并按上次快照补封。Swift 只让本机 owner 续写；备份 active 只作静态快照，按同作者的更新版本替换，不取得补封资格 | 生产采集走快照 writer；本机补封只看当前合法库中实际拥有的遗留行；出站只登记封段/正式记录 |
| v2 同步传输持久化 | Swift `CloudTransportRows`、`CloudCallbackJournal`、`DataSession` | 业务写入在同一账户库事务登记待发；记录名、意图、内容摘要及不可重用代次匹配回执。系统字段不是业务时钟。用户库就绪且账户允许同步后，单个引擎才能取得独立回调权限；同账户暂停不关闭普通读写，撤销的回调权限不会因重新启用而复活。领域入站失败后该引擎会话不得继续保存检查点 | App 和独立测试适配器使用同一入口，各自固定容器 |
| v2 App 同步启停与换户顺序 | Swift `CloudSyncCoordinator`、`ReadingSyncEngineAdapter`、`AppDataService` | 换户先撤旧引擎回调的写权限并取消旧轮次，独立收尾网络；草稿走页面原有离开流程。App 收尾旧阅读与导入、撤系统快照，在原 DataSession 换绑并重接观察。明确归户在开始写入时核对批准的当前账户；普通后台暂停不撤已确认快照。iCloud Drive 发现独立 | App 从签名对应的构建环境核对月读容器身份，获准后开实际引擎；Development 与 Production 不共享新库或账户确认 |
| v2 云区清除与意外失区 | Swift `ReadingSyncEngineAdapter`、`CloudSyncCoordinator`、`AppDataService`、`CloudAccountZoneRecovery`；领域结算沿原 owner | 同账户只记录自己的区事件，冻结检查点。旧引擎退出且账户复核后，主动清除/加密重置只清该账户正式同步证据，不重传；明确删区事件加精确缺失才允许重建；固定初始化记录与全新升级端条件竞争，胜者从本机权威按首批回执重排，跟随端等待完整新区基线。已出现不同控制的替换区可跟随；旧控制或单记录失败不作失区证明 | 已接 App 恢复、控制竞争及证据重排；签名 SyncProbe 已复验三种升级路径，真实月读容器待试用 |
| v2 整书删除 | Swift `ReaderIndex.deleteUserBooks`、各领域结算 | 核对正式 SHA、已证实别名和活跃阅读，在一个 usr 事务内删除和重结当前值并登记新区删除；设备正文缓存独立清理 | 不读写旧云区或旧本机库 |
| 已发布用户库存储迁入与升级说明 | Swift `LegacyUserSnapshot`、`LegacyUserImport`、`DataSession`；说明由 `MoonreadApp` 持有 | 本机 SwiftData 按已确认归属只读打开正式与 pending，禁用 CloudKit；一次迁入证据与用户数据同事务落库。升级说明由设备记一次，独立于迁入、G3 重试与 iCloud 开关 | 云区初始化另见下方规则 |
| 一次迁入的已提交内容来源 | Swift `UpgradeOrigins`，由旧源和各业务 writer 在现有事务内登记 | 摘要包含原始版本及所属关系，封面按候选引用而非附件到达决定来源。压缩保留 seed 依赖、批注关联组；隔离条目使用内容身份。D1 保留正式数据来源，已证实的 pending 晋升按普通本机新写同步；整书删除有一次性本机范围 | 新区初始化与跟随端基线折叠见下方规则 |
| 新区一次初始化的首台资格和完成门槛 | Swift `ReadingCloudInitialization`、`CloudCallbackJournal`、`ReadingSyncEngineAdapter` | 定点缺失且新区为空才提案条件创建；经同一安装和初始化 ID 核实才选首台。完成前直接核对当前正式集合与精确回执，关闭边界后按原 change tag 条件写 ready。真正缺封面以原键表示；隔离原文只留本机 | 后升级端见 ready 只进入完整基线阶段，控制记录不参加业务归属 |
| 后升级端基线暂存与正式来源折叠 | Swift `CloudBootstrapRows`、`CloudBootstrapFold`、`CloudCallbackJournal`、`ReadingSyncEngineAdapter` | 只使用同一账户、同一 ready 控制及覆盖全区的一次暂存。唯一 writer 比对当前提交内容来源与批注因果，把云候选、准入本机写入、领域结算与普通游标一起提交；中断保留原本机内容并丢弃暂存，普通网络从成功提交的游标继续。W2 跟随以替换区为准，不为旧区差异保留本机专用档案 | 未确认 SHA 的 pending 留在本机，不阻塞正式折叠；验证正文后由原晋升 writer 登记普通待发 |
| v2 固定 ID 候选与删除回送 | Swift `UserValueRows`、`ReadingPositionRows`（opened）、`FixedValueCloudRows`、`CloudCallbackJournal` | 领域持有校验和 current，传输按类型、设备候选和实际内容准备意图。X2 判断与删除共用 writer；明确新建的新 SAVE 等自身 DELETE ACK 后即可发送。已知旧候选仍按 W2-a 删除，歧义只暂停该 ID。封面送出前校验引用和字节；配色子表随候选，物理封面回收先核引用 | 逐记录查证与资产收发由同步适配器负责 |
| v2 同步引擎、逐记录查证与入站 | Swift `ReadingSyncEngineAdapter`、`CloudInboxRows`；领域仍归原 writer | 回调串行记录证据，网络调度在回调外；只接受本区完整 ID，普通状态在既有 checkpoint writer 落盘。固定值与因果候选需查证时在每轮限量按 ID 请求，回来同事务复核候选和 Attempt。CKAsset 先脱离 SDK 临时文件，再交数据库；未知记录局部隔离 | App 与测试工厂容器分开；App 入站提交后通知读取层，测试工厂不发 App 通知 |
| v2 token 位置与因果批注同步 | Swift `ReadingPositionRows`、`AnnotationRows`、`CausalCloudRows`、`CloudTransportRows` | 不按每设备固定字段重建身份。新位置或批注候选与其待发同事务，压缩删除绑定精确的前序 SAVE ACK，连续替换只改绑尚未授权的链；对端移除未确认新候选撤销相应压缩意图。同一 writer 从已提交的位置/token 和批注原候选重结，正常入站不改本机基线或回声上传 | 真实云端验证见同步设计 |
| v2 有效阅读事实与书日量 | Swift `ReadingHistoryRows`、`ReadingFactSettlement`、`ReadingSegmentRows`、`ReadingDayRows`；Rust 计算事实时长和段有效头 | 候选归属、隔离和来源清除在确定当前贡献前判断；历史 fact 和新段分别引用对应证据。书日量只用一套有检查的 UInt64 差额；极值只回查相应桶内两类窄头，封段状态变化不重复计时；覆盖按需计算 | 每批每个 typed ID 只结算提交前后；统计固定读见下表 |
| 相对路径语法、组件边界匹配、名称合法性 | Rust `storage/validation.rs`，bookshelf 委托 | 索引和真实操作都需要相同底线；具名 profile 保留入口差异 | 共享路径校验 |
| 表单 TXT 后缀补全、AI stem trim/保留扩展名 | Swift `LibraryActions.swift`、`AI/Data/Proposals/AIProposals.swift`，分别为两条不同规则 | 各自单源、不同输入契约，不为统一语言迁移 | 原位保留，只调用合法性 owner |
| source hint 字节/字段限制；恢复候选优先级与下载限额 | Swift `Data/UserData/UserDataValues.swift::PositionSourceHint`、`RecentReadingRestoration.swift::RecentRestorationPolicy` | 同步载荷与恢复行为专用且已经单源；共享路径语法调用 Rust | 共享路径语法 |
| symlink/授权/provider 生命周期、真实文件 IO | `MoonreadLibrary` 的 `LibraryFileOperations.swift` 与 `ProtectedFileAccess.swift` 管理路径、协调与选件作用域；主 App 的 `LibraryService.swift` 解析书架授权并编排索引提交，ShareReceiveShared 管理分享扩展授权 | 平台安全事实，Rust 字符串校验不能替代 | 保持 |
| 分享扩展入站安全校验 | Swift `ios/ShareReceiveShared/ShareInbox.swift` | 独立进程不依赖 Rust，属于明确防御性例外 | 保留，共同 fixture 对齐公共规则 |
| 系统元数据匹配 | Swift 共享 `LibraryQueryRules.systemMetadataBooks` | 共享书名、作者、标签、书名/作者的有效分词与拼音全拼/首字母；去空白、去重、最多64项，不生成前缀碎片或单字分词。Entity 用该词表做部分/拼音匹配，Spotlight 匹配与展示由系统负责；复用 Rust ordinal，不带 AI 简介 profile | 具名契约 |
| 系统书目、Widget 与系统开书 | Swift `SystemReadingRead`、`SystemReadingCatalog`、`SystemReadingRouter` | 同一池按输出观察提交，书目与统计分别发布；唯一本机发布者在代次/作用域核验后原子替换。目录查已验证身份、当前卡片与共用最近排名；明确开书只查目标 SHA 的候选来源，最新位置走正常开书，不等目录、Widget 或系统平台回调。扩展只消费相应派生文件 | 书目 Rust 自然序；统计 Swift 日量；平台发布不回写权威数据 |
| AI 目录来源、字段与连接预算 | Swift `AIModelDirectoryPolicy` / `AIModelDirectoryDecoder` / `AIModelCatalog.option/resolve`，`AIConnectionService` 编排刷新 | A/S 完整结果决定自动发现集合，首次失败空列表；P 仅精确补已有型号规格，只有 metadata-only 预设用 P 生成列表，显式 false 不覆盖成 true；M 保留预算并与连接明确上限取小值；ChatGPT 独立。目录缓存不进 CloudKit；无来源的旧目录与已取回快照分开，授权与目录失败独立，Keychain 编码保持旧字段；用途与端点适配仍由 `AINativeCapabilities` 单源判断，见[模型目录](../ai/model-catalog.md) | 单源解析与裁决 |
| AI 连接余额与额度 | Swift `AIConnectionUsageService` / `AIUsageAdapter` | 查询能力、官方端点及字段语义由 adapter 单源决定；usage service 独占详情访问、刷新、快照、冷却和迟到响应校验。凭据、代际及网络准入继续由 `AIConnectionService` / `AIAvailability` 管理；列表不触发查询，快照只在内存。见[连接余额与额度](../ai/providers.md#连接余额与额度) | 单一查询 owner |
| 查询范围、身份/metadata 关联、目录后代最近时间、最近副本选择 | 2c Swift 固定查询 | 数据库事实需要完整范围；不能从限量 recents 反推目录，不复建旧 TEMP 或通用查询门面 | 旧 Rust 查询已移除 |
| 书目文本/作者/标签/状态筛选、搜索排名和建议匹配 | Swift `LibraryQueryRules`（`Library/Search/LibraryQueryRules.swift` 与共享系统元数据 profile） | 条件树区分组与对应类型的谓词，搜索、编辑草稿与虚拟书架共用此结构；三值求值、无标签、自定义多键排序与摘要使用同一查询；书架书名/作者的全拼与首字母复用共享 `pinyinSpellings`，与 Entity/Spotlight 使用同一系统默认普通话转写，不加词典或 Rust 副本；普通搜索随结果带回命中来源和首个真实字面范围，列表与网格共用并沿用旧搜索快照；作者入口取同批作者命中按 UTF-8 去重，作品用全库精确作者条件；AI/建议匹配模式独立，64 项上限仅属于系统词表 | 单源匹配与排序 |
| 虚拟书架的保存和删改 | Swift `SavedFilters` / user.sqlite `local_saved_filter` | 仅当前在本机打开的账户用户库。保留结构化条件与排序，复用 `LibraryQueryRules` 实时打开结果；搜索输入仍在会话内 | 本机定义与查询分离 |
| 文件自然比较、目录/全书/标签自然排序 | Rust `library/order.rs`（从 bookshelf 提取） | 已服务 SQL 查询和目录；按完整快照一次计算 | Swift 搜索使用批量 ordinal 和同名分档，不复制自然 comparator |
| 搜索排名组合、AI 名称字典序/recent 平手顺序 | Swift `LibraryQueryRules.swift` | 与匹配结果一同完成，AI 原生字符串比较不迁语言 | 单源组合排序 |
| 拼音 key、字母分组及组内 localized collation | Swift `LibraryPresentation.swift::LibraryNameGroup` | 唯一实现且依赖 Foundation；不是原文件自然序副本 | 原位保留 |
| 多标签分组/未标注/未索引分区 | Swift `Data/Queries` 书架固定查询 | 按同一个索引身份分组，每个文件可属于多个标签 | 旧 Rust 查询已移除 |
| 目录四封面选择 | Swift `Data/Queries` 书架固定查询 | 独立 top-4 策略，不等于目录列表顺序 | 旧 Rust 查询已移除 |
| 字数定义与 UTF-8 前缀累计字数 | Rust `reading/text_count.rs` | 导入和覆盖对已校验切片计非空白 Unicode 标量，目录扫描在原有单趟扫描中调用同一谓词。手动修章由 Swift `UserValueRows` 校验与读取原行及旧块首累计值，一次调用 Rust 得到标题、正文起点的累计值 | 沿用存量块计数与正文坐标 |
| 字节位置→进度比例、百分比跳转 | Swift `Data/ReadingProgress.swift`；反向定位由 `ReaderOpeningRead.location` 执行 | 进度使用同一正文 SHA 的规范化 UTF-8 位置和长度。界面百分比格式和阅读位置附件取比例，跳转面板、系统目录和 AI `getBook` 取百分数；用户跳转仍校验 0…100 并贴齐 UTF-8 标量边界 | 只读换算，原始位置仍按 SHA 保存 |
| 有效章节/位置归属 | Swift `ReaderChapterRead.headingSQL`；`IndexTasks` 持有自动章节重建 | 导航、书架和统计使用同一有效章节边界；批注对排序后的偏移批量取前驱，搜索计算接收冻结标题，折叠目录按可见行定位 | 共享有效章节查询 |
| 文件目录类别、平台书架来源 | Swift `LibraryService` 与 `IndexSources` | 平台协调真实树和授权；Swift writer 对已准入扫描做一次事务，并保留失败范围最后清单 | 页面条目形状留 2c |
| 正文准备、目录覆盖与笔记选择 | Swift `IndexImport`、`IndexTasks`、`AppDataService` 与 `ReaderToolsModel` | 保留已提交前缀，提交失败丢弃 Rust 后继并从字节零重验；Swift 持有章节暂存，验证原正文再原子发布 | 窗口、覆盖等有效页面读法留 2c |
| 资料状态与统计范围 | Rust `reading/book_details.rs`，Swift `BookInformationModel` / `MoonreadStatistics.StatisticsModel` | 资料可无正文，未识别文件保留同一查询入口；详情来源沿指定文件，记录回退只在目标身份的文件中按目录阅读顺序选，不重复取资料和章；统计按目标和日期范围加载，首屏与累计详情独立，缓存按输入版本复用 | 同一身份查询链 |
| 数据管理操作与全量索引 | Swift `DataManagementModel` / `FullIndexController` | 列表加载与备份或删除分开；索引阶段与后台 runner 资源分开，暂停可先于 runner 退出。沿用已发布索引意图和备份编码 | 现有服务及资源 |
| 云激活、原生发现及文件交接 | Swift `CloudSyncCoordinator` / `UserDataService` / `CloudDocumentQuery` / `CloudDocumentHandoff` | 意图与账户激活分开，过期回调不发布；交接状态只在边界转为旧回执字段，异常组合没有删源资格 | 旧格式原样 |
| 正文智能缩进前缀 | Rust `reading/layout.rs::reading_indent_omissions` | 按真实段首与段落语义返回横向空白的运行时源范围，显示与选区摘录共用；Swift ReadingText 只映射省略区间，ReadingTypography 用字体度量设置两字几何。原文模式、标题、列表、续段不变，不写原件、SHA 或位置 | 显示投影 |
| 自动阅读偏好与计时例外 | Rust `reading/layout.rs::auto_reading_control` / `user/statistics/mod.rs::ReadingClock` | Rust 定义1–30档／默认10及指数 em/min 映射，Swift 经 ReaderSettingsStore 保存本机档位，按实际文本容器／缩放字体／正文行高换算位移；Swift 原生帧驱动只提供真实位移时间，Rust 单源裁决时长，不模拟手动 interaction |
| 自动阅读运行、打断与原生位移 | Swift `ReaderAutoReading` / `ReadingController` / `ReaderDeviceControls` | 同一附件与显式继续，使用原文位置／预取／有界检查点入口；复用统计可读性事实，临时常亮合并原 lease，不持久化运行状态 |
| 听书播放、跟随与瞬时高亮 | Swift `MoonreadReader/Session/Listening/`、`ReaderSession+Listening`、`ReadingController+Listening` / `ReadingLayoutManager` | AVSpeech/Now Playing 的单一 Session 控制播放；既有 TextCoordinates 映射语音范围，音频锚点与内存浏览分离，渲染只画临时范围；正文/规范化和统计规则仍归 Rust | 不新增位置、CloudKit、备份字段；声音不计阅读统计 |
| 阅读工具意图、关闭与输入 | Swift `ReaderToolSession` / `ReaderPresentationHost`、`ReaderBottomPanel` | ReaderSession 每次打开持有一个工具 owner。工具通过带 opening、访问 ID 和版本的动作修改 SurfaceIntent；根工具关闭统一从当前有效会话裁决恢复。宿主只记录物理安装和对应快照，同一快照驱动内容与真实页脚；旧回调只能释放原安装 | 不改公共导航、正文容量或存储 |
| 阅读执行、搜索与听书门禁 | Swift `ReaderExecution`（由 `ReaderSession` 持有）、`ReaderToolsModel`、`ReaderToolSession` / 原生呈现适配 | ReaderExecution 只持有当前执行主体，搜索任务独立于收起或展开；ReaderToolSession 从位置动作、选区和实际原生层的来源裁决一次播放资格。统计和自动阅读继续按正文可读性独立判断 | 均为会话状态；不持久化 |
| v2 统计总览、书目、时段和 Widget 固定读 | Swift `StatisticsHistoryRead`；Apollo 生成结果类型 | 期间总时长、日历和书目读 `reading_day`，按记录的自然日精确归并 UInt64；作者页按当前作品确认正文键批量选取同一总览，纳入已验证旧键并复用书目、总时长和正式阅读顺序；每书只定点补历史标题、作者与封面引用。时段从两种 current 读取起止、结算时长、类型 ID、首位置与历史标题。未知事实标不完整，相交未知清除阻止出数；覆盖仍由 Rust 计算 | 快捷指令仅取日量 |
| 有效阅读日 | Swift `MoonreadStatistics/StatisticsDataSource.swift::activeDayCount` | 在已筛选的日记录中按当地 day ID 对正结算时长的日期去重；App 统计和 AI 用总览的日记录，邀评复用同一规则并独立读取全书全期日量 | 单书累计日数与 Widget 连续日沿用各自查询 |
| 章节结构与覆盖加载 | Swift `ReaderChapterQuery.swift` / `ReaderToolsModel`，Rust `user/statistics/coverage.rs` | 目录结构先发布，不取事实。当前消费者只读目标书有效头、曝光文本与端点块；Rust 解码并裁去清除前缀，按连续停留算字节覆盖，再映射至非空白字符前缀。账户、正文边界或选中头变化时淘汰旧计算；兼容性阻断不显示 0%。离开后释放覆盖 | 无派生范围表或跨请求缓存 |
| 目录/临时跳转与正式续读保存 | Swift `ReaderSession`、`ReaderToolsModel` / Rust `ReadingFrame` | 目录断 visit 并 enqueue，不等统计 writer drain、不预读笔记；跳转 frame/章节标题在 Rust 同一读取事务中返回并一起发布；临时原点只在会话内存，原已接受保存走现有 saveTask；明确采用浏览位置或同步进度共用位置交还，结束听书后提交新位置，旧 flush 不得回写旧位置 | 不改正式位置格式 |
| 统计范围、观察与时段展示 | Swift `MoonreadStatistics.StatisticsModel`、`StatisticsSpan` | 同池观察按用途选列并合并已通知更新；保留上一范围并明示日期，不把旧数当新范围。账户变化和相交未知清除撤下旧数。单书先发布期间统计，再用同一快照复核期间并补齐累计、最近七个有记录日的时段。展示按原相邻条件合段，用类型和记录 ID 作行身份、用结算时长 checked 相加 | 每页独立观察，关闭页面取消读取；日界、时区和回前台重核参数 |
| Widget 统计摘要与连续日 | Swift `StatisticsHistoryRead.widget`；`SystemWidgetPublishing` 管日期窗口与发布 | 读已结算的自然日；今天无正时长则截至昨天，沿日期索引查到断日，不限七天。扩展只消费快照 | 独立调度和统计文件；不重建书目 |
| 同步位置领先阈值、有效章节与百分比 | Swift `ReaderOpeningRead.resume` | 用共用进度比例和有效章节查询一次裁决；会话持有本机基线与提示状态。见[同步设计](../data/sync.md#13-同步进度与编码) | 单源 |
| 手选编码 LWW 与升级 epoch 候选 | Swift `UserValueRows` / `UserSyncJSON`，`SourceDecodingPreferences` 编排 | rawSHA 和编码规范调用 Rust；formal 候选与 current 同提交，旧索引迁入任务在用户提交成功后才另行确认。开书、索引与 AI 读取 current 与同域隔离，无旧本机回退 | 按原始 SHA 同步编码值 |
| 章节修正、配色与书架引用写入 | Swift `UserValueRows`、`CurrentUserRows` | 章节编辑按原正文行边界校验，撤回保留候选；配色与其颜色关系、完整当前 Ref 同提交；书架引用只发布描述，与本机授权分离。三个全局域的 formal 读取仍按各自隔离规则 | 已接本机 writer；章节结构消费者另批切换 |
| 统计事实保存/去重裁决、日历展示桶/连续行视觉合并、显示格式 | Swift `ReadingStatistics.swift`、`MoonreadStatistics` 的图表与时段模型、`MoonreadDataTypes` 中 `StatisticsDates` 的日界与时长格式，按各自职责单源 | 图表按月或年分桶，时间线按相邻条件合段，两者均消费已结算的时长 | 展示与统计事实分离 |
| 备份 ZIP 布局、受限解包、路径/摘要与正文缓存 SQL 驱逐 | Rust `storage/maintenance/backup_archive.rs` 管 ZIP；Swift `ReaderIndex` 管缓存驱逐 | 缓存驱逐使用同一个 GRDB 池，保留索引/授权/任务 | 单源 |
| 来源栈 Tab 显隐 | Swift `LibrarySourceTabVisibility` | 按该栈路径中的阅读器及当前叶子目录的选择 preference 统一判定；目录只上报选择位置，不另提交相反显隐策略，不持久化全局选择标志 | 单一 owner |
| 笔记快照与可读导出 | Swift `NoteDocument.swift`、批注当前头、定点章节和正文长度读取 | 三入口共用摘录/出处与 TXT/Markdown 输出；快照不压缩候选，未知记录按范围阻止不完整导出；出处只取选中正文位置和可证的完整字节数 | 不增同步格式 |
| 用户备份 envelope、非事实恢复、对象级删除 | Swift `UserDataBackup.swift`、`ReadingDataManagement.swift`；同步删除状态由 `CloudTransportRows` 和 `CloudCallbackJournal` 持有 | 归档核验和字节准备先于写事务；恢复以候选及附件为输入，通过各领域同事务更新 current。封面附件只按合并后的候选引用入库，导出的封面取自实际导出的候选。只读预览复用各领域裁决，按正文 SHA 聚合差异并单列全局记录，无待恢复内容就跳过写事务。预览与写事务共用历史 ID 删除检查。同 ID 待发删除须先确认，再完整拉取本区后才放行 | 导出从同一用户库快照读取可携带的候选、附件及历史；无法完整编码时明确阻止导出 |
| 受保护来源的 bookmark 解析、安全作用域、协调读取与物理路径边界 | Swift `Data/Sources/ProtectedFileAccess.swift` | 开书、导入、索引、恢复和备份共用；沿用 `.withoutUI` 与可解析的陈旧书签，不增加拒绝条件；作用域覆盖各阶段，accessor 内不等待 actor | 平台边界 |
| 本机来源下载可用性与目录发布 | Swift `AppDataService.prepareSourceFile`、`LibraryService`、`IndexSources` | 协调访问成功后只改同位置现有行；旧源准入复核及通知由服务负责 | 唯一索引 writer |
| 正文缓存清理准入 | Swift `CacheManagement.swift`、`ReaderIndex` | 盘点读取缓存索引。打开的阅读请求先按正常退出流程保存并释放 lease。执行时复核当前活动持有者、缓存目标和导入任务 | 只操作派生正文 |
| 存储盘点与数据库维护 | Swift `StorageManagement`、`DataSession` 和 `CloudSyncCoordinator` | 文件按容器归类、去重，删除资格由各数据所有者给出；手动整理只操作当前附加用户库，排除在途同步。附件回收与同字节封面复用归 `UserValueRows`。提交后由缓存清理与封面加载器移除闲置读出副本，盘点时核对共用目录对应的各本机库 | 不改变持久化格式 |

维护约定：新增规则先查本表；已存在则调用 owner。新增或改变归属必须在同一 PR 更新表、实现入口及测试位置。两个策略若故意不同，命名其输入/输出契约；不能仅以语言或调用入口不同为理由再实现一份。


备份容器布局、受限解包与路径/摘要验证由 Rust `storage/maintenance/backup_archive.rs` 负责；用户备份 envelope 和非事实接入由 Swift `UserDataBackup.swift` 调用各领域关系 writer。`ReadingDataManagement.swift` 只编排本机事务交接，`ProtectedFileAccess.swift` 负责 bookmark、安全作用域和协调读取；`CacheManagement.swift` 负责缓存清理准入与活动保护，`StorageManagement.swift` 汇总存储空间；页面不实现另一份身份、排序或合并规则。数据管理列表的自然顺序调用 Rust `reading_data_order`，本地化文本匹配复用 `LibraryQueryRules`。

## Rust 源码目录

`crates/moonread-core/src/lib.rs` 仅声明领域模块、重导出现有 API 和注册 UniFFI scaffolding。模块移动不改变规则 owner、导出名称、签名、正文身份或持久化格式；跨实现模块需要的 `pub(crate)` / `pub(super)` 只表达原先 crate 根及父模块已有的内部访问范围，不增加对外 API。

| 目录 / 入口 | 职责 |
| --- | --- |
| `core.rs`、`error.rs` | 正文交换值、共享错误与已发布导入错误格式 |
| `library/` | `bookshelf/` 分查询、mutations、source、full_index（及原 SQL）和测试；order 保留独立入口；`tools/mod.rs` 保存原 DTO/导出，text 处理文本范围与段落，search 持有搜索对象和状态，catalogue 装配章节及内部共享查询 |
| `identity/` | content 阅读键与文件关联、source 原件探测/解码策略、sha |
| `reading/` | `input/` 汇集 ingest 事务正文导入与 text 解码/分块；chapters 扫描、navigation、layout、cover_page、book_details 保留独立入口 |
| `reading/progressive/` | 任务类型与状态入口；tasks 生命周期、stream 前缀分块、recovery 恢复/回收、query 不可变读取、原有测试 |
| `user/` | `reading_fact.rs` 负责阅读事实载荷校验和编解码，`projection.rs` 编解码排版设置与书籍元信息；`statistics/` 保留计时/聚合入口和 coverage；`themes/` 中 models、preferences、textures、palettes、resolve 分别保留类型、偏好迁移、正式图案、配色/对比度及校验解析，父模块重导出原 API；v2 用户表是阅读事实权威 |
| `storage/` | 原 schema.sql、migrations、validation、rows 正文缓存 SQL 行映射；`maintenance/` 汇集 backup_archive 与 cache_management，父模块重导出原 API |

SQL 内容、迁移顺序和调用时序保持原样；仅按新目录调整 `include_str!` 路径。章节和渐进准备的既有测试随实现移动，不复制测试或规则。

## Swift 源码目录

`ios/Moonread` 的真实目录与 Xcode groups 对应。此次整理改善源码导航与文件职责，沿用现有状态 owner、actor 隔离、任务生命周期、存储和接口；没有隔离共享 actor，也没有改变 JSON 投影的类型契约。

| 目录 | 文件职责与保留边界 |
| --- | --- |
| `App` | 应用入口和 `MoonreadDelegate`；App 继续持有同一个 `CloudStore` |
| `Library` | `LibraryModel/` 中 `LibraryModel.swift` 保留原存储和初始化，Navigation/Discovery/Reload/Imports/FileWork 同类型扩展分职责；`LibraryRoutes.swift` 保留原路由与首页快照值；`Browsing/` 保存首页、全部小说、文件夹、最近阅读及行/原生集合；`FileOperations/` 保存文件动作、drop 与独立 `LibraryExport.swift` 暂存生命周期，`Search/` 保存查询/筛选/排序，`Sources/` 保存真实目录、云文件与协调访问，`LibraryDirectoryObserver.swift` 只承载原文件呈现回调，`Indexing/` 和 `Recovery/` 保存索引/恢复及各自本地化；管理页保持入口，状态/绑定及层级不变；封面由 `Books/BookMetadata.swift` 的 `BookCoverView` 接入既有图片加载器；`Fixtures/LibraryUIFixtures.swift`、`LibraryStoreShotFixtures.swift` 与 `StoreScreenshotFixture.swift` 汇集 DEBUG/测试合成输入，target membership、隔离目录及初始化顺序不变 |
| `MoonreadReader/Session` | `ReaderSession/` 中 `ReaderSession.swift` 保留原存储、init、open/leave；Loading、Position、Preparation、Browsing、Continuation、Annotations 为同一类型的领域扩展，完整保留现有会话 owner；`Opening/` 汇集开书协调与已有诊断入口，ReaderAutoReading 保持会话级入口 |
| `MoonreadReader/UI` | `ReaderScreen/` 中 `ReaderPage` 持有阅读状态、会话生命周期和原生呈现协调；Content/Controls 扩展使用同一页面状态。App 的 `ReaderScreen` 把现有来源导航和外部目的地接给 `ReaderPage`；`Presentation/` 汇集原生呈现、来源导航及工具会话；`Controls/` 保存顶部提示、附件内容与更多操作，`Chapters/`、`Notes/` 保存目录与笔记，`Tools/` 保存工具 model/标签，`Search/` 保存完整原生搜索页和紧凑续搜入口；目录在 `Chapters/` 使用系统 List/DisclosureGroup/searchable 和独立惰性行，读取同一轻量快照；偏移 ID 由 ForEach 提供，仅当前章可见性回写页面；原意图路径、绑定和视图层级不变 |
| `MoonreadReader/Rendering` | `ReadingView` 是 SwiftUI 适配入口；`ReadingController/` 汇集原控制器及 Pages/Scroll/Navigation/Selection 扩展，`Pages/` 保存叶页/扉页控制器，`Text/` 保存排版装配、坐标、原生正文与背景；ReadingPagination、ReadingViewport 和设备控制保留原入口/owner |
| `Books` | 小说详情与完整 `BookMetadata`；封面展示、加载及服务私有辅助保留原文件边界 |
| `Statistics` | `StatisticsView` 装配总览和单书入口，提供书籍资料、导航、设置与 AI 动作；`StatisticsModels` 适配数据读取、提交观察与删除；`ReadingStatistics` 保有 writer 和 recorder。范围、页面观察、书目、图表及日/时段详情在 `ios/Packages/MoonreadStatistics`，共用日界和格式由 `MoonreadDataTypes` 的 `StatisticsDates` 提供 |
| `Settings` 与 `MoonreadSettings` | 包持有设置菜单、引导、帮助、iCloud 设置、关于与打赏，以及配色编辑和选择、数据管理、阅读数据问题和清单、存储空间各页及其状态。App 接线场景导航与首次引导选择，保有现行 TipKit 类型和完成记录，注入资料交换、文件授权、后台执行、存储清理及 ThemeStore。阅读预览继续由阅读包提供，App 负责装配。应用的唯一打赏实例从 App 启动时监听交易。 |
| `Data` | `AppDataService`、GRDB 用户数据及同步协调；`UserData/` 中 UserDataModels/UserDataValues 保留原模型与载荷，UserDataStore 的事务/存储留在同目录 UserData.swift，Values/Annotations/Statistics/Projection/Transfer 只物理拆分方法；UserDataService/Backup/SyncJSON/Themes 归入同目录，`Cloud/` 汇集云同步，`Restoration/` 汇集续读恢复，`Management/` 汇集备份/缓存编排，`Sources/` 汇集受保护访问与编码解析；正文准备、导入、云目录 owner 与紧耦合私有类型仍在 `AppDataService` |
| `SystemIntegration` / `SystemIntegrationShared` | 主 App 派生快照、系统入口路由与平台更新；共享部分只有稳定链接、只读 DTO、最小 Entity/配置与无状态文字卡片。Widget/Control 目标不含数据库/正文服务；任意队列系统回调显式 nonisolated / @Sendable 后再交接 |
| `Shared` | `Theme`、`MoonView`/`MoonCharacter`/`BrandSeal`、输入焦点及跨功能错误文案 `ReaderMessages` |
| `AI` 与 `ios/Packages/MoonreadAI` | 包持有运行时、仓储、连接、认证、目录、传输、工具契约，以及对话列表、聊天布局、原生消息视口、输入、设置列表和预览。App 注入消息行中的书籍详情、批准与写入，接入会话许可、平台分享与授权正文读取。模型快照及供应商品牌资源从包读取，运行时在 AI 入口首用时初始化。 |

`ios/MoonreadTests` 按 Library、Reader、Data、Settings、Statistics、Platform 与已有 AI 归目录，AI 夹具在 `Fixtures/AI/`；会话支撑留在 `ConversationTestFixtures.swift`，会话网络协议及共享状态、连接/认证协议与店面查询、原生事务 fixture 分别位于 `AIConversationProtocolFixtures.swift`、`AIConnectionFixtures.swift`、`AINativeToolsFixture.swift`；类/方法名和测试发现保持，UITests/TestPlan/scheme 入口不变。

`ios/MoonreadShare` 是独立分享扩展 target，只负责接收与取消。`ios/ShareReceiveShared` 同时编译进主 App 与扩展，提供版本化 ShareInbox、原字节复制和 provider 生命周期适配；不依赖主 App 的 Rust、SwiftData、AI 或阅读 UI。App Group 只共享待导入原件，主 App 继续独占书架写入和正文准备。

拆分保留现有类型、状态 owner 和 actor 隔离；SwiftUI 的 `@State` / `@FocusState` 留在原父视图，目录子视图只接收 Binding 和回调。UIKit 控制器跨文件扩展共用状态与方法时，仅将必要成员调整为模块内访问，其余保持 private，不增加 public API。原有 Sources UUID 与 target membership 保留，新增拆分文件显式加入应用 target。设置和统计按完整 View/model 类型移动，原有私有状态和 actor 标注保持；共享的页面与图表 helper 只在必要时由文件私有调整为模块内访问。

`AppDataServiceFactory` 选择普通、测试、截图与诊断环境。App 的 `SystemReadingPublication` 和换户接线保留原来的发布、撤销与重接观察顺序。`MoonreadData` 拥有唯一的 `DataSession`、GRDB 连接池、账户和引擎 lease、`ReaderIndex`、SQL 资源及关系结算规则。AI 书目引用、批注分组、系统来源查询以及 Spotlight 提交状态的读取与替换事务同样经 `ReaderIndex`。发布版 SwiftData 模型和只读库打开器保留在主 App，借由 `LegacyUserStore` 在原事务中分页递交字段。

`MoonreadLibrary` 包含目录及最近阅读、书架首页、列表和网格、文件任务界面、索引面板、搜索和虚拟书架、书架管理、作者页、书籍详情及资料交换。App 注入账户变化、文件授权、覆盖读取、封面与跨功能导航。索引队列和资料交换记录由 `MoonreadData` 持久化。

`MoonreadReader` 持有阅读会话、开书进度、正文窗口与视口、UIKit 阅读控件、工具页、听书和自动阅读、阅读活动采样，以及排版预览、字体和快捷设置。App 通过 `ReaderDataAccess` 注入原 `AppDataService`。位置、批注、章节与阅读段仍走现有账户作用域、写入事务和 lease 释放顺序。App 负责来源栈、系统开书确认、完整设置、统计与 AI 对话的目的地装配。 阅读器向 App 提供原文坐标和选区，由 App 转换为 AI 附件。App 观察作者统计并把摘要行交给书架页面。阅读器、书架、统计、设置和 AI 包之间无直接依赖。同一数据错误的显示文案与跨功能通知名称在 `MoonreadDataTypes` 定义。Widget 通过无正文依赖的 `MoonreadInstalledFonts` 复用系统字体可用性检查。

`AppDataService` 当前协调小说来源、Swift 索引与 Rust 正文计算、用户阅读数据、配色与同步，不仅服务阅读页；`ReaderSession` 才是阅读会话状态 owner。其扩展已随领域位于 Library、Books、Statistics 和 AI，Data 保存用户事实、备份/缓存及同步协调。`MoonreadData` 内的 `UserBackupRestore` 负责预览与还原，`RelationalReadingData` 负责清单与导出。`MoonreadDesign` 的 `DataExchangeTask` 管理小说信息和阅读数据共用的进度、结果和停止状态，由宿主接入系统后台执行。备份审阅值和正文缓存清单由 `MoonreadData` 提供。名称仍为 `AppDataService`，领域扩展共用同一 actor 的串行边界；文件目录不改变数据权威和存储归属。

## 原文件与平台访问

- 当前阅读与正文准备只读小说原件，阅读记录、索引和缓存放在应用数据区。统一书架设计允许用户主动重命名、移动、建目录与删除真实文件；这些操作由平台协调执行，Swift 管理文件索引，Rust 只计算正文身份。
- 系统文件选择器决定可访问范围；“选择目录”不代表能够访问整个 iOS 文件系统。
- Swift 在安全授权和文件协调有效期内提供可读源，Rust 执行文本处理。平台路径、授权 bookmark、凭据不作为跨设备书籍身份。
- 当前按已授权根枚举真实子目录与 TXT，成功扫描后事务更新文件索引；失败保留已知清单。Swift 索引 writer 保留稳定文件 ID；目录和最近阅读的固定查询在 2c 接入，Rust 自然比较保留；Swift LibraryQueryRules 负责书目匹配与搜索排名，平台层管理系统授权与 NSFileCoordinator。见[数据与来源](../data/README.md)与[书架界面](../design/library.md)。
- 目录暂时不可用或扫描缺失不等于删除阅读记录。“移除来源”“删除原文件”“清除用户记录”需要分别定义，不互相隐含执行。

文件提供方可能在交出可读 URL 前完整下载云端文件；不能把本地渐进解析等同于云端边下载边读。原始 SHA 与解码策略快开、协调读取及中断恢复详见[渐进正文准备](../reader/import.md)。外部目录中的 iCloud Drive 文件由提供方管理，不代表月读已同步设置或阅读记录。

## 内容身份与位置

- `bookId` 为 UUID。规范化 v1 只去除开头 BOM，并将 CRLF/CR 转为 LF，其余原文保留。
- 规范文本 SHA-256 相同则关联正式内容；改名、移动、重复导入，以及只改变编码或换行形式的文件可以共享记录。
- 正文追加或修改创建新记录并保留旧记录，不凭相同文件名自动合并，也不执行跨版本自动重定位。
- 渐进任务在 SHA 完成前已有稳定 ID；完成后通过映射解析正式书籍。正式位置统一取最后更新，去重关联见[导入去重](../reader/import.md#去重与位置归属)。

上述去重属于正文准备与记录关联。原始 TXT 导入在目标目录内按实际文件名提示替换；重命名和移动只改变文件定位，正文 SHA 不变。同名替换也不改变正文坐标必须匹配的规则，见[导入与替换](../data/README.md#导入与替换)。

- 位置保存为同一内容版本的规范 UTF-8 字节偏移，范围使用 `[startUtf8, endUtf8)`。核心校准有效边界；Swift 仅在局部窗口映射 UTF-16。
- 页码、滚动像素、屏幕尺寸、存储块编号均不是持久阅读位置。换模式、字号和屏幕方向后以原文锚点重排。
- 范围摘录用于辨认；相似上下文不能作为把旧批注静默贴到新正文的依据。

自然阅读、布局重排和显式跳转是不同操作。目录、搜索、书签与批注的临时浏览保护统一见[阅读工具的定位契约](../reader/tools.md#共同的数据与定位契约)。保留正式续读原点，同时由 Rust 管理最多 32 项的会话跳转历史；回退/前进不压入重复历史，新的跳转截断前进分支。普通临时浏览确认继续阅读或回到原点后结束本次历史；接受同步进度提示时保留原点与会话历史，仍由同一 Rust 导航规则管理。

主题类型与解析分工见[主题模型](../design/themes.md)：Rust 管理配色校验和继承计算；新用户库保存配色方案本体，UserDefaults 保存各设备的显示选择与首帧快照；平台负责语义颜色和渲染。

文件定位与正文关联实现见[关联交接](../data/README.md#文件定位与-sha-关联)。保留 SHA、现有存储职责和规则归属边界；交接发布关联必须先于扫描，外部修改重新核验。SQLite 事务同时发布最后已知关联与固定根，平台记录保护复制和清理之间的中断重试；临时任务不作为已完成快开缓存。

## 持久化

当前表、schema 版本、文件位置、目录授权与首帧快照统一列在[当前实际存储](../data/README.md#当前实际存储)，不在多份文档重复维护表清单。

Swift 关系库是本机用户数据权威；旧阅读 SwiftData 库仅以只读方式迁入。旧 ReaderQuery 和 TEMP 已退场，页面、AI 批注、数据管理与备份均读新用户表。所有书架是统一真实目录：云端 TXT 与目录结构交给 iCloud Documents，用户可从系统文件工具直接整理；CloudKit 只同步阅读数据与配色方案，不镜像书架文件清单或原文。运行中的 SQLite 不放进云文件夹。职责与冲突规则见[同步设计](../data/sync.md)。

## 持久化演进与发布兼容

兼容只对照已发布给用户的版本（main，或已提审且会先上架的构建）。release 分支开发中的中间结构不做兼容和迁移，可直接修改；未发布的新结构（如小组件标识、共享快照字段）直接按最终形状写。检查时对照基线提交 diff 持久化与共享结构；设计文档讨论兼容时须注明基线版本。

从 1.0.0 发布基线开始，SQLite、SwiftData/CloudKit、UserDefaults、Keychain、同步 payload 与缓存的格式变更必须保持已有数据可读。持久化枚举只增加、不删除或更改已有 raw value；退役功能可停止展示，不能用未知值使整个集合读取失败。新增字段使用可选值或明确默认值；结构调整须带版本、升级路径与迁移测试（旧数据、重复打开、失败回滚、降级拒绝），不能以删除重装代替升级。内部非持久化接口仍可直接整理，不要求保留无用的重复实现。

`Data/v3` 是目录布局的版本。`index.sqlite` 和 `user.sqlite` 独立版本化，当前分别为 v2 和 v9，遇到不支持的版本不覆盖。1.7.1 的用户库为 v7，升级时先经 v8 新增本机虚拟书架表，再经 v9 新增已获删除回执、尚待拉取的历史记录表。

1.6 旧库继续沿用 1.7 发布时的迁入规则。旧索引采用 SQLite user_version 20–23。v21 增加导入任务目的，v22 增加全量索引，v23 登记手选编码迁移输入。索引迁入器只读接入这些文件、保留旧源，复用发布 SQL 形状并在目标事务内核对行键、关系及字节；只迁入升级时已确认 raw SHA 的旧编码映射。用户数据迁入通过 SwiftData 发布模型读取，结构迁入完成标记不等于已满足云附件和切换门槛。位置 token／批注操作仍在后继 SAVE 精确回执后放行前驱 DELETE；撤回压缩删除时不额外保留前驱归属。账户 local 并入先提交目标用户文件，续做需要的索引任务归属更新，再清冻结源；三个文件写入各自提交，不依赖 ATTACH/WAL 跨库原子性。

AI 连接、共享授权、用途默认值逐条解码，失败条目跳过并记录不含正文/凭据的日志；会话列表逐行容错，存储读取错误仍向上抛出。读取不修复、不回写。显式保存时按稳定 ID/用途键更新可识别项，保留不可识别的原始 JSON 元素与未知对象字段；用户可删除可识别项，不能顺带删掉未知项。JSON 整体损坏时拒绝覆盖并报告失败。用途字典既读取此前 Codable 的键值交替数组，也读取对象，显式保存统一为字符串键对象。授权撤销另更新连接 generation，保留的未知授权不能绕过该边界；日志只记录集合键和序号。同步 payload 采用独立的版本/隔离契约，见[同步专题](../data/sync.md#同步-payload-的-v1-边界与隔离)。

`readingSettingsTab` 的发布取值固定为 `typography`、`colors`、`controls`，标题另行本地化；按发布前决定，旧开发中文取值不迁移，回到默认排版页。已识别对象内的数组字段按当前编辑值保存，不将这项容错措施宣称为任意嵌套协议的无损回放。

正文身份 `content_sha256` 的 normalization-v1 是稳定契约。已经支持的文件，其解码策略与规范化结果不得因依赖更新、算法整理而静默改变；若确需变更，须保留原键到新键的映射与所有进度/标记关联，并测试旧文件解码和旧键恢复。缓存可版本失效重建，但不得连带抛弃授权、解码选择、任务暂存或用户记录。

1.6 的最近打开复用既有 UserValue v1 envelope 和 LWW，新增可缺省的 `opened/<reading-key>` 值（JSON Int64 毫秒）；缺失不伪造，排序回退已发布 1.5 的位置时间。既有 SwiftData 模型、CloudKit schema、位置和备份容器格式不变；完整备份包含此值，pending 晋升和按书删除沿原入口处理。旧版可保留未知键，1.6 能读取原有 1.5 数据；没有开发中间态迁移。

已发布的 SwiftData 模型按其发布版本识别。仍使用 SwiftData 的 AI 会话库遵循以下演进规则。1.0.0 的阅读数据库与 AI 会话库没有使用 `VersionedSchema`。1.0.0 之后第一次修改任一库的模型（包括只加可选字段的轻量变更）时引入版本化：1.0.0 的现有模型原样作为 `SchemaV1`，新模型为 `SchemaV2`，加 `SchemaMigrationPlan` 与旧库升级测试；此后每个发布过的 schema 都保留一个版本，轻量变更用 lightweight stage，不能只登记首尾两端。CloudKit 生产 schema 只增加字段/记录类型，不删改既有类型及字段语义。UserDefaults/Keychain 的键名与凭据编码属于数据契约，变更需迁移且不得落入日志。阅读事实 payload 由 Rust 类型化校验，其他同步 payload 由 Swift 校验；Swift 存储边界按作用域隔离未知内容，不能靠 JSON 字段保留代替 LWW 并发设计；详见同步专题。

重置仅限当轮明确授权的开发数据，不是发布后错误恢复方式；不得删除用户的外部或 iCloud 小说原件。上述约定不改变[iOS 版本和 API 兼容策略](ios-support.md)。

## 技术参考

- [UniFFI](https://mozilla.github.io/uniffi-rs/next/)
- [Apple 目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、[文件协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [TextKit 2 能力介绍](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [SQLite 备份与运行中数据库](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)

## 正文接口与业务查询归属

2b 已移除 Rust `ReaderCore`、`ReaderQuery` 及正文库的 SQL/迁移。Swift `DataSession` 独占当前环境的 `Data/v3/<environment>/index.sqlite`，按作用域挂载对应的 `usr`。来源扫描、解码策略、导入、章节暂存、搜索和缓存驱逐共用这一池。慢速文件协调和 Rust 计算在数据库闭包外。资料包的私有暂存 `inspection.sqlite` 与归档文件 I/O 由 Swift 管理；Rust 保留交换格式和预算。

导入从实际 EOF 或 64 KiB 加一字节识别编码，每步最多读 8192 个新字节。中止后新建 Rust 状态，从头读并按连续窗口验证至多 16 个既有块。允许有界合并多步输出；只有提交才推进已发布进度，提交失败丢弃整批未提交输出和工作状态。2b 仍在每个产出步骤后提交。若连失败或暂停状态也写不进去，Swift 在当前 lease、书 ID 与代次内保留终态；下一代任务或切换会话不继承旧终态。章节暂存到最终 apply 才替换正式内容。

2c 的用户库准备先由 writer 校验两个版本、配置 `usr` 的 WAL，再开放连接池的读侧，以便已存在的索引能安全换绑新账户。迁入已知归属的旧用户源时禁写、禁 CloudKit；成功写入完成标记后才开放新关系表。关系表的打开记录和位置是不同事实，按领域、书键和分区复用隔离屏障；位置可与隐藏、首选副本和续读基线同事务提交。含 `usr` 的 GRDB 观察在 writer 上串行读取初值并注册，因为连接池并发观察只比较 `main` 的 WAL；重取也占 writer，耗时计算留在查询闭包外。store 仍需在参数或账户变化时取消并丢弃迟到结果。

1.7 的固定查询直接读取 GRDB 表。选择有效位置、章节覆盖、统计日期范围和目录自然顺序仍遵循发布语义。

SHA-256 是规范正文身份，原始 SHA 加解码策略仅作快开和字节校验，UUID file id 只定位副本。路径、mtime、平台 generation 与 xattr 均不构成内容身份；不在小说原件写扩展属性是已确认边界。用户库事务同时写入阅读事实及其出站意图，CKSyncEngine 负责传输；Automerge 原型未进入依赖，不并行引入第二套 CRDT。框架限制若影响既定体验，先取得可复现证据再决定是否换存储。
