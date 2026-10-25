# 系统续读、动作与书目快照

1.3 已确认设计，整理基线 release/1.3 `6dc282a`；本页不是已交付声明。实现 PR 更新实际接口和状态，顺序见[1.3 计划](../plans/1.3.md)。产品默认见[系统集成设计](../design/ios-integration.md)，持久化与身份规则沿用[架构](architecture.md)。

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
| envelope | schemaVersion=1、generation、storeScope、generatedAt、books、recentIDs、exposurePolicy；scope 为本机不透明域，不含 Apple ID |

不保存精确 offset/位置 token，点击时读最新权威位置，不能反算百分比跳页。首版文字封面，不发布实际图片资产。同 SHA 多副本合一；正文改变换身份，旧 ID 不按同名重绑。

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

输入仅 `continueReading`、`openBook(entityID)`、`showStatistics`。深链只作路由，严格校验 scheme/host/path/SHA，无任意文件 URL 或 offset 参数。待主 App 容器/引导/导航 ready 再执行。

- 继续阅读执行时重新取最近书；无记录到书架，已打开同书保持当前会话，不重开或跳页。
- 指定书重新核验 SHA、授权和来源，复用 LibraryModel/OpeningRequest/ReaderSession 的下载、取消与错误；快照不授访问权。同名不同正文不接旧进度。
- iCloud 未下载只在用户打开后走正常下载；外部根失效由主 App 重新授权，扩展不弹文件选择器。仅有云位置时沿受限最近恢复，不把 source_hint 当权限。
- 同目标合并，不同目标串行交接并取消旧 opening；不抢未保存编辑。请求消耗后不跨启动重放。只有实际正文呈现并符合原计时规则才写统计。
- Siri 可说“正在打开《X》”。今天/本周时长直接调用既有统计查询回答，不重算、不因错误报零；系统保护不可读时才提示打开 App。动作不依赖 AI 开关或外部模型。

## 各消费者的范围

**App Entity / Shortcuts / Control：**显式选书使用 catalog；元数据匹配由 Swift LibraryQueryRules 的具名 systemMetadata profile 统一处理（书名/作者/标签），不用 AI 简介匹配。注册三语短语，Control 只有继续阅读；不自动替用户添加控件。不承诺任意自然语言都能识别，不为此采用不匹配的 Books schema。

**Spotlight 与建议：**本机默认开启，书架排除默认空，无 onboarding。一个命名 CSSearchableIndex，仅填写 title/author/keywords，不填 textContent、正文 URL、简介、批注、进度、章节、时间、路径、封面。按 ID/domain 做更新/删除与可重建处理，点击走共用 router；不同时启用另一套 IndexedEntity 自动全属性捐赠。

同 SHA 任一已知副本被排除就不自动公开；donation 只针对真实读过且未排除的书，按会话/目标合并，不每页或整库批量捐赠。开关/排除同时撤自动建议。用户显式放书到 Widget/Shortcuts 是另一用途，不能被 Spotlight 开关误关；两种范围共用一个 exposure owner。

**Widget：**一个 kind，最近阅读/指定书；桌面 small/必要 medium、锁屏 rectangular/inline、系统 StandBy，默认书名+进度、文字封面。不提供 circular、隐藏书名开关或实时计时。显示哪本就传其 ID；未知进度不填零。Timeline 只读快照、`.never` 配合主 App 事件 reload，系统不保证即时更新；无联网、定时下载或 Widget push。gallery 全用合成数据。

## 可用性与验收

最低 iOS/iPadOS 18，Widget target 同下限。普通 AppEntity/EntityQuery/OpenIntent、Controls 与传统 CSSearchableIndex 足够；不用 iOS 18.4 hideInSpotlight 作18.0开关，不依赖 iOS27 IndexedEntityQuery/allowedExecutionTargets。较新 supportedModes 等仅 availability 分支。API 可用性依据原方案的本机 SDK 核查，实现时再查锁定 SDK，不以新网页示例抬高下限。

打开动作由主 App 执行；共享声明不得误初始化 AppDataService。Controls target 归属与 iOS18/当前系统实际打开进程需设备验收，不能用27-only执行目标修饰解决旧系统边界。Widget 不配置 CloudKit/iCloud Documents 权限，只加入已有 App Group，并走既有签名核验。

Rust 测身份等既有 owner，Swift 测快照/范围/失效/路由边界，UI复用关键开书流程；不测 Siri 识别率、系统菜单或 Widget 调度时机。锁屏首次解锁、真实 Siri、云下载/授权失效和跨设备时序单独验收。自己的书名在自己的设备显示不要求额外隐私许可；不新增外发服务、不进入 AI 请求、不向系统索引正文。

参考（原方案核查来源）：[App Intents 运行](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)、[Controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)、[Widget 数据保护](https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension)、[刷新预算](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)。
