# 架构与数据约定

本文记录已采用的技术与共同契约。功能现状从[开发文档入口](../README.md)进入，未完成范围统一见[后续计划](../roadmap.md)。当前存储与统一文件夹书架设计见[数据专题](../data/README.md)，iCloud Documents/CloudKit 分工见[同步设计](../data/sync.md)，代码接入与云端验证边界见[接入实施](../data/icloud-implementation.md)。

## 平台与职责

首个平台是 iOS，后续可能增加 Android。可跨平台的底层能力与业务规则由 Rust 实现，Swift 负责 iOS 界面、原生排版和平台适配。当前通过 UniFFI 连接；SwiftData 是用户数据权威来源，Rust SQLite 保存正文、索引与任务。

| 部分 | 当前实现与职责 |
| --- | --- |
| Rust 文本核心 | `crates/moonread-core`：`encoding_rs` 解码、规范化、字素分块、SHA-256、章节扫描、`regex` 单书搜索 |
| Rust 数据与任务 | `rusqlite` 保存正文、自动章节、来源索引与导入任务；位置换算、计时与覆盖计算从 Swift 输入取得用户数据 |
| Swift 用户数据 | `UserDataStore` ModelActor：用户事实、完整批注候选、小说信息、配色及正式位置；自动 CloudKit，设备偏好独立 |
| Swift 平台适配 | `Data/ReaderService.swift`、`Library/LibraryService.swift`：目录授权、bookmark、协调扫描与真实文件操作、目录变动通知、生命周期和异步工作调度 |
| 页面状态 | `Library/LibraryModel.swift` 保存现有书架状态与路由；`Reader/Session/ReaderSession.swift` 保存现有阅读会话状态与任务 |
| SwiftUI 页面 | `Library/LibraryView.swift`、`Reader/UI/ReaderScreen.swift`、`Reader/UI/ReaderTools.swift`：书架、阅读、工具面板与编辑器呈现 |
| 原生正文 | `Reader/Rendering/ReadingView.swift` 使用 UIKit / TextKit 1；`Reader/Rendering/TextCoordinates.swift` 映射 UTF-8 / UTF-16，处理局部滚动、分页与选字 |
| Swift AI | Providers / Agent / Data / Tools / UI 分层；Swift AI SDK 承担协议与工具循环，本机 SwiftData 保存对话；读取工具经 ReaderService 调用 Rust 最终查询 |
| 后续平台 | Android 可复用 Rust 正文与计算核心；不预先增加平台依赖 |

