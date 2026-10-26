# 系统续读、动作与书目快照

1.3 当前实现，兼容基线为已提审且会先上架的 1.2 (10) `6ceef33`；本批新增 Widget、Intent 与共享快照直接采用最终结构，无开发中间态迁移，真实系统效果仍待用户试用。实现 PR 更新实际接口和状态，顺序见[1.3 计划](../plans/1.3.md)。产品默认见[系统集成设计](../design/ios-integration.md)，持久化与身份规则沿用[架构](architecture.md)。

## 一个生产者，多个消费者

```text
SwiftData 用户事实 → 唯一候选裁决 ─┐
Rust 索引、身份、来源状态 ─────────┴→ AppDataService / ReaderQuery
                                      ↓ SystemReadingCatalog
                               App Group 原子派生快照
                              ↙          ↓          ↘
                        App Entity   Spotlight     Widget
                              ↘          ↓          ↙
                         SystemReadingRouter → 主 App 正常开书
```

主 App 唯一发布快照；扩展不打开 SwiftData/CloudKit、Rust SQLite 或根 bookmark，不读 TXT、不调用 AI、不写位置/统计。快照不进入同步/用户备份，不能回写权威事实。全库 catalog 不是 recentReadings 的十本截取；分批查询元数据，不加载正文/批注/统计 facts。

拟新增主 App `SystemIntegration/SystemReadingCatalog.swift`、`SystemReadingRouter.swift` 和共享 `ios/SystemIntegrationShared/` DTO，不新增包管理工具或通用事件总线。名称由实现 PR 核定。

## 身份与字段

稳定实体 ID 为 `book:<normalization-v1 content_sha256>`，调用 Rust `parse_sha256`，不以 bookId/fileId/路径作身份。尚无正文 SHA 的书不发布实体或 Spotlight 项；不为系统搜索自动下载全库。以后建立索引/正常开书后自然出现。

| 对象 | 字段与边界 |
| --- | --- |
| BookEntity | id、title、author?；标题沿现有有效书名规则，不含正文、简介、批注、路径或精确时间 |
| catalog 书目 | id、title、author?、tags、availability、sourceCount、naturalOrdinal；排序/代表副本沿既有 owner，availability 不是授权 |
| 阅读摘要 | progress?、chapterLabel?、recentRank?；现有 ReaderQuery 计算，未知为 nil，不伪造0% |
| envelope | schemaVersion=1、generation、storeScope、generatedAt、books、recentIDs、exposurePolicy、appearance?、statistics?；scope 为本机不透明域，不含 Apple ID |
| 封面引用 | fileName/revision/pixelWidth/pixelHeight；仅受控 Covers basename，损坏/缺图用文字封面，统计/主题不可得不阻断书目 |
| 统计摘要 | status、generatedAt、localDay、validUntil、timeZoneID/calendarID/firstWeekday、recordingEnabled、今日/本周时长、连续日、七日条；不进 Entity/Spotlight/donation |

不保存精确 offset/位置 token，点击时读最新权威位置，不能反算百分比跳页。共享 catalog 只引用自身 Covers 子目录内的受限缩略图，不发布原封面路径或字节；Spotlight 复用同一缩略图生成入口，缺图共用 App 文字封面。同 SHA 多副本合一；正文改变换身份，旧 ID 不按同名重绑。

## 发布和失效

App Group `SystemReading/v1/` 同目录暂存后原子替换完整 JSON；串行发布者用配置代次丢弃旧结果。建议初始保护量为总 JSON 8 MiB、单 title/author 1 KiB、tags 总 4 KiB，由合成大库检查再定；这是应用候选限额，不是 Apple API 限制。超额不能无声截断成完整快照。

| 事件 | 处理 |
| --- | --- |
| 本机书目/位置改变、云导入、pending 转正、索引完成 | 合并刷新对应书目，发布完整一致快照，有意义变化才 reload Widget |
| 文件删除/移除根 | 重查同 SHA 副本；最后来源移除时撤系统候选。清可重建缓存不等于删书名 |
| 阅读数据删除/备份导入 | 刷新最近及进度，不删仍在书架的元数据项 |
| 关闭系统搜索/排除书架 | 先改本机 policy，再删 Spotlight/donation；失败待下一前台重试；旧索引点击重新检查 |
| 账户/configuration 切换 | 撤旧域建议并发布空/通用状态，再按新域重建；单纯关闭同步不删除仍属本机的数据 |
| 未知版本、缺失、保护不可读 | 消费者显示“打开月读继续阅读”，主 App 下次重建，不强解码或回写 |

