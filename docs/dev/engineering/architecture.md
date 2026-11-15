# 架构与数据约定

本文记录已采用的技术与共同契约。功能现状从[开发文档入口](../README.md)进入，未完成范围统一见[后续计划](../roadmap.md)。当前存储与统一文件夹书架设计见[数据专题](../data/README.md)，iCloud Documents/CloudKit 分工见[同步设计](../data/sync.md)，代码接入与云端验证边界见[接入实施](../data/sync.md)。

## 平台与职责

首个平台是 iOS，后续可能增加 Android。每条业务规则有一个明确归属方，按语义、数据权威与平台依赖选择 Rust 或 Swift，见下方规则归属表；Swift 同时负责 iOS 界面、原生排版和平台适配。当前通过 UniFFI 连接；SwiftData 仍是用户数据权威。#270 2b 分支中，Swift 的 GRDB 池保存正文、索引与任务；2c 才接齐页面直查和新用户表写入，中间态不发布。

| 部分 | 当前实现与职责 |
| --- | --- |
| Rust 文本核心 | `crates/moonread-core`：`encoding_rs` 解码、规范化、字素分块、SHA-256、章节扫描、`regex` 单书搜索 |
| Swift 索引与任务 | `DataSession` 的 GRDB 池保存正文、自动章节、来源索引与导入任务；Rust 接收有界值并计算，不打开正文索引库 |
| Swift 用户数据 | `UserDataStore` ModelActor：用户事实、完整批注候选、小说信息、配色及正式位置；自动 CloudKit，设备偏好独立 |
| Swift 关系库迁入 | `Data/Database/DataSession.swift`：`Data/v2` 的版本化正文索引与独立本机/账户用户文件，由一个 GRDB 池挂载；仅提供迁入和归属边界，尚未接入应用启动、页面或生产同步 |
| Swift 平台适配 | `Data/AppDataService.swift`、`Library/Sources/LibraryService.swift`：目录授权、bookmark、协调扫描与真实文件操作、目录变动通知、生命周期和异步工作调度 |
| 页面状态 | `Library/LibraryModel/LibraryModel.swift` 与同类型领域扩展保存书架状态、来源路由及唯一设置会话 `SettingsNavigation`（任务路径、配色草稿/预览）；`Reader/Session/ReaderSession/ReaderSession.swift` 与同类型领域扩展保存现有阅读会话状态与任务 |
| SwiftUI 页面 | `Library/Browsing/LibraryView.swift`、`Reader/UI/ReaderScreen/ReaderScreen.swift`、`Reader/UI/Presentation/ReaderLibrarySheet.swift` / `ReaderSearchContent.swift` / `NoteEditor.swift`：书架、阅读、工具面板与编辑器呈现 |
| 原生正文 | `Reader/Rendering/ReadingView.swift` 适配原 UIKit 控制器，`ReadingPagination.swift` / `ReadingTextDecorations.swift` 使用 TextKit 1；`Reader/Rendering/Text/TextCoordinates.swift` 映射 UTF-8 / UTF-16，处理局部滚动、分页与选字 |
| Swift AI | Providers / Agent / Data / Tools / UI 分层；Swift AI SDK 承担协议与工具循环，本机 SwiftData 保存对话；读取工具经 AppDataService 读取不可变投影，书目匹配由 Swift LibraryQueryRules 统一 |
| 后续平台 | Android 可复用 Rust 正文与计算核心；不预先增加平台依赖 |