依赖及版本以[根 Cargo.toml](../../../Cargo.toml)、[核心 Cargo.toml](../../../crates/moonread-core/Cargo.toml)和[锁文件](../../../Cargo.lock)为准。当前搜索直接使用 Rust `regex`，不启动 `rg` 子进程，也未采用 `grep-searcher`。具体搜索语法和限额见[阅读工具](../reader/tools.md#搜索先找到上下文再决定跳转)。

TextKit 1 的显式字形范围和文本容器用于两种阅读模式。Swift 只持有邻近正文，不一次布局整本；是否迁移 TextKit 2 取决于实际排版、选区和性能需要。Rust 不承担 iOS 字体度量，用户数据只由 SwiftData 持久化。

## Swift 源码目录

`ios/Moonread` 的真实目录与 Xcode groups 对应。此次整理改善源码导航与文件职责，沿用现有状态 owner、actor 隔离、任务生命周期、存储和接口；没有隔离共享 actor，也没有改变 JSON 投影的类型契约。

| 目录 | 文件职责与保留边界 |
| --- | --- |
| `App` | 应用入口和 `MoonreadDelegate`；App 继续持有同一个 `CloudStore` |
| `Library` | 书架 model/路由、UI、目录操作、云文件与书目搜索；`LibraryPresentation` 保留跨功能复用的 `LibraryBookCover` |
| `Reader/Session` | 单独的 `ReaderSession.swift`，完整保留现有会话 owner |
| `Reader/UI` | 阅读页面、底部面板、目录、进度、工具和 `ReaderTitlePage` |
| `Reader/Rendering` | UIKit 正文、排版、坐标转换和设备控制 |
| `Books` | 小说详情与完整 `BookMetadata`；封面展示、加载及服务私有辅助保留原文件边界 |
| `Statistics` | 统计 UI 和完整 `ReadingStatistics`；统计 writer、recorder 与日期辅助仍在同一文件 |
| `Settings` | 设置 UI、设备阅读偏好、阅读预览、`CloudSettingsView` 和现有 UI 状态 `CloudStore` |
| `Data` | `ReaderService`、SwiftData 用户数据及同步协调；正文准备、导入、云目录 owner 与紧耦合私有类型仍在 `ReaderService` |
| `Shared` | `Theme`、`MoonView`/`MoonCharacter`/`BrandSeal`、输入焦点及跨功能错误文案 `ReaderMessages` |
| `AI` | 保持现有分层和路径；资源与签名配置路径保持原位 |

拆分仅沿现有类型边界进行，未放宽 `private` / `fileprivate`。原有 Sources UUID 与 target membership 保留，新增拆分文件显式加入应用 target。

## 原文件与平台访问

- 当前阅读与正文准备只读小说原件，阅读记录、索引和缓存放在应用数据区。统一书架设计允许用户主动重命名、移动、建目录与删除真实文件；这些操作由平台协调执行，Rust 维护文件索引与 SHA 阅读数据的独立归属。
- 系统文件选择器决定可访问范围；“选择目录”不代表能够访问整个 iOS 文件系统。
- Swift 在安全授权和文件协调有效期内提供可读源，Rust 执行文本处理。平台路径、授权 bookmark、凭据不作为跨设备书籍身份。
- 当前按已授权根枚举真实子目录与 TXT，成功扫描后事务更新文件索引；失败保留已知清单。Rust 负责目录查询、文件名搜索、自然排序和正式最近阅读；Swift 管理系统授权与 NSFileCoordinator。见[数据与来源](../data/README.md)与[书架界面](../design/library.md)。
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

自然阅读、布局重排和显式跳转是不同操作。目录、搜索、书签与批注的临时浏览保护统一见[阅读工具的定位契约](../reader/tools.md#共同的数据与定位契约)。保留正式续读原点，同时由 Rust 管理最多 32 项的会话跳转历史；回退/前进不压入重复历史，新的跳转截断前进分支。确认继续阅读或回到原点后结束本次历史。

主题类型与解析分工见[主题模型](../design/themes.md)：Rust 管理配色校验和继承计算；SwiftData 保存配色方案本体，UserDefaults 保存各设备的显示选择与首帧快照；平台负责语义颜色和渲染。

文件定位与正文关联实现见[关联交接](../data/README.md#文件定位与-sha-关联)。保留 SHA、现有存储职责和最终业务查询边界；交接发布关联必须先于扫描，外部修改重新核验。SQLite 事务同时发布最后已知关联与固定根，平台记录保护复制和清理之间的中断重试；临时任务不作为已完成快开缓存。

## 持久化

当前表、schema 版本、文件位置、目录授权与首帧快照统一列在[当前实际存储](../data/README.md#当前实际存储)，不在多份文档重复维护表清单。

SwiftData 是用户数据权威来源。Rust 用户存储和同步协议已删除，计算使用独立只读 ReaderQuery 的 TEMP 输入，业务层按查询范围组合所需用户状态，不以此前刷新过共享投影为读取前提。所有书架是统一真实目录：云端 TXT 与目录结构交给 iCloud Documents，用户可从系统文件工具直接整理；CloudKit 只同步阅读数据和设置，不镜像书架文件清单或原文。运行中的 SQLite 不放进云文件夹。职责与冲突规则见[同步设计](../data/sync.md)。

## 开发阶段的数据与接口变更

数据库 schema、设置、缓存和内部接口按最终正确、简洁的设计调整；不为历史开发版本增加迁移、兼容字段、多版本读取或双路径。必要时重置应用数据或卸载重装；开发重置不得删除用户的外部小说原件，用户明确触发的文件删除遵循文件层规则。

这项约定不免除新版本内部的持久化、暂停恢复与进度保护，也不改变[iOS 版本和 API 兼容策略](ios-support.md)。

## 技术参考

- [UniFFI](https://mozilla.github.io/uniffi-rs/next/)
- [Apple 目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、[文件协调](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [TextKit 2 能力介绍](https://developer.apple.com/videos/play/wwdc2021/10061/)
- [SQLite 备份与运行中数据库](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)

## 正文接口与最终业务查询

Swift 通过 ReaderService 的 ReaderQuery 快照读取书籍、章节、搜索、阅读位置、统计与书架展示数据。快照统一叠加 SwiftData 的章节修正、元数据、位置和阅读事实；ReaderCore 不再对 UniFFI 暴露这些原始业务查询。

ReaderCore 只公开正文与索引操作所需的接口。导入生命周期使用 ImportStatus（正文身份、大小、分块及导入阶段），文件移动和云端转存使用 SourceFileLocation（索引 ID、目录标记、路径与正文关联），SHA 查找返回正文 ID。这些类型不携带用户展示字段，不充当页面查询的替代路径。

## 查询范围与执行隔离

开书只按正文 SHA 或 pending key 读取位置、元数据与章节覆盖；首次 snapshot/frame 共用同一不可变 ReaderQuery。普通目录只投影该目录及子目录相关书籍，普通最近列表先查位置索引再补必要资料。冷首页全量路径与需要 facts 的统计/目录查询保留各自范围，不把它们作为每次开书的前置条件。

阅读设置使用验证后的内存副本；位置压缩按写入 key 进行，CloudKit 导入失效缓存，读路径不执行全库压缩。pending 恢复与全局 reclaim 在本地首页建立后启动一次。ReaderQuery 保持独立不可变 TEMP 输入；缓存按输入版本失效，不恢复共享可变 TEMP 表。详细失效与执行原则见[性能设计](performance.md)。

SHA-256 是规范正文身份，原始 SHA 加解码策略仅作快开和字节校验，UUID file id 只定位副本。路径、mtime、平台 generation 与 xattr 均不构成内容身份；不在小说原件写扩展属性是已确认边界。SwiftData 用户事实只有一个权威写入口，不与 Rust 用户表或 CKSyncEngine 双写；Automerge 原型未进入依赖，不并行引入第二套 CRDT。框架限制若影响既定体验，先取得可复现证据再决定是否换存储。