快照与扩展使用 `completeUntilFirstUserAuthentication`：重启首次解锁前不可读，之后锁屏/待机可显示书名/进度。不主动 `privacySensitive` 遮挡，也不强制 unredacted 绕过系统限制；正文与事实库保护不改。系统可能将 iPhone Widget 展示到 Mac，不承诺只出现在本机屏幕。

## 共用动作与路由

输入包括 `continueReading`、`openBook(entityID)`、`showStatistics`、`showLibrary`、`searchBooks(query)`。深链只作路由，严格校验 scheme/host/path/SHA；仅搜索允许一个受限的 query 参数，无任意文件 URL 或 offset 参数。待主 App 容器/引导/导航 ready 再执行。

- 继续阅读执行时重新取最近书；无记录到书架，已打开同书保持当前会话，不重开或跳页。
- 指定书重新核验 SHA、授权和来源，复用 LibraryModel/OpeningRequest/ReaderSession 的下载、取消与错误；快照不授访问权。同名不同正文不接旧进度。
- iCloud 未下载只在用户打开后走正常下载；外部根失效由主 App 重新授权，扩展不弹文件选择器。仅有云位置时沿受限最近恢复，不把 source_hint 当权限。
- 同目标合并，不同目标串行交接并取消旧 opening；不抢未保存编辑。请求消耗后不跨启动重放。只有实际正文呈现并符合原计时规则才写统计。
- Siri 可说“正在打开《X》”。今天/本周时长直接调用既有统计查询回答，不重算、不因错误报零；系统保护不可读时才提示打开 App。动作不依赖 AI 开关或外部模型。

## 各消费者的范围

**App Entity / Shortcuts / Control：**显式选书使用 catalog；元数据匹配由 Swift LibraryQueryRules 的具名 systemMetadata profile 统一处理（书名/作者/标签、NLTokenizer 分词与词边界前缀、无声调拼音全拼和首字母），Entity 做部分匹配，Spotlight 使用同一份检索词；不用 AI 简介匹配。注册三语短语，Control 只有继续阅读；不自动替用户添加控件。不承诺任意自然语言都能识别，不为此采用不匹配的 Books schema。

**Spotlight 与建议：**本机默认开启，书架排除默认空，无 onboarding。一个命名 CSSearchableIndex，填写 title/author/keywords、thumbnailData 和 contentDescription（作者 · 当前章节 · 已知进度）。缩略图从用户已有封面读取，缺失时用 App 内文字封面渲染；只在主 App 内查询资产描述，不给 Widget 增加权限或数据。未知章节/进度省略；不填 textContent、正文 URL、简介、批注、精确时间或路径。按 ID/domain 做更新/删除与可重建处理，点击走共用 router；不同时启用另一套 IndexedEntity 自动全属性捐赠。

Spotlight 另记 `contentFormatVersion`（当前 1）：提交字段、关键词或缩略图表达变化时递增。启动/后续 catalog 刷新发现版本不同就清空自身命名索引并全量重提，仅所有批次成功回调后标完成；失败或 scope/许可变化不误记完成。这是同一用户数据版本内的可重建缓存失效，不是数据迁移。填写 title/displayName/contentType；每批最多 50 本，独立于 Siri donation 工作链，普通位置更新不反复中断同 scope 全量提交。

当前没有后台 reindex extension，必须先打开主 App，让它生成并提交书目。设置 → 阅读 → 系统集成显示“正在准备/正在提交/已向系统搜索提交 N 本”；保持前台直到已提交即可，不必重新导入或重建正文。API 成功仅表示 Core Spotlight 已接受并 journal，不等于系统结果已可见，不能承诺固定秒数；系统检索匹配仍由 iOS 决定。若已提交但仍不命中，可据此区分提交失败与系统检索问题。

