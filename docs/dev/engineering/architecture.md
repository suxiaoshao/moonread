# 架构与数据约定

本文记录已采用的技术与共同契约。功能现状从[开发文档入口](../README.md)进入，未完成范围统一见[后续计划](../roadmap.md)。当前存储与统一文件夹书架设计见[数据专题](../data/README.md)，iCloud Documents/CloudKit 分工见[同步设计](../data/sync.md)，代码接入与云端验证边界见[接入实施](../data/sync.md)。

## 平台与职责

首个平台是 iOS，后续可能增加 Android。每条业务规则有一个明确归属方，按语义、数据权威与平台依赖选择 Rust 或 Swift，见下方规则归属表；Swift 同时负责 iOS 界面、原生排版和平台适配。当前通过 UniFFI 连接；SwiftData 是用户数据权威来源，Rust SQLite 保存正文、索引与任务。

| 部分 | 当前实现与职责 |
| --- | --- |
| Rust 文本核心 | `crates/moonread-core`：`encoding_rs` 解码、规范化、字素分块、SHA-256、章节扫描、`regex` 单书搜索 |
| Rust 数据与任务 | `rusqlite` 保存正文、自动章节、来源索引与导入任务；位置换算、计时与覆盖计算从 Swift 输入取得用户数据 |
| Swift 用户数据 | `UserDataStore` ModelActor：用户事实、完整批注候选、小说信息、配色及正式位置；自动 CloudKit，设备偏好独立 |
| Swift 平台适配 | `Data/AppDataService.swift`、`Library/LibraryService.swift`：目录授权、bookmark、协调扫描与真实文件操作、目录变动通知、生命周期和异步工作调度 |
| 页面状态 | `Library/LibraryModel.swift` 保存书架状态、来源路由及唯一设置会话 `SettingsNavigation`（任务路径、配色草稿/预览）；`Reader/Session/ReaderSession.swift` 保存现有阅读会话状态与任务 |
| SwiftUI 页面 | `Library/LibraryView.swift`、`Reader/UI/ReaderScreen.swift`、`Reader/UI/ReaderLibrarySheet.swift` / `ReaderSearchContent.swift` / `NoteEditor.swift`：书架、阅读、工具面板与编辑器呈现 |
| 原生正文 | `Reader/Rendering/ReadingView.swift` 适配原 UIKit 控制器，`ReadingPagination.swift` / `ReadingTextDecorations.swift` 使用 TextKit 1；`Reader/Rendering/TextCoordinates.swift` 映射 UTF-8 / UTF-16，处理局部滚动、分页与选字 |
| Swift AI | Providers / Agent / Data / Tools / UI 分层；Swift AI SDK 承担协议与工具循环，本机 SwiftData 保存对话；读取工具经 AppDataService 读取不可变投影，书目匹配由 Swift LibraryQueryRules 统一 |
| 后续平台 | Android 可复用 Rust 正文与计算核心；不预先增加平台依赖 |