依赖及版本以[根 Cargo.toml](../../../Cargo.toml)、[核心 Cargo.toml](../../../crates/moonread-core/Cargo.toml)和[锁文件](../../../Cargo.lock)为准。当前单书正文搜索直接使用 Rust `regex`，不启动 `rg` 子进程，也未采用 `grep-searcher`。具体搜索语法和限额见[阅读工具](../reader/tools.md#搜索先找到上下文再决定跳转)。

TextKit 1 的显式字形范围和文本容器用于两种阅读模式。Swift 只持有邻近正文，不一次布局整本；是否迁移 TextKit 2 取决于实际排版、选区和性能需要。Rust 不承担 iOS 字体度量，用户数据只由 SwiftData 持久化。

## 规则归属表

每条独立规则只在一处实现；调用层只测边界及自身状态。表中“后续”项登记待收敛的现存副本，不将它们写成已经单源。Rust 路径前缀为 `crates/moonread-core/src/`，Swift 主 App 前缀为 `ios/Moonread/`。

| 独立规则 | 唯一归属方 / 文件 | 理由与其他层边界 | 现状 / 边界 |
| --- | --- | --- | --- |
| 封面显示优先级、预设分配与排版 | Swift 共享 `SystemIntegrationShared/SystemReadingCard.swift` 的 `SystemBookCover`；`SystemPresetBookCover.swift` 负责预设绘制 | `SystemBookCover` 唯一决定用户图片优先、否则预设／无 SHA 文字兜底；App 的 `BookCoverView` 只订阅既有 `CoverImageLoader`，小组件只读取共享缩略图，Spotlight 用同一视图生成缩略图，阅读扉页也复用；统计查询从现有资料投影带回作者及封面。固定六款按完整 content_sha256 取余6；主 App/小组件共享竖排、横排、作者、固定字色、书脊与有界缩略缓存；宋体仅用已安装字款，缓存包含实际字款；无身份文字封面使用固定暖灰纸/墨色；不重算身份、不写用户封面事实。扩展对传入 SHA 拼写作防御性校验，主 App 沿用 Rust 身份校验 | 显示规则及读取接线共用；不新增用户数据格式 |
| 小说信息交换格式、归档与诊断 | Rust `metadata/`，共用 `storage/maintenance/archive_limits.rs` | JSON/JSONL/ZIP、版本/必需能力、流式私有暂存、路径与资源预算；不实现字段正规化或 LWW | 新增单源 |
| 小说信息编辑与交换 | Swift `Books/BookMetadata.swift`、`MetadataExchangeRows`、`UserValueRows.putMetadata` | 预览和资料导出在同一 GRDB 快照匹配索引、全库副本与 current 引用；保留正式库逐 SHA 兼容屏障及 pending 整对象。单书和资料包共用事务 writer，批量预取选中键的全部设备时钟与兼容状态。封面在事务外准备，候选、附件与 current 一次提交。原配置、用户库 lease 与删除代次在批闸门内复核；唯一来源改名仍独立，并核对正文身份 | 资料交换已切关系库；页面详情及其他消费者另批接入 |
| 配色草稿字段与保存准入 | Rust `user/themes/palettes.rs` 的 `validate_theme_palette_draft` / `make_theme_palette` 共用名称 trim、Unicode scalar 长度与 RGB 校验；Swift `UserThemes.paletteSaveIssue` | UI 只消费字段原因并定位名称，保存仍由服务按当前事实检查 64 个上限与编辑目标；已存配色解码不重新规范化 | 单源字段规则／服务事实 |
| 配色专属纹理支持、descriptor/混合参数、独立开关及发布迁移 | Rust `user/themes/textures.rs`（descriptor），`preferences.rs`（偏好与迁移），`resolve.rs`（校验/解析） | 分层资源、锚点/尺度限制与混合参数单源；按最终有效内置配色 ID 解析；运行时区分不支持、关闭、启用，关闭仍保留图案说明；本机 version 1 map；旧 1.3 两槽播种同明暗全部支持项，缺 key 新默认开；App/官网共用 descriptor，不再维护通用纹理/强度/Lr/tile 运行契约 | 单源 |
| 导入字体资源身份、引用与清单格式/校验 | Rust `user/reader_fonts.rs` 与 `reading/layout.rs` | 复用 Swift `SourceIdentityProbe.rawSha256` 与 Rust raw hash 步进 标识原字节；Swift `ReaderFontLibrary` 负责协调复制与 Core Text 注册，`ReaderBuiltinFonts` 管已知 Apple 宋体/圆体的按需下载与可用性，已安装字款与中文字形验证共用 Swift 共享 `SystemInstalledFont`；封面只读可用性，不调用下载，Rust 将已存偏好解析为内置字款或导入引用与兜底字款；`ReadingTypography` 唯一处理平台可用性及正文/预览回退；资源/face 可用性改变使排版缓存失效 | 单源与平台接线 |
| 字号、行距、段间距的默认值、范围与控件步长 | Rust `reading/layout.rs` | `reader_typography_controls` 同时供设置校验、Swift Stepper 和官网导出器使用；原生/浏览器字体度量各自归平台 | 单源 |
| 阅读设置当前值、连续修改与串行保存 | Swift `Settings/Reading/ReaderSettingsStore.swift`，App 级可观察环境对象 | `ReaderSession` 和设置页共用同一实例，不持有可写副本或各自排队；`AppDataService` 仍负责既有 UserDefaults 编解码和持久化，Rust 校验范围不变 | 单一 owner |
| 纹理偏好本机保存/回滚 | Swift `UserThemes` / `ThemeStore` | 原 UserDefaults key，缺 key 与已有坏数据分开；不可读不能被默认覆盖；不改 Palette、CloudKit 或备份 | 平台边界 |
| 正文几何、叶页分组、活动叶及原文选区恢复 | Swift `Reader/Rendering/ReadingController` / `PageController` / `ReadingViewport` | 原生字体度量与硬件保留区归平台；一个 pager、一份统计输入，源范围用 Rust UTF-8 坐标。`ReadingContainerRegions` 单源拆分保留区；`ReadingTypography.prepare` 单源装配 `PreparedReadingText`（映射、富文本与当次版本），分页/滚动/预览只消费及派生配套结果，不新增缓存；TextCoordinates 和 Rust 语义不变。正文占满本阅读窗口，sheet/键盘/工具路径不参与几何，不为工具让位；真实窗口或排版改变才按锚点排版。宽>高且每叶满足最小行宽自动双页，保留无效 canvas 与转场检查；几何变化不写阅读事实。正文滚动文本已有固定头部，创建时关闭系统额外顶部滚动边缘模糊，避免交互返回取消残层遮挡首行 | 平台排版 |
| 阅读呈现意图与原生占用 | Swift `Reader/UI/ReaderScreen/ReaderScreen.swift` 保留私有 State、生命周期与来源导航，`ReaderScreen+Content.swift` / `+Controls.swift` 只组合原内容；`ReaderPresentationState` / `ReaderPresentationProjection` / `ReaderPresentationHost`；`ReaderToolSession` 保留编辑对象引用，批注权威仍为 `ReaderSession` | selection、有类型 path、exposure 与栏显隐单源；所有尺寸用同一手机工具 sheet/原生任务导航，无 inspector、容量投影或手画页头。完整设置/详情直接绑定同一逻辑路径并在来源栈 push，原生 sheet 释放后交接；系统返回直接生效，不等待原生完成或校验工具代次。工具 sheet 的 opening/token/代次仍隔离旧回调，退出内容仅保留渲染引用。阅读模块在原生返回手势资格通过后、开始前临时显示自身导航栏并完成公开布局，显示意图与 controlsVisible 分离；完成/取消清除临时状态；取消与正文点击共用关闭工具入口；源页不设置恢复条件。系统子模态保留父链，窗口变化不改路径/草稿或写偏好 | 单一 owner |
| 系统通知进入界面隔离域 | Swift `Shared/Concurrency/MainActorNotifications.swift` | 非隔离 Sendable 接收入口先安全接住通知，带载荷时在原队列提取 Sendable 值（如 keys/reset）后再调用 MainActor 客户端（后台异步切主、已在主线程即时交付；Combine 则先 receive(on:)）；不可依赖继承 MainActor 的回调体内再检查线程。已有显式主队列 onReceive 与 actor 内 AsyncSequence 维持原交付；锁保护的同步缓存不迁到主线程 | 平台线程边界 |
| 书架状态、来源导航与文件任务协调 | Swift `Library/LibraryModel/LibraryModel.swift` 及 `+Navigation.swift` / `+Discovery.swift` / `+Reload.swift` / `+Imports.swift` / `+FileWork.swift` | 同一 MainActor model、同一存储和 generation；书架点击直接提交阅读目标，同一位置的快速连点不叠加阅读页；FileWork 统一拥有执行、等决定、等开书与结束四个阶段，任务与文件选择器各自保持原资源寿命 | 单一 owner |
| 单书会话、窗口与位置/lease 生命周期 | Swift `Reader/Session/ReaderSession/ReaderSession.swift` 及 `+Loading.swift` / `+Position.swift` / `+Preparation.swift` / `+Browsing.swift` / `+Continuation.swift` / `+Annotations.swift` | 导航后由会话拥有文件准备、进度、失败、重试及取消；AppDataService 协调并校验来源、交付 lease，旧请求不得接收迟到进度或 lease。开书请求、lease、窗口、离页进度由会话阶段配对；扉页与正文 0 分离；正文 frame 与来源、版本、范围及可用边缘配对。听书的播放与跟随独立，采用新位置仍走同一写入交还入口 | 单一 owner |
| AI 单会话执行、审批/取消与顺序持久化 | Swift `AI/Agent/AIAgentRuntime/AIAgentRuntime.swift` 及 `+Run.swift` / `+Persistence.swift` / `+Tools.swift` / `+Context.swift` | 同一 MainActor runtime 以事件游标、当前输出及独立发布阶段归并原 task、generation、审批与 persistenceTail；共享等待、推理和停止仍可与持久化交错，durable head 编码与提交顺序不变 | 单一执行 owner |
| 系统开书与未保存修改确认 | Swift `SystemReadingRouter`；dirty 权威为 `PaletteDraft` / `ChapterEditDraft` / `NoteEditorModel` | 普通面板不排队；比较草稿基线，保存中的请求即时提示并消费，不取消写入或排队；同一请求在解析、等确认及打开间转换；解析错误不离书，取消消费请求，晚到确认按请求 token 隔离 | 平台入口与草稿 owner |
| 固定阅读背景合成与原生/预览绘制 | Swift `ThemeSurface` / `ReadingPaperView` / `ReadingPreviewBackdrop` | 彩色 RGBA、固定 sRGB；图块/paper/blend/opacity 准备一次，原生与预览共用 ReadingPaperView/PreparedReadingPaper；尺寸只更新 descriptor 所定的贴边/靠角/cover CGRect；内层分页/滚动透明，不动正文布局或坐标 | 平台绘制 |
| 解码、normalization-v1、正文/原字节 SHA 计算 | Rust `reading/input/text.rs`、`identity/source.rs` 及正文导入共用核心 | 和正文缓存/稳定内容身份一致；Swift 不重算规范正文 | 保持 |
| fileId/bookId/canonical→正式或 pending 阅读键、索引有效性 | Swift `Data/Database/ReaderIndex.swift`、`IndexSources.swift`；Rust `identity/content.rs` 只校验 wire 键 | 当前作用域的导入别名、正文缓存及匹配文件版本的索引身份由同一 writer 维护；页面范围与完整副本裁决留 2c | 2b 写入与任务取数 |
| 待索引集合与书架索引 inventory | Swift `Data/Database/IndexSources.swift` | 同一库快照返回总量/pending；有效关系只认路径索引行当前编码、大小与修改时间 | 单一索引池 |
| 书架同步描述、本机授权绑定和扫描后准入 | Swift `ShelfRecovery.swift`、`UserSyncJSON.swift`、`FullIndex.swift` | SwiftData 裁决描述，本机 schemaVersion 1 绑定按账户隔离；平台扫描成功范围限制自动任务，不复制 Rust 查询 | 平台边界 |
| SHA 格式 | Rust `identity/content.rs::parse_sha256` | 身份及资产校验共享严格语法，语义字段仍区分 | 单源 |
| 查询输入范围与失效 | Swift `UserDataQuery.swift` / `UserDataStore+Projection.swift` / `UserData.swift` | 正式+pending（含 Rust `reading_scope_keys` 解析的旧别名）、字段依赖与按书 facts 在一个装配入口；全部、明确零本及不读取 facts 由各自范围类型表达；事务保存前按变更模型的书/领域阻断旧缓存；读取在同一 actor 提交/回滚后取值，成功后才发布数据变更；未知云导入全局失效；查询 owner 统一复核输入范围、身份与版本并在同一有效任务内补读，失效不向上抛取消；模型负责请求寿命及发布资格，真正取消不补读，真实错误不自动重试；Rust ReaderQuery 只做既有计算 | 单一查询 owner |
| 最近打开 | Swift `ReaderSession.bodyDidDisplay` 及 `UserDataService.recordBookOpened`，Rust `user/projection.rs` / `library/bookshelf` | 原生正文完成布局并到达显示时机后单次记录；UserValue `opened/<reading-key>` 的毫秒时间与位置独立，复用 LWW/备份/pending 晋升。Rust `library/bookshelf/recent.rs` 唯一决定排序与副本，旧数据缺值回退位置时间。冷首页和最近列表先读全域位置/打开时间，再按命中副本补作者、封面和章节；两阶段共同重验，不制造位置/计时交互 | 单一事实与排序 |
| 封面资源与静默替换 | Swift `Books/BookMetadata.swift` 的 `CoverResourceLoader`、`CoverImageLoader`、`BookCoverDisplay` | 独立资源 actor 统一 UI/Widget/Spotlight I/O 与派生；按作用域/资源/尺寸合并并有界缓存，ready 不随订阅销毁。同书旧图等新图成功，删除/换书/换账号立即清；系统文字更新复用图像输入版本 | 单一资源 owner |
| 默认阅读中状态 | 2c 固定查询待接 | 保留按正式 SHA 的位置事实（含无本机正文的已索引书）及显式状态优先规则 | 旧 Rust 查询已移除 |
| 文件夹列表的排序、计数与封面候选 | Rust `library/bookshelf`；Swift `UserDataQuery.swift` 组织输入 | 后代阅读活动只投影时间，由原封面规则选至多四个候选；opened 仅为保留参与的 pending 别名读取。直接书卡补位置、章节、作者与封面；封面专用键只补作者与封面。两步共用候选裁决与失效边界 | 单一目录规则 |
| 书目、搜索与筛选按用途取数 | Swift `UserDataQuery.swift` / `UserDataStore+Projection.swift` / `LibraryQueryRules.swift`；Rust `library/bookshelf/catalogue_cards.rs` | 名称书目与最近返回窄卡片，标签按文件 ID 引用单份卡片，筛选只取作者/标签；普通搜索按规则字段匹配再批量补命中卡片。AI 保留简介与正式库兼容检查。正式库按字段取；pending 的窄用途仍校验命中范围完整资料前缀，保留整对象覆盖而不把无关内容跨语言传输 | 共用字段依赖、匹配与发布边界 |
| AI 工具输入/schema/输出契约与执行 | Swift `AI/Tools/Reading/AIReadingToolContracts.swift` / `AIReadingTools.swift` | 只拆契约、执行和 `AppDataService+AIReading.swift` 平台适配的物理文件；引用、SHA、范围与搜索仍调用既有 owner | 单一执行 actor |
| AI b: 引用协议 | Swift `AI/Tools/Reading/AIReadingReferences.swift` | 工具协议只在 Swift；调用 Rust SHA 校验。外部字符串解码为书或文件引用，准备权限独立；共享准备由 AppDataService 持有，最后一个等待者释放工作 | 共享引用解析 |
| v2 导入、搜索、重建及计时纯计算 | Rust `reading/compute.rs`、`reading/input/text.rs`、`library/tools/search_compute.rs`、`user/statistics/mod.rs` | 每步消费前态。导入共享发布规范化与原文／正文 SHA；搜索按显式范围每步最多 50 条；章节复用发布扫描器。计时新接口拒绝单步超过一天；旧 Swift 计时调用尚未切换 | 正文三项已由 Swift 用显式票据调用 |
| v2 文件归属、连接池与本机归户 | Swift `Data/Database/DataSession.swift`、`LocalScopeImport.swift` | 唯一会话 owner 决定 `index.sqlite` 和所挂 `usr`；失去账户确认时仍可本机读写、不同步；明确登出使用 local。首次确认启用时冻结后合并目标证据，由目标同事务结算非事实当前值并写完成标记，成功后独立清理源；旧会话代次不得访问另一账户 | 本机归户和非事实结算已接；事实结算与运行时同步待接 |
| v2 pending 晋升与索引别名 | Swift `Data/Database/PendingUserPromotion.swift`，位置、打开和批注沿用各领域结算 | 同一 writer 核对当前作用域的已完成导入、可读 SHA、删除代次及未决别名的删除约束。只写 `usr`，候选晋升、重结当前位置/打开和批注 heads、pending 源删除同事务。确认用户提交或核实源为空后才能独立回收；重启重验仍有完成任务的索引 | 启动、导入收尾及索引回收已接；事实晋升仍走原 clear/证据路径，有效事实结算与同步待接 |
| v2 本机整书删除与迟到写入准入 | Swift `PendingUserPromotion.swift`、`ReadingDataManagement.swift`、`CacheManagement.swift` | 正式 SHA 与已核实别名只写 `usr` 一次；单删 pending 不扩为整书。删除时同事务为当时未确认身份的阅读任务记下别名与目标 SHA，晋升或显式丢弃别名后清掉，不约束未来导入；该约束随 D1 归户。保留全局清除、不明归属记录与源文件；封面只回收可证明无剩余引用的目标资产。提交后撤销本机代次，再独立回收安全别名、按选中的正式 SHA 尝试清理设备正文；保留活跃和任务保护，缓存未清不回滚用户删除。云端删除及出站裁决另接 | 晋升与打开/位置接入；其他 writer 随切换接入 |
| v2 打开、位置与本机续读基线 | Swift `ReadingPositionRows.swift`、`LocalReadingRows.swift`、`UserDataService.swift` | 阅读会话在开页时取得写票据；写者在 `usr` 提交前按索引当前书键复核。打开与位置是独立事实；位置沿用 UTF-8 边界，位置与本机基线同事务。隐藏和首选副本随相关动作更新；续读比较在同一读取周期取本机基线与正式胜出位置 | 位置/打开写入与续读依据已切换；阅读窗口及续读导航查询待接 |
| v2 批注与书签因果写入 | Swift `AnnotationRows.swift`、`UserDataValues.swift::AnnotationReduction` | 编辑包按重叠范围与合并关联扩展；普通写入只取代原基线，显式解冲突或批量选中删除重验候选 ID。候选、祖先、关联及旧内容压缩同事务，读取不改库。撤销基于自己的删除候选；未知候选按已知书/标记范围隔离；书签按书/偏移确定键。编辑、选择和撤销保留原票据，进入写者时复核 | 批注读写接关系库；正文摘录固定查询、页面观察与云同步待接 |
| v2 发布库结构迁入 | Swift `LegacyIndexImport`、`LegacyUserImport`；Rust `user/reading_fact.rs` 提供已解析事实列 | 用唯一 Swift pool 读旧索引 v20–23，校验后把完成标记写入副本；不读取私有 SwiftData SQLite schema。旧用户模型导入两个分区后结算非事实当前值，与证据及完成标记同事务 | 已接本机启动迁入；事实日量及消费者切换待接 |
| SwiftData LWW、候选裁决与事务 | Swift `Data/UserData/UserData.swift` 的 UserDataStore 及其 Values、Annotations、Statistics、Projection、Transfer 扩展 | SwiftData 保留原始事实；Swift 绑定外部行 id，按同库坏副本、首份、session/clear、日期的顺序裁决。正式选择先于 pending；两库不传播坏 id；原有合并及 ID 唯一规则是 2c 查询接入的兼容约束。原保存、回滚、清除范围与写入代次不变 | 单一事实权威 |
| 阅读事实 wire 与查询计算 | Rust `user/reading_fact.rs`（serde）、`user/statistics/`；Swift `UserSyncJSON.swift` 绑定行 id | 发布 wire 迁入和本机计时切片复用 Rust 的类型化列和时长派生；本机写入不构造整条 JSON，仅曝光数组随关系行保存。历史缺 v 可读，未知载荷保留；清除与候选裁决归 Swift | 已删 ReaderQuery/TEMP；窄事实读取待接 |
| v2 阅读事实写入与统计清除入口 | Swift `ReadingFactRows.swift`、`Statistics/ReadingStatistics.swift` | 采集入口保留开页票据，在用户闸门内重验账户、统计代次和书键。旧 fact 清除按范围时间或明确 ID，captured 只用明确成员；新段清除保留独立的已发生前缀证据。两者使用各自身份，不把旧事实合成新段 | 新结构已落地；生产采集、段清除及晋升尚待同事务接线 |
| v2 业务当前状态 | Swift `ReadingPositionRows.settleCurrent`、`CurrentUserRows`、`AnnotationRows.settleHeads` | 在证据的同一事务结算受影响的键；领域各自决定隔离范围和来源。位置保持跨分区未知阻断，打开只略过不可读分区；章节按分区裁决后由有效 pending 覆盖；解码、配色和书架引用只读 formal，坏引用不阻断正常提示。资料与标签采用同一胜出对象来源，批注复用因果 reduction 并保留并发及删除 head。整书删除同步清本书当前引用；候选引用在提交时检查 | 迁入、归户、位置/打开、批注、pending 晋升和整书删除已接；其他本机写入和 current 消费者待切换 |
| 连续段采集与载荷 | Rust `user/statistics/segments.rs`，两套采集共用 `ReadingTiming` 计费 | Swift 提供时间、ID 种子及采集作者，Rust 消耗前态，独立返回本步计费和累计快照；15 秒检查点不换 ID，真正边界才封段。Rust 负责版本、完整前缀比较、精确裁剪及基于上次快照补封；书身份与本机补封资格由 Swift 复核 | 纯计算及绑定已验证，App 仍未切采集或出站 |
| v2 有效阅读事实与书日量 | Swift `ReadingFactSettlement`、`ReadingDayRows`；Rust 计算事实时长和段有效头 | 候选归属、隔离和来源清除在确定当前贡献前判断；历史 fact 和新段分别引用对应证据。书日量只用一套有检查的 UInt64 差额；极值只回查相应桶内两类窄头，封段状态变化不重复计时；覆盖按需计算 | legacy 结算与共享日量已有；新段 writer、清除与读者待接 |
| 相对路径语法、组件边界匹配、名称合法性 | Rust `storage/validation.rs`，bookshelf 委托 | 索引和真实操作都需要相同底线；具名 profile 保留入口差异 | 共享路径校验 |
| 表单 TXT 后缀补全、AI stem trim/保留扩展名 | Swift `LibraryActions.swift`、`AI/Data/Proposals/AIProposals.swift`，分别为两条不同规则 | 各自单源、不同输入契约，不为统一语言迁移 | 原位保留，只调用合法性 owner |
| source hint 字节/字段限制；恢复候选优先级与下载限额 | Swift `Data/UserData/UserDataValues.swift::PositionSourceHint`、`RecentReadingRestoration.swift::RecentRestorationPolicy` | 同步载荷与恢复行为专用且已经单源；共享路径语法调用 Rust | 共享路径语法 |
| symlink/授权/provider 生命周期、真实文件 IO | Swift `LibraryService.swift`、ShareReceiveShared | 平台安全事实，Rust 字符串校验不能替代 | 保持 |
| 分享扩展入站安全校验 | Swift `ios/ShareReceiveShared/ShareInbox.swift` | 独立进程不依赖 Rust，属于明确防御性例外 | 保留，共同 fixture 对齐公共规则 |
| 系统元数据匹配 | Swift 共享 `LibraryQueryRules.systemMetadataBooks` | 共享书名、作者、标签、书名/作者的有效分词与拼音全拼/首字母；去空白、去重、最多64项，不生成前缀碎片或单字分词。Entity 用该词表做部分/拼音匹配，Spotlight 匹配与展示由系统负责；复用 Rust ordinal，不带 AI 简介 profile | 具名契约 |
| 系统书目派生快照与统一开书路由 | Swift `SystemIntegration`、`SystemIntegrationShared` | SystemReadingCatalog 是全库书目、最近项、曝光策略与失效的主 App 唯一生产者；共享 DTO 不含正文、路径、位置 token/偏移，不成为事实权威。身份、代表副本、顺序与进度沿既有 Rust 查询；SystemReadingRouter 统一开书，扩展不读正文或事实库，统计回答调用既有主 App 查询 | 平台边界 |
| AI 目录来源、字段与连接预算 | Swift `AIModelDirectoryPolicy` / `AIModelDirectoryDecoder` / `AIModelCatalog.option/resolve`，`AIConnectionService` 编排刷新 | A/S 完整结果决定自动发现集合，首次失败空列表；P 仅精确补已有型号规格，只有 metadata-only 预设用 P 生成列表，显式 false 不覆盖成 true；M 保留预算并与连接明确上限取小值；ChatGPT 独立。目录缓存不进 CloudKit；无来源的旧目录与已取回快照分开，授权与目录失败独立，Keychain 编码保持旧字段；用途与端点适配仍由 `AINativeCapabilities` 单源判断，见[模型目录](../ai/model-catalog.md) | 单源解析与裁决 |
| AI 连接余额与额度 | Swift `AIConnectionUsageService` / `AIUsageAdapter` | 查询能力、官方端点及字段语义由 adapter 单源决定；usage service 独占详情访问、刷新、快照、冷却和迟到响应校验。凭据、代际及网络准入继续由 `AIConnectionService` / `AIAvailability` 管理；列表不触发查询，快照只在内存。见[连接余额与额度](../ai/providers.md#连接余额与额度) | 单一查询 owner |
| 查询范围、身份/metadata 关联、目录后代最近时间、最近副本选择 | 2c Swift 固定查询 | 数据库事实需要完整范围；不能从限量 recents 反推目录，不复建旧 TEMP 或通用查询门面 | 旧 Rust 查询已移除 |
| 书目文本/作者/标签/状态筛选、搜索排名和建议匹配 | Swift `LibraryQueryRules`（`Library/Search/LibraryQueryRules.swift` 与共享系统元数据 profile） | 条件树区分组与对应类型的谓词，只在搜索会话内存在；三值求值、无标签、自定义多键排序与摘要使用同一查询；书架书名/作者的全拼与首字母复用共享 `pinyinSpellings`，与 Entity/Spotlight 使用同一系统默认普通话转写，不加词典或 Rust 副本；UI 原文匹配与 AI/建议模式显式保留，64 项上限仅属于系统词表 | 单源匹配与排序 |
| 文件自然比较、目录/全书/标签自然排序 | Rust `library/order.rs`（从 bookshelf 提取） | 已服务 SQL 查询和目录；按完整快照一次计算 | Swift 搜索使用批量 ordinal 和同名分档，不复制自然 comparator |
| 搜索排名组合、AI 名称字典序/recent 平手顺序 | Swift `LibraryQueryRules.swift` | 与匹配结果一同完成，AI 原生字符串比较不迁语言 | 单源组合排序 |
| 拼音 key、字母分组及组内 localized collation | Swift `LibraryPresentation.swift::LibraryNameGroup` | 唯一实现且依赖 Foundation；不是原文件自然序副本 | 原位保留 |
| 多标签分组/未标注/未索引分区 | 2c 固定查询待接 | 按同一个索引身份分组，每个文件可属于多个标签 | 旧 Rust 查询已移除 |
| 目录四封面选择 | 2c 固定查询待接 | 独立 top-4 策略，不等于目录列表顺序 | 旧 Rust 查询已移除 |
| 字数定义与 UTF-8 前缀累计字数 | Rust 文本计数共用 helper（后续）；当前 reading/chapters、identity/source、reading/navigation 和 user/coverage | 与导入字数、章节/覆盖分母一致 | 不在 #66 改写；旧报告第8项仍待收敛 |
| 字节位置→进度比例、百分比跳转 | Rust `reading/navigation.rs::reading_percentage`，阅读数据通过 `identity/content.rs::reading_data_percentage` 查询可信全文长度 | 阅读数据与跳转共用比例/边界计算；Swift 只本地化格式化 | 其余旧报告第9项 Swift 比例副本仍待处理 |
| 有效章节/位置归属 | Swift `IndexTasks.swift` 持有自动章节重建；2c 负责有效章节查询 | 同一书的手动目录覆盖须对导航、查找和统计一致；搜索计算接收冻结标题 | 旧 Rust SQL 已移除 |
| 文件目录类别、平台书架来源 | Swift `LibraryService` 与 `IndexSources` | 平台协调真实树和授权；Swift writer 对已准入扫描做一次事务，并保留失败范围最后清单 | 页面条目形状留 2c |
| 正文准备、目录覆盖与笔记选择 | Swift `IndexImport`、`IndexTasks`、`AppDataService` 与 `ReaderToolsModel` | 保留已提交前缀，提交失败丢弃 Rust 后继并从字节零重验；Swift 持有章节暂存，验证原正文再原子发布 | 窗口、覆盖等有效页面读法留 2c |
| 资料状态与统计范围 | Rust `reading/book_details.rs`，Swift `BookInformationModel` / `StatisticsModel` | 资料可无正文，未识别文件保留同一查询入口；详情来源沿指定文件，记录回退只在目标身份的文件中按目录阅读顺序选，不重复取资料和章；统计按目标和日期范围加载，首屏与累计详情独立，缓存按输入版本复用 | 同一身份查询链 |
| 数据管理操作与全量索引 | Swift `DataManagementModel` / `FullIndexController` | 列表加载与备份或删除分开；索引阶段与后台 runner 资源分开，暂停可先于 runner 退出。沿用已发布索引意图和备份编码 | 现有服务及资源 |
| 云激活、原生发现及文件交接 | Swift `CloudSyncCoordinator` / `UserDataService` / `CloudDocumentQuery` / `CloudDocumentHandoff` | 意图与账户激活分开，过期回调不发布；交接状态只在边界转为旧回执字段，异常组合没有删源资格 | 旧格式原样 |
| 正文智能缩进前缀 | Rust `reading/layout.rs::reading_indent_omissions` | 按真实段首与段落语义返回横向空白的运行时源范围，显示与选区摘录共用；Swift ReadingText 只映射省略区间，ReadingTypography 用字体度量设置两字几何。原文模式、标题、列表、续段不变，不写原件、SHA 或位置 | 显示投影 |
| 自动阅读偏好与计时例外 | Rust `reading/layout.rs::auto_reading_control` / `user/statistics/mod.rs::ReadingClock` | Rust 定义1–30档／默认10及指数 em/min 映射，Swift 经 ReaderSettingsStore 保存本机档位，按实际文本容器／缩放字体／正文行高换算位移；Swift 原生帧驱动只提供真实位移时间，Rust 单源裁决时长，不模拟手动 interaction |
| 自动阅读运行、打断与原生位移 | Swift `ReaderAutoReading` / `ReadingController` / `ReaderDeviceControls` | 同一附件与显式继续，使用原文位置／预取／有界检查点入口；复用统计可读性事实，临时常亮合并原 lease，不持久化运行状态 |
| 听书播放、跟随与瞬时高亮 | Swift `Reader/Session/Listening/`、`ReaderSession+Listening`、`ReadingController+Listening` / `ReadingLayoutManager` | AVSpeech/Now Playing 的单一 Session 控制播放；既有 TextCoordinates 映射语音范围，音频锚点与内存浏览分离，渲染只画临时范围；正文/规范化和统计规则仍归 Rust | 不新增位置、CloudKit、备份字段；声音不计阅读统计 |
| 阅读工具意图、关闭与输入 | Swift `ReaderToolSession` / `ReaderPresentationHost`、`ReaderBottomPanel` | ReaderSession 每次打开持有一个工具 owner。工具通过带 opening、访问 ID 和版本的动作修改 SurfaceIntent；根工具关闭统一从当前有效会话裁决恢复。宿主只记录物理安装和对应快照，同一快照驱动内容与真实页脚；旧回调只能释放原安装 | 不改公共导航、正文容量或存储 |
| 阅读执行、搜索与听书门禁 | Swift `ReaderExecution`（由 `ReaderSession` 持有）、`ReaderToolsModel`、`ReaderToolSession` / 原生呈现适配 | ReaderExecution 只持有当前执行主体，搜索任务独立于收起或展开；ReaderToolSession 从位置动作、选区和实际原生层的来源裁决一次播放资格。统计和自动阅读继续按正文可读性独立判断 | 均为会话状态；不持久化 |
| 阅读时长/有效天数/覆盖等统计数值 | Rust `user/statistics/mod.rs`、`user/statistics/coverage.rs`（后续统一 summary） | 事实聚合按固定 local_day；Swift 不再另 reduce 同一总量 | #66 不迁；旧报告第11项仍登记 |
| 目录结构与覆盖加载 | Rust `library/tools/catalogue.rs` 共用章节装配，`user/statistics/coverage.rs` 批量映射覆盖端点；Swift `ReaderToolsModel` 分两阶段发布 | 结构不读 facts；覆盖沿用同一查询失效规则，后台补齐不改变筛选/滚动，取消随目录 owner | 无新增持久缓存或事实格式 |
| 目录/临时跳转与正式续读保存 | Swift `ReaderSession`、`ReaderToolsModel` / Rust `ReadingFrame` | 目录断 visit 并 enqueue，不等统计 writer drain、不预读笔记；跳转 frame/章节标题在 Rust 同一读取事务中返回并一起发布；临时原点只在会话内存，原已接受保存走现有 saveTask；明确采用浏览位置或同步进度共用位置交还，结束听书后提交新位置，旧 flush 不得回写旧位置 | 不改正式位置格式 |
| 统计范围结果与读取状态 | Swift `Statistics/StatisticsModels.swift::StatisticsModel` | 日期边界／书籍身份／用途作查询键，复用结果和在途读取；已知变更按书使结果过期，同 scope 保留旧内容直到成功替换，真正清除/未知导入撤下旧数；页面关闭取消查询，迟到结果不回填。单书先发布期间统计，累计与时段按同一事实版本补齐，视图只消费状态，Rust 聚合与持久化不变 | 平台查询状态 |
| 系统统计摘要与连续日 | Rust `user/statistics/mod.rs` | 复用有效日汇总与清除投影；今天未读则截至昨天，不限七天。Swift 只处理 Calendar 和展示，Widget 不读事实库 | 单源 |
| 同步位置领先阈值、有效章节与百分比 | Rust `reading/navigation.rs` / `ReaderQuery` | Swift 只持有冷启动本机基线与提示状态，不重算领先裁决；见[同步设计](../data/sync.md#13-同步进度与编码) | 单源 |
| 手选编码 LWW 与升级 epoch 候选 | Swift `UserValueRows` / `UserSyncJSON`，`SourceDecodingPreferences` 编排 | rawSHA 和编码规范调用 Rust；formal 候选与 current 同提交，旧索引迁入任务在用户提交成功后才另行确认。开书、索引与 AI 读取 current 与同域隔离，无旧本机回退 | 本机事实裁决；CKSyncEngine 待接 |
| 章节修正、配色与书架引用写入 | Swift `UserValueRows`、`CurrentUserRows` | 章节编辑按原正文行边界校验，撤回保留候选；配色与其颜色关系、完整当前 Ref 同提交；书架引用只发布描述，与本机授权分离。三个全局域的 formal 读取仍按各自隔离规则 | 已接本机 writer；章节结构消费者另批切换 |
| 统计总览总时长 | Rust `user/statistics/mod.rs::statistics_overview` | 与已投影书目一次计算为只读 DTO 字段，App 总览和 Siri 直接读取，不来回搬运整个列表重复求和 | 单源 |
| 统计事实保存/去重裁决、日历展示桶/连续行视觉合并、显示格式 | Swift `ReadingStatistics.swift`、`StatisticsView.swift`，按各自职责单源 | 写入/界面组织与 Rust 数值汇总是不同规则；展示合并应消费已算 duration | 保持平台/状态规则，数值副本后续删除 |
| 备份 ZIP 布局、受限解包、路径/摘要与正文缓存 SQL 驱逐 | Rust `storage/maintenance/backup_archive.rs` 管 ZIP；Swift `ReaderIndex` 管缓存驱逐 | 缓存驱逐使用同一个 GRDB 池，保留索引/授权/任务 | 单源 |
| 来源栈 Tab 显隐 | Swift `LibrarySourceTabVisibility` | 按该栈路径中的阅读器及当前叶子目录的选择 preference 统一判定；目录只上报选择位置，不另提交相反显隐策略，不持久化全局选择标志 | 单一 owner |
| 笔记快照与可读导出 | Swift `NoteDocument.swift`、`UserDataStore.noteCandidates` | 三入口共用摘录/出处与 TXT/Markdown 输出；快照不压缩候选，未知记录按范围阻止不完整导出，位置/章节/百分比复用 Rust | 不增同步格式 |
| 用户备份 envelope、非事实恢复、对象级删除 | Swift `UserDataBackup.swift`、`ReadingDataManagement.swift` | 归档核验和字节准备先于写事务；恢复以 v1 候选及附件为输入，通过各领域同事务更新 current，不把派生值作为备份权威。整书删除无本机删除回执或启动补删 | 非事实恢复已接；事实/clear 等连续段，完整备份导出另批接入 |
| 受保护来源的 bookmark 解析、安全作用域、协调读取与物理路径边界 | Swift `Data/Sources/ProtectedFileAccess.swift` | 开书、导入、索引、恢复、缓存和备份共用；沿用 `.withoutUI` 与可解析的陈旧书签，不增加拒绝条件；作用域覆盖各阶段，accessor 内不等待 actor | 平台边界 |
| 本机来源下载可用性与目录发布 | Swift `AppDataService.prepareSourceFile`、`LibraryService`、`IndexSources` | 协调访问成功后只改同位置现有行；旧源准入复核及通知由服务负责 | 唯一索引 writer |
| 缓存来源可读性证明与清理准入 | Swift `CacheManagement.swift` | 借用公共文件访问组件，证明期内调用 Rust 重验事务；页面不判断可清性 | 平台边界 |

维护约定：新增规则先查本表；已存在则调用 owner。新增或改变归属必须在同一 PR 更新表、实现入口及测试位置。两个策略若故意不同，命名其输入/输出契约；不能仅以语言或调用入口不同为理由再实现一份。


备份容器布局、受限解包与路径/摘要验证由 Rust `storage/maintenance/backup_archive.rs` 负责；用户备份 envelope 和非事实接入由 Swift `UserDataBackup.swift` 调用各领域关系 writer。`ReadingDataManagement.swift` 只编排本机事务交接，`ProtectedFileAccess.swift` 负责 bookmark、安全作用域和协调读取；`CacheManagement.swift` 保留清理准入与可读性证明；页面不实现另一份身份、排序或合并规则。数据管理列表的自然顺序调用 Rust `reading_data_order`，本地化文本匹配复用 `LibraryQueryRules`。

## Rust 源码目录

`crates/moonread-core/src/lib.rs` 仅声明领域模块、重导出现有 API 和注册 UniFFI scaffolding。模块移动不改变规则 owner、导出名称、签名、正文身份或持久化格式；跨实现模块需要的 `pub(crate)` / `pub(super)` 只表达原先 crate 根及父模块已有的内部访问范围，不增加对外 API。

| 目录 / 入口 | 职责 |
| --- | --- |
| `core.rs`、`error.rs` | 正文交换值、共享错误与已发布导入错误格式 |
| `library/` | `bookshelf/` 分查询、mutations、source、full_index（及原 SQL）和测试；order 保留独立入口；`tools/mod.rs` 保存原 DTO/导出，text 处理文本范围与段落，search 持有搜索对象和状态，catalogue 装配章节及内部共享查询 |
| `identity/` | content 阅读键与文件关联、source 原件探测/解码策略、sha |
| `reading/` | `input/` 汇集 ingest 事务正文导入与 text 解码/分块；chapters 扫描、navigation、layout、cover_page、book_details 保留独立入口 |
| `reading/progressive/` | 任务类型与状态入口；tasks 生命周期、stream 前缀分块、recovery 恢复/回收、query 不可变读取、原有测试 |
| `user/` | `reading_fact.rs` 负责阅读事实载荷校验和编解码，`projection.rs` 负责查询投影；`statistics/` 保留计时/聚合入口和 coverage；`themes/` 中 models、preferences、textures、palettes、resolve 分别保留类型、偏好迁移、正式图案、配色/对比度及校验解析，父模块重导出原 API；SwiftData 继续是用户事实权威 |
| `storage/` | 原 schema.sql、migrations、validation、rows 正文缓存 SQL 行映射；`maintenance/` 汇集 backup_archive 与 cache_management，父模块重导出原 API |

SQL 内容、迁移顺序和调用时序保持原样；仅按新目录调整 `include_str!` 路径。章节和渐进准备的既有测试随实现移动，不复制测试或规则。

## Swift 源码目录

`ios/Moonread` 的真实目录与 Xcode groups 对应。此次整理改善源码导航与文件职责，沿用现有状态 owner、actor 隔离、任务生命周期、存储和接口；没有隔离共享 actor，也没有改变 JSON 投影的类型契约。

| 目录 | 文件职责与保留边界 |
| --- | --- |
| `App` | 应用入口和 `MoonreadDelegate`；App 继续持有同一个 `CloudStore` |
| `Library` | `LibraryModel/` 中 `LibraryModel.swift` 保留原存储和初始化，Navigation/Discovery/Reload/Imports/FileWork 同类型扩展分职责；`LibraryRoutes.swift` 保留原路由与首页快照值；`Browsing/` 保存首页、全部小说、文件夹、最近阅读及行/原生集合；`FileOperations/` 保存文件动作、drop 与独立 `LibraryExport.swift` 暂存生命周期，`Search/` 保存查询/筛选/排序，`Sources/` 保存真实目录、云文件与协调访问，`LibraryDirectoryObserver.swift` 只承载原文件呈现回调，`Indexing/` 和 `Recovery/` 保存索引/恢复及各自本地化；管理页保持入口，状态/绑定及层级不变；封面由 `Books/BookMetadata.swift` 的 `BookCoverView` 接入既有图片加载器；`Fixtures/LibraryUIFixtures.swift`、`LibraryStoreShotFixtures.swift` 与 `StoreScreenshotFixture.swift` 汇集 DEBUG/测试合成输入，target membership、隔离目录及初始化顺序不变 |
| `Reader/Session` | `ReaderSession/` 中 `ReaderSession.swift` 保留原存储、init、open/leave；Loading、Position、Preparation、Browsing、Continuation、Annotations 为同一类型的领域扩展，完整保留现有会话 owner；`Opening/` 汇集开书协调与已有诊断入口，ReaderAutoReading 保持会话级入口 |
| `Reader/UI` | `ReaderScreen/` 中 `ReaderScreen` 保留全部私有 State、会话生命周期和导航/原生呈现协调；Content/Controls 扩展使用同一 View 的只读引用/值访问口组合原内容，不引入宿主或副本状态；`Presentation/` 汇集原生呈现、来源导航及工具会话；`Controls/` 保存顶部提示、附件内容与更多操作，`Chapters/`、`Notes/` 保存目录与笔记，`Tools/` 保存工具 model/标签，`Search/` 保存完整原生搜索页和紧凑续搜入口；目录在 `Chapters/` 使用系统 List/DisclosureGroup/searchable 和独立惰性行，读取同一轻量快照；偏移 ID 由 ForEach 提供，仅当前章可见性回写页面；原意图路径、绑定和视图层级不变 |
| `Reader/Rendering` | `ReadingView` 是 SwiftUI 适配入口；`ReadingController/` 汇集原控制器及 Pages/Scroll/Navigation/Selection 扩展，`Pages/` 保存叶页/扉页控制器，`Text/` 保存排版装配、坐标、原生正文与背景；ReadingPagination、ReadingViewport 和设备控制保留原入口/owner |
| `Books` | 小说详情与完整 `BookMetadata`；封面展示、加载及服务私有辅助保留原文件边界 |
| `Statistics` | `StatisticsView` 保留总览/单书详情的状态和路由；models、书目列表与统计设置保留入口，`Charts/` 汇集时长条/节奏/时段图，`Details/` 保存日期与时段详情；`ReadingStatistics` 的 writer、recorder 与日期辅助保持原 owner |
| `Settings` | `SettingsView` 只保留首页与私有入口辅助；`Reading/` 汇集阅读偏好、唯一 store/缓存与预览，`Reading/Fonts/` 保存系统/导入字体；`Appearance/` 汇集应用外观与配色选择/预览/编辑，`Cloud/` 汇集云设置和状态，`About/` 汇集关于及许可；`DataManagement/` 按现有类型分别保存唯一 `DataManagementModel`、根页、阅读数据列表及待处理页，根页保留缓存／备份小视图；专题入口和原 owner 不变 |
| `Data` | `AppDataService`、SwiftData 用户数据及同步协调；`UserData/` 中 UserDataModels/UserDataValues 保留原模型与载荷，UserDataStore 的事务/存储留在同目录 UserData.swift，Values/Annotations/Statistics/Projection/Transfer 只物理拆分方法；UserDataService/Backup/SyncJSON/Themes 归入同目录，`Cloud/` 汇集云同步，`Restoration/` 汇集续读恢复，`Management/` 汇集备份/缓存编排，`Sources/` 汇集受保护访问与编码解析；正文准备、导入、云目录 owner 与紧耦合私有类型仍在 `AppDataService` |
| `SystemIntegration` / `SystemIntegrationShared` | 主 App 派生快照、系统入口路由与平台更新；共享部分只有稳定链接、只读 DTO、最小 Entity/配置与无状态文字卡片。Widget/Control 目标不含数据库/正文服务；任意队列系统回调显式 nonisolated / @Sendable 后再交接 |
| `Shared` | `Theme`、`MoonView`/`MoonCharacter`/`BrandSeal`、输入焦点及跨功能错误文案 `ReaderMessages` |
| `AI` | 保持现有分层；`Agent/AIAgentRuntime/` 下 AIAgentRuntime 与 Run/Persistence/Tools/Context 扩展共用原执行状态；`Tools/Reading/` 汇集原契约 DTO、唯一 AIReadingTools actor 和 AppDataService 平台适配，`Tools/Proposals/` 保存审批动作；`UI` 下 Conversations/Tasks/Reading/Settings 分别组织对话、任务、阅读入口和共享模型选择；Conversations 中 `AIToolPresentation.swift` 保留唯一的工具名称/图标/摘要/状态映射；列表、`AIChatView.swift`、`AIComposer.swift`、`AIReadingAttachmentPreview.swift` 按原类型分文件，Settings 中 `AIModelDetailView.swift`／`AIThinkingSlider.swift` 保留既有详情与思考控件，快速页 presentation owner 不变；`Data` 下 Conversations/Proposals 归拢对应值，`Providers/Connections/` 归拢连接/认证；资源与签名配置路径保持原位 |

`ios/MoonreadTests` 按 Library、Reader、Data、Settings、Statistics、Platform 与已有 AI 归目录，AI 夹具在 `Fixtures/AI/`；会话支撑留在 `ConversationTestFixtures.swift`，会话网络协议及共享状态、连接/认证协议与店面查询、原生事务 fixture 分别位于 `AIConversationProtocolFixtures.swift`、`AIConnectionFixtures.swift`、`AINativeToolsFixture.swift`；类/方法名和测试发现保持，UITests/TestPlan/scheme 入口不变。

`ios/MoonreadShare` 是独立分享扩展 target，只负责接收与取消。`ios/ShareReceiveShared` 同时编译进主 App 与扩展，提供版本化 ShareInbox、原字节复制和 provider 生命周期适配；不依赖主 App 的 Rust、SwiftData、AI 或阅读 UI。App Group 只共享待导入原件，主 App 继续独占书架写入和正文准备。

拆分保留现有类型、状态 owner 和 actor 隔离；SwiftUI 的 `@State` / `@FocusState` 留在原父视图，目录子视图只接收 Binding 和回调。UIKit 控制器跨文件扩展共用状态与方法时，仅将必要成员调整为模块内访问，其余保持 private，不增加 public API。原有 Sources UUID 与 target membership 保留，新增拆分文件显式加入应用 target。设置和统计按完整 View/model 类型移动，原有私有状态和 actor 标注保持；共享的页面与图表 helper 只在必要时由文件私有调整为模块内访问。

`AppDataService` 当前协调小说来源、Swift 索引与 Rust 正文计算、用户阅读数据、配色与同步，不仅服务阅读页；`ReaderSession` 才是阅读会话状态 owner。其扩展已随领域位于 Library、Books、Statistics 和 AI，Data 保存用户事实、备份/缓存及同步协调。名称仍为 `AppDataService`，领域扩展共用同一 actor 的串行边界；文件目录不改变数据权威和存储归属。

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

主题类型与解析分工见[主题模型](../design/themes.md)：Rust 管理配色校验和继承计算；SwiftData 保存配色方案本体，UserDefaults 保存各设备的显示选择与首帧快照；平台负责语义颜色和渲染。

文件定位与正文关联实现见[关联交接](../data/README.md#文件定位与-sha-关联)。保留 SHA、现有存储职责和规则归属边界；交接发布关联必须先于扫描，外部修改重新核验。SQLite 事务同时发布最后已知关联与固定根，平台记录保护复制和清理之间的中断重试；临时任务不作为已完成快开缓存。

## 持久化

当前表、schema 版本、文件位置、目录授权与首帧快照统一列在[当前实际存储](../data/README.md#当前实际存储)，不在多份文档重复维护表清单。

SwiftData 是用户数据权威来源。Swift 正文库与旧用户权威各自提交；旧 ReaderQuery 和 TEMP 已退场，固定页面查询与新用户表写入留 2c。所有书架是统一真实目录：云端 TXT 与目录结构交给 iCloud Documents，用户可从系统文件工具直接整理；CloudKit 只同步阅读数据与配色方案，不镜像书架文件清单或原文。运行中的 SQLite 不放进云文件夹。职责与冲突规则见[同步设计](../data/sync.md)。

## 持久化演进与发布兼容

兼容只对照已发布给用户的版本（main，或已提审且会先上架的构建）。release 分支开发中的中间结构不做兼容和迁移，可直接修改；未发布的新结构（如小组件标识、共享快照字段）直接按最终形状写。检查时对照基线提交 diff 持久化与共享结构；设计文档讨论兼容时须注明基线版本。

从 1.0.0 发布基线开始，SQLite、SwiftData/CloudKit、UserDefaults、Keychain、同步 payload 与缓存的格式变更必须保持已有数据可读。持久化枚举只增加、不删除或更改已有 raw value；退役功能可停止展示，不能用未知值使整个集合读取失败。新增字段使用可选值或明确默认值；结构调整须带版本、升级路径与迁移测试（旧数据、重复打开、失败回滚、降级拒绝），不能以删除重装代替升级。内部非持久化接口仍可直接整理，不要求保留无用的重复实现。

SQLite 以 `user_version=20` 为首次支持基线，`storage/migrations.rs` 按有序步骤升级。新库先事务创建 v20，再与已有库一样逐级升级；v21 为导入任务增加目的字段，既有任务默认 reading，恢复专用任务为 restoration；v22 增加全量索引数据；v23 一次登记旧手选编码待迁项，原件未就绪时保留，SwiftData epoch 候选保存后才确认完成。当前版本为23。每步成功后更新版本，失败回滚该步。高于当前版本明确提示更新应用；低于 20 的开发库无升级路径，保留原库并报不支持，不自动删除或重建。哪些是可重建派生数据、哪些必须保留，见[数据存储](../data/README.md#当前实际存储)。

`Data/v2` 的 `index.sqlite` 和 `user.sqlite` 各有独立 v1 版本；遇到较新版本不覆盖。索引迁入器只读接入旧 v20–23 的文件、保留旧源，复用发布 SQL 形状并在目标事务内核对行键、关系及字节。用户数据迁入通过 SwiftData 发布模型读取，结构迁入完成标记不等于已满足云附件和切换门槛。账户 local 并入先提交目标用户文件，续做需要的索引任务归属更新，再清冻结源；三个文件写入各自提交，不依赖 ATTACH/WAL 跨库原子性。应用一版合并切换运行时权威前，不启动 v2 页面读取、双写或新同步。

AI 连接、共享授权、用途默认值逐条解码，失败条目跳过并记录不含正文/凭据的日志；会话列表逐行容错，存储读取错误仍向上抛出。读取不修复、不回写。显式保存时按稳定 ID/用途键更新可识别项，保留不可识别的原始 JSON 元素与未知对象字段；用户可删除可识别项，不能顺带删掉未知项。JSON 整体损坏时拒绝覆盖并报告失败。用途字典既读取此前 Codable 的键值交替数组，也读取对象，显式保存统一为字符串键对象。授权撤销另更新连接 generation，保留的未知授权不能绕过该边界；日志只记录集合键和序号。同步 payload 采用独立的版本/隔离契约，见[同步专题](../data/sync.md#同步-payload-的-v1-边界与隔离)。

`readingSettingsTab` 的发布取值固定为 `typography`、`colors`、`controls`，标题另行本地化；按发布前决定，旧开发中文取值不迁移，回到默认排版页。已识别对象内的数组字段按当前编辑值保存，不将这项容错措施宣称为任意嵌套协议的无损回放。

正文身份 `content_sha256` 的 normalization-v1 是稳定契约。已经支持的文件，其解码策略与规范化结果不得因依赖更新、算法整理而静默改变；若确需变更，须保留原键到新键的映射与所有进度/标记关联，并测试旧文件解码和旧键恢复。缓存可版本失效重建，但不得连带抛弃授权、解码选择、任务暂存或用户记录。

1.6 的最近打开复用既有 UserValue v1 envelope 和 LWW，新增可缺省的 `opened/<reading-key>` 值（JSON Int64 毫秒）；缺失不伪造，排序回退已发布 1.5 的位置时间。既有 SwiftData 模型、CloudKit schema、位置和备份容器格式不变；完整备份包含此值，pending 晋升和按书删除沿原入口处理。旧版可保留未知键，1.6 能读取原有 1.5 数据；没有开发中间态迁移。

SwiftData 变更使用可验证的 schema 演进/迁移。1.0.0 的阅读数据库与 AI 会话库没有使用 `VersionedSchema`。1.0.0 之后第一次修改任一库的模型（包括只加可选字段的轻量变更）时引入版本化：1.0.0 的现有模型原样作为 `SchemaV1`，新模型为 `SchemaV2`，加 `SchemaMigrationPlan` 与旧库升级测试；此后每个发布过的 schema 都保留一个版本，轻量变更用 lightweight stage，不能只登记首尾两端。CloudKit 生产 schema 只增加字段/记录类型，不删改既有类型及字段语义。UserDefaults/Keychain 的键名与凭据编码属于数据契约，变更需迁移且不得落入日志。阅读事实 payload 由 Rust 类型化校验，其他同步 payload 由 Swift 校验；Swift 存储边界按作用域隔离未知内容，不能靠 JSON 字段保留代替 LWW 并发设计；详见同步专题。

重置仅限当轮明确授权的开发数据，不是发布后错误恢复方式；不得删除用户的外部或 iCloud 小说原件。上述约定不改变[iOS 版本和 API 兼容策略](ios-support.md)。

## 技术参考

- [UniFFI](https://mozilla.github.io/uniffi-rs/next/)
- [Apple 目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、[文件协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [TextKit 2 能力介绍](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [SQLite 备份与运行中数据库](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)

## 正文接口与业务查询归属

2b 已移除 Rust `ReaderCore`、`ReaderQuery` 及正文库的 SQL/迁移。Swift `DataSession` 按当前作用域独占 `Data/v2/index.sqlite`，挂载对应 `usr`；来源扫描、解码策略、导入、章节暂存、搜索和缓存驱逐共用这一池。慢速文件协调和 Rust 计算在数据库闭包外。资料包的私有暂存 `inspection.sqlite` 和归档文件 I/O 仍在 Rust，计划在 2c 之后、新同步之前迁到 Swift。

导入从实际 EOF 或 64 KiB 加一字节识别编码，每步最多读 8192 个新字节。中止后新建 Rust 状态，从头读并按连续窗口验证至多 16 个既有块。允许有界合并多步输出；只有提交才推进已发布进度，提交失败丢弃整批未提交输出和工作状态。2b 仍在每个产出步骤后提交。若连失败或暂停状态也写不进去，Swift 在当前 lease、书 ID 与代次内保留终态；下一代任务或切换会话不继承旧终态。章节暂存到最终 apply 才替换正式内容。

2c 的用户库准备先由 writer 校验两个版本、配置 `usr` 的 WAL，再开放连接池的读侧，以便已存在的索引能安全换绑新账户。迁入已知归属的旧用户源时禁写、禁 CloudKit；成功写入完成标记后才开放新关系表。关系表的打开记录和位置是不同事实，按领域、书键和分区复用隔离屏障；位置可与隐藏、首选副本和续读基线同事务提交。含 `usr` 的 GRDB 观察在 writer 上串行读取初值并注册，因为连接池并发观察只比较 `main` 的 WAL；重取也占 writer，耗时计算留在查询闭包外。store 仍需在参数或账户变化时取消并丢弃迟到结果。

2c 接 B 固定直查函数与本机用户数据写入。既有 SwiftData 选择规则、章节覆盖、统计日期范围、目录自然顺序及缓存失效语义是该批兼容约束；分支中间态的页面不构成可运行或可发布承诺。

SHA-256 是规范正文身份，原始 SHA 加解码策略仅作快开和字节校验，UUID file id 只定位副本。路径、mtime、平台 generation 与 xattr 均不构成内容身份；不在小说原件写扩展属性是已确认边界。SwiftData 用户事实只有一个权威写入口，不与 Rust 用户表或 CKSyncEngine 双写；Automerge 原型未进入依赖，不并行引入第二套 CRDT。框架限制若影响既定体验，先取得可复现证据再决定是否换存储。