同 SHA 任一已知副本被排除就不自动公开；donation 只针对真实读过且未排除的书，按会话/目标合并，不每页或整库批量捐赠。开关/排除同时撤自动建议。用户显式放书到 Widget/Shortcuts 是另一用途，不能被 Spotlight 开关误关；两种范围共用一个 exposure owner。

**Widget（V7）：**三个最终 kind：`dev.moonread.Moonread.widgets.continue-reading`、`dev.moonread.Moonread.widgets.recent-reading`、`dev.moonread.Moonread.widgets.reading-statistics`。续读 small/medium 用 A，配置最近一本/指定书；最近阅读 medium 为 A 双本、large 为 B 四行，各书独立 Link，不复制填满，查看全部进入 App 最近阅读。统计 medium 为 B 三列与七日柱，整块进入统计总览。锁屏 circular/rectangular/inline 与待机用 A；未知进度用书本符号，不画伪零值圆环。系统背景移除、染色、低光由平台接管，gallery 的书目与统计全是合成数据，但 placeholder/isPreview 读取共享快照的 App 界面配色；无快照才用 `WidgetDefaultAppearance.json` 的默认杏桃。该资源由 Rust 默认主题导出，Swift 合同测试与主 App 解析结果比对，扩展不复制配色计算。

共享颜色由主 App 调用既有主题 owner 解析 App 界面（书架/设置）的 appMode 与 light/dark 槽；固定浅/深同样生效，系统配色槽使用原生角色，染色/锁屏由系统处理。小组件不读取阅读页配色或纸张纹理，使用纯色背景；扩展不重新混色。自设封面保留原色，复用 coverImage 下采样后重新编码（最长边 384，必要时 274/192；JPEG 0.8 或透明 PNG，去原图元数据），目标 128 KiB、单图硬上限 256 KiB。自身 Covers 目录按指定书、最近、其余书目优先，保留当前及预算内上一代引用，清理后总预算 32 MiB。先落图再原子发布 JSON，失败用文字回退，不省书目。Widget 配置查询独立于发布，失败不阻塞；scope 变更清空旧图，过时异步工作不得重新发布。

统计从单个 ReaderQuery 有效事实快照查询，Rust statistics owner 统一日汇总、今日/本周及连续天数：今天有效时长 >0 则截至今天，否则截至昨天，向前数到断日，不限七天，清除规则沿原投影。Swift 只传 Calendar 周起点并格式化。位置变化复用统计摘要，事实/清除/导入/开关/跨日才标脏；关闭记录保留历史，未知必需格式提示更新、读取失败显示不可用，未取得摘要不伪造 0。

统计带本地日、时区/日历/周起点及下个民用午夜有效期。主 App 活跃时重算跨日/设置变化；扩展在午夜时间线 entry 显示“打开月读更新统计”并请求 reload，不能靠重读旧 JSON 冒充新一天或访问数据库。续读仍可用。显示数据没变不 reload；generation/generatedAt 本身不是内容变更。系统调度不保证按时刷新。

## 可用性与验收

最低 iOS/iPadOS 18，Widget target 同下限。普通 AppEntity/EntityQuery/OpenIntent、Controls 与传统 CSSearchableIndex 足够；不用 iOS 18.4 hideInSpotlight 作18.0开关，不依赖 iOS27 IndexedEntityQuery/allowedExecutionTargets。较新 supportedModes 等仅 availability 分支。API 可用性依据原方案的本机 SDK 核查，实现时再查锁定 SDK，不以新网页示例抬高下限。

打开动作由主 App 执行；共享声明不得误初始化 AppDataService。Controls target 归属与 iOS18/当前系统实际打开进程需设备验收，不能用27-only执行目标修饰解决旧系统边界。Widget 不配置 CloudKit/iCloud Documents 权限，只加入已有 App Group，并走既有签名核验。

Rust 测身份等既有 owner，Swift 测快照/范围/失效/路由边界，UI复用关键开书流程；不测 Siri 识别率、系统菜单或 Widget 调度时机。锁屏首次解锁、真实 Siri、云下载/授权失效和跨设备时序单独验收。自己的书名在自己的设备显示不要求额外隐私许可；不新增外发服务、不进入 AI 请求、不向系统索引正文。

参考（原方案核查来源）：[App Intents 运行](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)、[Controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)、[Widget 数据保护](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)、[刷新预算](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)。