依赖及版本以[根 Cargo.toml](../../../Cargo.toml)、[核心 Cargo.toml](../../../crates/moonread-core/Cargo.toml)和[锁文件](../../../Cargo.lock)为准。当前单书正文搜索直接使用 Rust `regex`，不启动 `rg` 子进程，也未采用 `grep-searcher`。具体搜索语法和限额见[阅读工具](../reader/tools.md#搜索先找到上下文再决定跳转)。

TextKit 1 的显式字形范围和文本容器用于两种阅读模式。Swift 只持有邻近正文，不一次布局整本；是否迁移 TextKit 2 取决于实际排版、选区和性能需要。Rust 不承担 iOS 字体度量，用户数据只由 SwiftData 持久化。

## 规则归属表

每条独立规则只在一处实现；调用层只测边界及自身状态。表中“后续”项登记待收敛的现存副本，不宣称 #66 已改写这些计算。Rust 路径前缀为 `crates/moonread-core/src/`，Swift 主 App 前缀为 `ios/Moonread/`。

| 独立规则 | 唯一归属方 / 文件 | 理由与其他层边界 | #66 动作 |
| --- | --- | --- | --- |
| 阅读纹理 ID/强度、alpha、逻辑平铺周期与偏好兼容解码 | Rust `user/themes.rs` | App 与官网复用同一 256pt/CSS px 周期；两个可选本机槽；未知值归无，旧 night-v1 读作 grain-v1；接收 paper/ink，按 OKLab toe 修正后的 ΔLr 求 alpha，不做可读性门槛 | 单源 |
| 字号、行距、段间距的默认值、范围与控件步长 | Rust `reading/layout.rs` | `reader_typography_controls` 同时供设置校验、Swift Stepper 和官网导出器使用；原生/浏览器字体度量各自归平台 | 单源 |
| 阅读设置当前值、连续修改与串行保存 | Swift `Settings/ReaderSettingsStore.swift`，App 级可观察环境对象 | `ReaderSession` 和设置页共用同一实例，不持有可写副本或各自排队；`AppDataService` 仍负责既有 UserDefaults 编解码和持久化，Rust 校验范围不变 | 单一 owner |
| 纹理槽本机保存/回滚、最终系统来源禁用 | Swift `UserThemes` / `ThemeStore` / 阅读设置 | 使用既有 UserDefaults；不改 Palette、CloudKit 或备份 | 平台边界 |
| 正文局部几何、叶页分组、活动叶及原文选区恢复 | Swift `Reader/Rendering/ReadingController` / `PageController` / `ReadingViewport` | 原生字体度量与系统保留区归平台；一个 pager、一份统计输入，源范围仍用 Rust UTF-8 坐标；几何变化不写阅读事实 | 平台排版 |
| 宽窄工具交接与呈现意图 | Swift `ReaderScreen` / `ReaderInspector`，`ReaderWideTools` 持有章节/配色/重建编辑会话（稳定 ID、草稿/任务引用、呈现宿主与返回工具），批注模型由 `ReaderSession` 持有 | `ReaderRootPresentation` 单源裁决独立编辑、dock、设置页与按需进度 popover 的呈现资格，dock 内编辑保留父链；进度复用既有控件，原生关闭完成后才交接历史等任务；inspector 原生退出前保留内容，关闭完成后才呈现独立编辑或经既有 dismiss→push 路径交接设置；宽窄变化不结束任务，章节输入和识别 job 不随视图消失；compact 外壳保留，偏好经 ReaderSettingsStore 单源保存 | 单一 owner |
| 系统开书与未保存修改确认 | Swift `SystemReadingRouter`；dirty 权威为 `PaletteDraft` / `ChapterEditDraft` / `NoteEditorModel` | 普通面板不排队；比较草稿基线，保存中的请求即时提示并消费，不取消写入或排队；解析错误不离书，取消消费请求，晚到确认按请求 token 隔离 | 平台入口与草稿 owner |
| 纸面 tile 与滚动/分页背景 | Swift `ThemeSurface` / `ReadingTextDecorations` / `ReadingController+Pages` / `ReaderTitlePage` | 当前输入与 tile；复用容器/页面，不动正文布局 | 平台绘制 |
| 解码、normalization-v1、正文/原字节 SHA 计算 | Rust `reading/text.rs`、`identity/source.rs` 及正文导入共用核心 | 和正文缓存/稳定内容身份一致；Swift 不重算规范正文 | 保持 |
| fileId/bookId/canonical→正式或 pending 阅读键、索引有效性 | Rust `identity/content.rs`，供 user/projection、library/full_index 和 library/bookshelf 共用 | 数据库关联是事实，不能由 UI 看长度猜身份 | 收敛 |
| 待索引集合与书架索引 inventory | Rust `library/full_index.rs` | 同一数据库快照返回总量/pending；Swift 不重复身份判定 | 单源扩展 |
| 书架同步描述、本机授权绑定和扫描后准入 | Swift `ShelfRecovery.swift`、`UserSyncJSON.swift`、`FullIndex.swift` | SwiftData 裁决描述，本机 schemaVersion 1 绑定按账户隔离；平台扫描成功范围限制自动任务，不复制 Rust 查询 | 平台边界 |
| SHA 格式 | Rust `identity/content.rs::parse_sha256` | 身份及资产校验共享严格语法，语义字段仍区分 | 收敛 |
| 默认阅读中状态 | Rust `user/projection.rs::reading_content_positions` + `reading/book_details.rs::project_metadata` | 详情与搜索共用 SHA 位置记录判定；file_identities 提供有效索引身份，不依赖本机 books 正文缓存；显式状态优先 | 单源修复 |
| AI b: 引用协议 | Swift `AI/Tools/AIReadingReferences.swift` | 工具协议只在 Swift；调用 Rust SHA 校验，不再复制 hex 判断 | 删除 AIReadingTools 第二 parser |
| SwiftData LWW/候选裁决、未知 payload 隔离 | Swift `Data/UserData.swift`、`UserSyncJSON.swift` | 权威写入口；Rust 仅接最终唯一投影 | 保持已修复单源 |
| 相对路径语法、组件边界匹配、名称合法性 | Rust `storage/validation.rs`，bookshelf 委托 | 索引和真实操作都需要相同底线；具名 profile 保留入口差异 | 删除主 App 字符/路径段副本 |
| 表单 TXT 后缀补全、AI stem trim/保留扩展名 | Swift `LibraryActions.swift`、`AI/Data/AIProposals.swift`，分别为两条不同规则 | 各自单源、不同输入契约，不为统一语言迁移 | 原位保留，只调用合法性 owner |
| source hint 字节/字段限制；恢复候选优先级与下载限额 | Swift `Data/UserData.swift::PositionSourceHint`、`RecentReadingRestoration.swift::RecentRestorationPolicy` | 同步载荷与恢复行为专用且已经单源；共享路径语法调用 Rust | 保留，删重复路径语法 |
| symlink/授权/provider 生命周期、真实文件 IO | Swift `LibraryService.swift`、ShareReceiveShared | 平台安全事实，Rust 字符串校验不能替代 | 保持 |
| 分享扩展入站安全校验 | Swift `ios/ShareReceiveShared/ShareInbox.swift` | 独立进程不依赖 Rust，属于明确防御性例外 | 保留，共同 fixture 对齐公共规则 |
| 系统元数据匹配 | Swift 共享 `LibraryQueryRules.systemMetadataBooks` | 只匹配书名/作者/标签及其分词、词边界前缀、拼音全拼/首字母，复用 Rust ordinal；App Entity 与 Spotlight 共享词表，不带 AI 简介 profile | 新增具名契约 |
| 系统书目派生快照与统一开书路由 | Swift `SystemIntegration`、`SystemIntegrationShared` | 主 App 唯一生产者；共享 DTO 不含正文、路径、位置 token/偏移，不成为事实权威；身份、代表副本、顺序与进度沿既有 Rust 查询 | 平台边界 |
| 查询范围、身份/metadata 关联、目录后代最近时间、最近副本选择 | Rust `library/bookshelf/`、`user/projection.rs` | 需要完整索引/快照，不能由限量 recents 再聚合 | 收敛，删除 Swift 目录聚合 |
| 书目文本/作者/标签/状态筛选、搜索排名和建议匹配 | Swift `LibraryQueryRules`（`Library/LibraryQueryRules.swift` 与共享系统元数据 profile） | Foundation 本地化能力合适；UI literal 与 AI/建议模式显式保留 | 删除 Rust search_rank/metadata filter 与各 Swift 调用点副本 |
| 文件自然比较、目录/全书/标签自然排序 | Rust `library/order.rs`（从 bookshelf 提取） | 已服务 SQL 查询和目录；按完整快照一次计算 | Swift 搜索使用批量 ordinal，不复制自然 comparator |
| 搜索排名组合、AI 名称字典序/recent 平手顺序 | Swift `LibraryQueryRules.swift` | 与匹配结果一同完成，AI 原生字符串比较不迁语言 | AI 私有 sort 收入单一模块；Rust 不留搜索组合副本 |
| 拼音 key、字母分组及组内 localized collation | Swift `LibraryPresentation.swift::LibraryNameGroup` | 唯一实现且依赖 Foundation；不是原文件自然序副本 | 原位保留 |
| 多标签分组/未标注/未索引分区 | Rust `library/bookshelf/::all_library_tag_groups` | 已单源，依赖索引身份 | 保持 |
| 目录四封面选择 | Rust `library/bookshelf/::populate_cover_previews` | 独立 top-4 策略，不等于目录列表顺序 | 保持 |
| 字数定义与 UTF-8 前缀累计字数 | Rust 文本计数共用 helper（后续）；当前 reading/chapters、identity/source、reading/navigation 和 user/coverage | 与导入字数、章节/覆盖分母一致 | 不在 #66 改写；旧报告第8项仍待收敛 |
| 字节位置→进度比例、百分比跳转 | Rust `reading/navigation.rs::reading_percentage`，阅读数据通过 `identity/content.rs::reading_data_percentage` 查询可信全文长度 | 阅读数据与跳转共用比例/边界计算；Swift 只本地化格式化 | 其余旧报告第9项 Swift 比例副本仍待处理 |
| 有效章节/位置归属 | Rust `library/tools.rs` 与有效章节关系（后续统一 SQL） | 手动目录需一致；Swift 展开/滚动目标不是同一规则 | #66 不迁；旧报告第10项仍登记 |
| 阅读时长/有效天数/覆盖等统计数值 | Rust `user/statistics.rs`、`user/coverage.rs`（后续统一 summary） | 事实聚合按固定 local_day；Swift 不再另 reduce 同一总量 | #66 不迁；旧报告第11项仍登记 |
| 统计总览总时长 | Rust `user/statistics.rs::statistics_overview` | 与已投影书目一次计算为只读 DTO 字段，App 总览和 Siri 直接读取，不来回搬运整个列表重复求和 | 单源 |
| 统计事实保存/去重裁决、日历展示桶/连续行视觉合并、显示格式 | Swift `ReadingStatistics.swift`、`StatisticsView.swift`，按各自职责单源 | 写入/界面组织与 Rust 数值汇总是不同规则；展示合并应消费已算 duration | 保持平台/状态规则，数值副本后续删除 |
| 备份 ZIP 布局、受限解包、路径/摘要与正文缓存 SQL 驱逐 | Rust `storage/backup_archive.rs`、`storage/cache_management.rs` | Swift 不另写 ZIP 或数据库清理规则，驱逐保留索引/授权/任务 | 新增单源 |
| 用户备份 envelope、原 payload 接入、对象级删除 | Swift `UserDataBackup.swift`、`ReadingDataManagement.swift` | SwiftData 权威与既有裁决不迁到 Rust；整书删除无本机删除回执或启动补删 | 共用接入 |
| 受保护来源的 bookmark 解析、安全作用域、协调读取与物理路径边界 | Swift `Data/ProtectedFileAccess.swift` | 开书、导入、索引、恢复、缓存和备份共用；沿用 `.withoutUI` 与可解析的陈旧书签，不增加拒绝条件；作用域覆盖各阶段，accessor 内不等待 actor | 平台边界 |
| 缓存来源可读性证明与清理准入 | Swift `CacheManagement.swift` | 借用公共文件访问组件，证明期内调用 Rust 重验事务；页面不判断可清性 | 平台边界 |

维护约定：新增规则先查本表；已存在则调用 owner。新增或改变归属必须在同一 PR 更新表、实现入口及测试位置。两个策略若故意不同，命名其输入/输出契约；不能仅以语言或调用入口不同为理由再实现一份。


备份容器布局、受限解包、路径/摘要验证与正文缓存 SQL 驱逐由 Rust `storage/backup_archive.rs` / `storage/cache_management.rs` 负责；用户备份 envelope、原 payload 接入与对象级删除仍由 Swift `UserDataStore` / `UserDataBackup.swift` 负责，调用既有裁决。`ReadingDataManagement.swift` 只编排本机事务交接，`ProtectedFileAccess.swift` 负责 bookmark、安全作用域和协调读取；`CacheManagement.swift` 保留清理准入与可读性证明；页面不实现另一份身份、排序或合并规则。数据管理列表的自然顺序调用 Rust `reading_data_order`，本地化文本匹配复用 `LibraryQueryRules`。

## Rust 源码目录

`crates/moonread-core/src/lib.rs` 仅声明领域模块、重导出现有 API 和注册 UniFFI scaffolding。模块移动不改变规则 owner、导出名称、签名、正文身份或持久化格式；跨实现模块需要的 `pub(crate)` / `pub(super)` 只表达原先 crate 根及父模块已有的内部访问范围，不增加对外 API。

| 目录 / 入口 | 职责 |
| --- | --- |
| `core.rs`、`error.rs` | ReaderCore 连接/锁与入口类型，共享错误类型 |
| `library/` | `bookshelf/` 分查询、mutations、source 和测试；full_index（及原 SQL）、order、tools |
| `identity/` | content 阅读键与文件关联、source 原件探测/解码策略、sha |
| `reading/` | ingest 事务正文导入、chapters 扫描、text 解码/分块、navigation、layout、cover_page、book_details |
| `reading/progressive/` | 任务类型与状态入口；tasks 生命周期、stream 前缀分块、recovery 恢复/回收、query 不可变读取、原有测试 |
| `user/` | projection、statistics、coverage、themes；只投影/计算，SwiftData 继续是用户事实权威 |
| `storage/` | 原 schema.sql、migrations、backup_archive、cache_management、validation、rows 正文缓存 SQL 行映射 |

SQL 内容、迁移顺序和调用时序保持原样；仅按新目录调整 `include_str!` 路径。章节和渐进准备的既有测试随实现移动，不复制测试或规则。

## Swift 源码目录

`ios/Moonread` 的真实目录与 Xcode groups 对应。此次整理改善源码导航与文件职责，沿用现有状态 owner、actor 隔离、任务生命周期、存储和接口；没有隔离共享 actor，也没有改变 JSON 投影的类型契约。

| 目录 | 文件职责与保留边界 |
| --- | --- |
| `App` | 应用入口和 `MoonreadDelegate`；App 继续持有同一个 `CloudStore` |
| `Library` | 书架 model/路由、UI、目录操作、云文件与书目搜索；`LibraryPresentation` 保留跨功能复用的 `LibraryBookCover` |
| `Reader/Session` | 单独的 `ReaderSession.swift`，完整保留现有会话 owner |
| `Reader/UI` | `ReaderScreen` 保留会话生命周期和私有路由状态；`ReaderTaskContent`、`ReaderPreparationContent`、`ReaderCompactHeader`、`ReaderMoreContent` 分别呈现任务、准备、顶部提示和更多操作；`ReaderTools` 保留 model，目录/笔记/搜索及 NoteEditor 分文件 |
| `Reader/Rendering` | `ReadingView` 是 SwiftUI 适配入口；`ReadingController` 与 Pages/Scroll/Navigation/Selection 扩展共用原控制器状态；`ReadingPagination`、`ReadingViewport`、`ReadingTextDecorations`、`ReadingTextView`、扉页/分页控制器按职责分文件，坐标和设备控制保持原 owner |
| `Books` | 小说详情与完整 `BookMetadata`；封面展示、加载及服务私有辅助保留原文件边界 |
| `Statistics` | `StatisticsView` 保留总览/单书详情的状态和路由；models、书目列表、时长条、节奏图、时段图/行、全部时段、日期详情、统计设置按完整类型分文件；`ReadingStatistics` 的 writer、recorder 与日期辅助保持原 owner |
| `Settings` | `SettingsView` 只保留首页与私有入口辅助；应用外观、模式 Picker、配色选择/预览/编辑、关于与第三方许可分文件；设备阅读偏好、阅读预览、`CloudSettingsView` / `CloudStore` 保持原 owner |
| `Data` | `AppDataService`、SwiftData 用户数据及同步协调；正文准备、导入、云目录 owner 与紧耦合私有类型仍在 `AppDataService` |
| `SystemIntegration` / `SystemIntegrationShared` | 主 App 派生快照、系统入口路由与平台更新；共享部分只有稳定链接、只读 DTO、最小 Entity/配置与无状态文字卡片。Widget/Control 目标不含数据库/正文服务；任意队列系统回调显式 nonisolated / @Sendable 后再交接 |
| `Shared` | `Theme`、`MoonView`/`MoonCharacter`/`BrandSeal`、输入焦点及跨功能错误文案 `ReaderMessages` |
| `AI` | 保持现有分层和路径；资源与签名配置路径保持原位 |

`ios/MoonreadShare` 是独立分享扩展 target，只负责接收与取消。`ios/ShareReceiveShared` 同时编译进主 App 与扩展，提供版本化 ShareInbox、原字节复制和 provider 生命周期适配；不依赖主 App 的 Rust、SwiftData、AI 或阅读 UI。App Group 只共享待导入原件，主 App 继续独占书架写入和正文准备。

拆分保留现有类型、状态 owner 和 actor 隔离；SwiftUI 的 `@State` / `@FocusState` 留在原父视图，目录子视图只接收 Binding 和回调。UIKit 控制器跨文件扩展共用状态与方法时，仅将必要成员调整为模块内访问，其余保持 private，不增加 public API。原有 Sources UUID 与 target membership 保留，新增拆分文件显式加入应用 target。设置和统计按完整 View/model 类型移动，原有私有状态和 actor 标注保持；共享的页面与图表 helper 只在必要时由文件私有调整为模块内访问。

`AppDataService` 当前协调小说来源、Rust 正文/查询、用户阅读数据、配色与同步，不仅服务阅读页；`ReaderSession` 才是阅读会话状态 owner。其扩展已随领域位于 Library、Books、Statistics 和 AI，Data 保存用户事实、备份/缓存及同步协调。名称仍为 `AppDataService`，领域扩展共用同一 actor 的串行边界；文件目录不改变数据权威和存储归属。

## 原文件与平台访问

- 当前阅读与正文准备只读小说原件，阅读记录、索引和缓存放在应用数据区。统一书架设计允许用户主动重命名、移动、建目录与删除真实文件；这些操作由平台协调执行，Rust 维护文件索引与 SHA 阅读数据的独立归属。
- 系统文件选择器决定可访问范围；“选择目录”不代表能够访问整个 iOS 文件系统。
- Swift 在安全授权和文件协调有效期内提供可读源，Rust 执行文本处理。平台路径、授权 bookmark、凭据不作为跨设备书籍身份。
- 当前按已授权根枚举真实子目录与 TXT，成功扫描后事务更新文件索引；失败保留已知清单。Rust 负责目录范围、身份关联、自然排序和正式最近阅读；Swift LibraryQueryRules 负责书目匹配与搜索排名，平台层管理系统授权与 NSFileCoordinator。见[数据与来源](../data/README.md)与[书架界面](../design/library.md)。
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

SwiftData 是用户数据权威来源。Rust 用户存储和同步协议已删除，计算使用独立只读 ReaderQuery 的 TEMP 输入，业务层按查询范围组合所需用户状态，不以此前刷新过共享投影为读取前提。所有书架是统一真实目录：云端 TXT 与目录结构交给 iCloud Documents，用户可从系统文件工具直接整理；CloudKit 只同步阅读数据与配色方案，不镜像书架文件清单或原文。运行中的 SQLite 不放进云文件夹。职责与冲突规则见[同步设计](../data/sync.md)。

## 持久化演进与发布兼容

兼容只对照已发布给用户的版本（main，或已提审且会先上架的构建）。release 分支开发中的中间结构不做兼容和迁移，可直接修改；未发布的新结构（如小组件标识、共享快照字段）直接按最终形状写。检查时对照基线提交 diff 持久化与共享结构；设计文档讨论兼容时须注明基线版本。

从 1.0.0 发布基线开始，SQLite、SwiftData/CloudKit、UserDefaults、Keychain、同步 payload 与缓存的格式变更必须保持已有数据可读。持久化枚举只增加、不删除或更改已有 raw value；退役功能可停止展示，不能用未知值使整个集合读取失败。新增字段使用可选值或明确默认值；结构调整须带版本、升级路径与迁移测试（旧数据、重复打开、失败回滚、降级拒绝），不能以删除重装代替升级。内部非持久化接口仍可直接整理，不要求保留无用的重复实现。

SQLite 以 `user_version=20` 为首次支持基线，`storage/migrations.rs` 按有序步骤升级。新库先事务创建 v20，再与已有库一样逐级升级；v21 为导入任务增加目的字段，既有任务默认 reading，恢复专用任务为 restoration；v22 增加全量索引数据；v23 一次登记旧手选编码待迁项，原件未就绪时保留，SwiftData epoch 候选保存后才确认完成。当前版本为23。每步成功后更新版本，失败回滚该步。高于当前版本明确提示更新应用；低于 20 的开发库无升级路径，保留原库并报不支持，不自动删除或重建。哪些是可重建派生数据、哪些必须保留，见[数据存储](../data/README.md#当前实际存储)。

AI 连接、共享授权、用途默认值逐条解码，失败条目跳过并记录不含正文/凭据的日志；会话列表逐行容错，存储读取错误仍向上抛出。读取不修复、不回写。显式保存时按稳定 ID/用途键更新可识别项，保留不可识别的原始 JSON 元素与未知对象字段；用户可删除可识别项，不能顺带删掉未知项。JSON 整体损坏时拒绝覆盖并报告失败。用途字典既读取此前 Codable 的键值交替数组，也读取对象，显式保存统一为字符串键对象。授权撤销另更新连接 generation，保留的未知授权不能绕过该边界；日志只记录集合键和序号。同步 payload 采用独立的版本/隔离契约，见[同步专题](../data/sync.md#同步-payload-的-v1-边界与隔离)。

`readingSettingsTab` 的发布取值固定为 `typography`、`colors`、`controls`，标题另行本地化；按发布前决定，旧开发中文取值不迁移，回到默认排版页。已识别对象内的数组字段按当前编辑值保存，不将这项容错措施宣称为任意嵌套协议的无损回放。

正文身份 `content_sha256` 的 normalization-v1 是稳定契约。已经支持的文件，其解码策略与规范化结果不得因依赖更新、算法整理而静默改变；若确需变更，须保留原键到新键的映射与所有进度/标记关联，并测试旧文件解码和旧键恢复。缓存可版本失效重建，但不得连带抛弃授权、解码选择、任务暂存或用户记录。

SwiftData 变更使用可验证的 schema 演进/迁移。1.0.0 的阅读数据库与 AI 会话库没有使用 `VersionedSchema`。1.0.0 之后第一次修改任一库的模型（包括只加可选字段的轻量变更）时引入版本化：1.0.0 的现有模型原样作为 `SchemaV1`，新模型为 `SchemaV2`，加 `SchemaMigrationPlan` 与旧库升级测试；此后每个发布过的 schema 都保留一个版本，轻量变更用 lightweight stage，不能只登记首尾两端。CloudKit 生产 schema 只增加字段/记录类型，不删改既有类型及字段语义。UserDefaults/Keychain 的键名与凭据编码属于数据契约，变更需迁移且不得落入日志。同步 payload 通过 Swift 边界校验并按作用域隔离未知内容，不能靠 JSON 字段保留代替 LWW 并发设计；详见同步专题。

重置仅限当轮明确授权的开发数据，不是发布后错误恢复方式；不得删除用户的外部或 iCloud 小说原件。上述约定不改变[iOS 版本和 API 兼容策略](ios-support.md)。

## 技术参考

- [UniFFI](https://mozilla.github.io/uniffi-rs/next/)
- [Apple 目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、[文件协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [TextKit 2 能力介绍](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [SQLite 备份与运行中数据库](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)

## 正文接口与业务查询归属

Swift 通过 AppDataService 的 ReaderQuery 快照读取书籍、章节、搜索、阅读位置、统计与书架展示数据。快照统一叠加 SwiftData 的章节修正、元数据、位置和阅读事实；ReaderCore 不再对 UniFFI 暴露这些原始业务查询。

ReaderQuery 提供身份一致的不可变数据投影，以及 Rust 所拥有的范围、自然排序、目录聚合和正文计算；Swift LibraryQueryRules 是书目匹配、筛选、排名和结果组合的唯一入口，保留 UI literal 与 AI/建议的既有匹配模式。页面和工具不能另写筛选副本。

ReaderCore 只公开正文与索引操作所需的接口。导入生命周期使用 ImportStatus（正文身份、大小、分块及导入阶段），文件移动和云端转存使用 SourceFileLocation（索引 ID、目录标记、路径与正文关联），SHA 查找返回正文 ID。这些类型不携带用户展示字段，不充当页面查询的替代路径。

## 查询范围与执行隔离

开书只按正文 SHA 或 pending key 读取位置、元数据与章节覆盖；首次 snapshot/frame 共用同一不可变 ReaderQuery。普通目录只投影该目录及子目录相关书籍，普通最近列表先查位置索引再补必要资料。冷首页全量路径与需要 facts 的统计/目录查询保留各自范围，不把它们作为每次开书的前置条件。

阅读设置使用验证后的内存副本；位置压缩按写入 key 进行，CloudKit 导入失效缓存，读路径不执行全库压缩。pending 恢复与全局 reclaim 在本地首页建立后启动一次。ReaderQuery 保持独立不可变 TEMP 输入；缓存按输入版本失效，不恢复共享可变 TEMP 表。详细失效与执行原则见[性能设计](performance.md)。

SHA-256 是规范正文身份，原始 SHA 加解码策略仅作快开和字节校验，UUID file id 只定位副本。路径、mtime、平台 generation 与 xattr 均不构成内容身份；不在小说原件写扩展属性是已确认边界。SwiftData 用户事实只有一个权威写入口，不与 Rust 用户表或 CKSyncEngine 双写；Automerge 原型未进入依赖，不并行引入第二套 CRDT。框架限制若影响既定体验，先取得可复现证据再决定是否换存储。

## 1.3 规则归属增量（已定稿待实现）

| 规则 | 唯一归属与复用 | 契约 |
| --- | --- | --- |
| 系统书目/最近项、展示排除、快照失效 | Swift SystemReadingCatalog；身份/排序继续调用现有 owner | [系统集成](system-integration.md) |
| 系统元数据字符串匹配 | Swift LibraryQueryRules 具名 profile | Entity 不复制匹配，Spotlight 排名由系统负责 |
| 系统统计摘要与连续日 | Rust user/statistics（既有有效日汇总），Swift 仅处理 Calendar/展示 | 今日未读截至昨日；不限七天，清除复用原投影；Widget 不读事实库 |
| 系统路由与统计回答 | Swift SystemReadingRouter / AppDataService 既有查询 | 扩展不读正文或用户事实库，不保存位置 |
| 领先阈值/有效章节/百分比 | Rust navigation / ReaderQuery | [同步提示](../data/sync.md#13-同步进度与编码)，Swift 仅本机基线与提示状态 |
| rawSHA/编码规范 | Rust source identity/text；Swift `ProtectedFileAccess` 协调读源 | 不改 normalization-v1 |
| 编码 LWW、epoch 迁移候选与兼容 | Swift UserDataStore / UserSyncJSON 共用接入，SourceDecodingPreferences 编排 | 三路径只消费同步 winner，不新增 legacy 回退 |

实现 PR 将拟增量并入上方现行表并删除相应计划表项；不让两张表长期定义同一已实现规则。
