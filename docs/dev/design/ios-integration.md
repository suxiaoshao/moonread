# iOS 系统集成

更新：2026-10-25。1.3 的系统展示默认值按用户确认修订；详细设置归属见[设置信息架构](settings-information-architecture.md)。系统续读基础已接入 App 内首页续读：稳定 book:SHA ID、主 App 唯一生产的版本化只读快照、失效事件和统一开书路由。App Entity、五项 App Shortcuts 与继续阅读 Control 已接线；选书查询只读共享快照，统计动作仅在主 App 读取既有统计查询。真实正文可读时才为允许的书登记带书名的打开动作 donation；关闭系统搜索、排除来源或切换分域时撤销。Control/OpenIntent 声明同时属于主 App 和扩展，扩展不含 AppDataService/Rust/SwiftData；iOS 27 显式限定主 App 执行，iOS 18 沿 OpenIntent 的前台打开语义。进程归属和系统可见性仍需真机核验。最低系统继续为 iOS 18；具体 API 按部署版本检查可用性，不因最新文档提高系统下限。

## 系统搜索（1.3）

设置 → 阅读 → 系统集成提供默认开启的“在系统搜索中显示书籍”和本机书架排除。共用 catalog 的已识别书目；同 SHA 任一已知来源被排除，就不自动索引/捐赠，但显式选书与 Widget 配置仍可使用。命名索引 `MoonreadBooks` 提交书名、作者、标签，以及用户允许的封面缩略图、当前章节与进度。书名/作者使用 NLTokenizer 分词，加入书名词边界前缀、无声调拼音全拼和首字母（ü 用 v）；App Entity 选书复用同一份检索词做部分匹配。封面优先使用已有用户资产，否则复用 App 内文字封面渲染；封面描述只在主 App 内使用，不改变 Widget 快照。正文、路径、简介、批注和精确时间仍不索引。旧系统搜索点击重新检查当前许可，再走统一路由。

成功扫描、身份发布、元数据与事实变更更新快照；临时扫描失败保留已知书目，明确移除最后副本才删除候选。已提交/尝试提交的 ID 是版本化本机派生状态，删除成功才去除，失败下次前台重试。Core Spotlight delegate 的任意队列回调显式非隔离，只将重建请求交回主 App；回执不等待可能依赖该回调的系统索引工作链。

## 书架索引后台任务

全量索引共用串行 worker；正文准备和阅读租约共用前台闸门，索引与最近阅读恢复在逐个文件处理前等待空闲；开书失败或取消也释放闸门并自动继续，不依赖页面或前后台切换唤醒。阅读准备优先，低电量或 serious／critical 热状态暂停。iOS 26+ 用户点按发起的索引用 `BGContinuedProcessingTask` 显示系统进度和取消；自动索引、iOS 18–25 前台运行，退后台保存暂停状态，由充电时的 `BGProcessingTask` 续跑，实际时间由系统决定。处理过期不丢已完成身份，未完成文件下次重算。

固定任务标识为 `dev.moonread.Moonread.full-index.processing`；ContinuedProcessing 许可模式为 `dev.moonread.Moonread.full-index.continued.*`，实际注册／提交 `dev.moonread.Moonread.full-index.continued.<UUID>`。两项列入 `BGTaskSchedulerPermittedIdentifiers`，`UIBackgroundModes` 增加 `processing` 并保留原项；标识前缀发布后保持稳定。提交失败仍可前台执行，不承诺后台一定获调度。模拟器验证不能代表真实后台调度或 iCloud 下载释放已验收。

BGTask 的 launch／expiration 回调显式非隔离且 `@Sendable`，只在切到 MainActor 后接触索引状态；不能依赖闭包写在 `@MainActor` 类型内便由系统在主线程调用。通知进入界面之前同样明确投递到主队列。

## 产品目标

让读者在系统中更容易继续正在读的书、找到书和导入文件。所有入口共用现有开书、正文 SHA、位置恢复和统计规则，不另建一套阅读状态。优先展示书籍与续读动作，统计作为辅助。

## 灵动岛与实时活动

用户提出阅读中退出应用后，希望仍有灵动岛与实时活动入口。苹果的 [Live Activities 设计规范](https://developer.apple.com/design/human-interface-guidelines/live-activities)面向正在进行的任务或事件，并要求任务结束时结束活动；[ActivityKit](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities)负责生命周期与更新，WidgetKit 描述界面。灵动岛是支持设备上的一种呈现位置，不是另一个独立常驻组件，也不能保证永久显示。

建议方案（产品提案，未实现）：

- 阅读会话内展示书名、当前章节、已累计的有效阅读时长，提供返回当前书入口。紧凑布局不塞正文或多个统计指标。
- 切到后台或锁屏，立即暂停阅读计时与覆盖累计。如果保留短暂续读窗口，必须标明“已暂停”，冻结时长；返回正文后沿用既定计时规则。不能因为卡片还在而继续计时。
- 用户结束阅读、换书时结束旧活动；后台暂停最多保留多久、默认是否自动开启，留待实施前确定。不要把“退出后一直存在”作为承诺，长期续读由小组件承担。
- 锁屏隐藏书名/封面的选项、用户关闭实时活动、无灵动岛设备、系统移除活动、应用被终止都需可用降级；任何入口打开应用后重新校验书籍及来源状态。
- 实时活动不赋予应用持续后台执行能力。后续若展示下载进度，须先确认真实下载任务的后台生命周期；不得让活动显示的进度代替实际任务。
- 未来若做朗读，优先使用系统媒体播放与 Now Playing/远程控制，不用虚假音频后台模式维持阅读活动。

以上是月读的产品建议，不是苹果规定的阅读器专用方案。当前不实现新计时模式、不加入阅读目标或预计读完时间。

## 系统能力与状态

| 状态 | 系统能力 | 月读用途与边界 |
| --- | --- | --- |
| 1.3 已接线 | 主屏幕/锁屏小组件（WidgetKit） | 桌面、锁屏、待机默认显示书名与进度，首版文字封面；用户自行添加。共享轻量快照，允许短暂陈旧，不依赖秒级刷新；不做默认隐藏/显示详情开关，重启首次解锁前等平台限制如实降级 |
| 1.3 已接线 | App Intents / App Shortcuts | 继续阅读、打开指定书、查看统计；Siri 可说书名、直接回答今天/本周时长，允许未排除的已读书续读 donation。只进入正文还不能立即算一次有效阅读；需复用实际正文计时与正式续读规则 |
| 中 | 实时活动/灵动岛 | 按上节保留阅读会话与短暂暂停续读入口；先确定结束和暂停规则，再实施。无灵动岛设备仍验证锁屏呈现 |
| 1.3 已接线 | 控制中心、锁屏按钮、操作按钮（Controls） | 复用“继续阅读”动作，供用户配置系统入口；避免与小组件创建不同的续读规则 |
| 1.3 已接线 | Spotlight 书籍检索 | 以书名、作者、标签找到书并打开；使用设备私有索引。默认开启，设置提供开关与书架排除，无 onboarding 选择；未识别正文 SHA 的书先不公开，首版不索引小说全文或私人批注；删除/改名/来源失效要同步处理 |
| 后续 | Handoff（NSUserActivity） | 从另一台支持月读的设备接着读。先完成真实 iCloud 双设备验收；传递书籍身份与位置，接收端检查同 SHA 原文可用。Handoff 不负责自动传输小说或阅读数据库 |
| 后续 | 系统媒体播放集成 | 仅在朗读功能实施时考虑后台音频、锁屏播放控制、耳机控制、中断和音频路由。当前纯文本阅读不接入 |

当前代码已有原生文件选择/文档打开、分享导出、TXT 分享接收扩展、选字系统查询与翻译等基础集成。分享接收用 App Group 原字节暂存，由主 App 自动导入固定根目录，复用同名确认；不在扩展执行全文解析，详见[分享接收](../data/README.md#txt-分享与默认打开)。1.3 已接入 WidgetKit、App Intents 与 Core Spotlight；ActivityKit 和 Handoff 仍是提案，不属于当前能力。无独立 Watch App、CarPlay 或通知提醒需求，不因系统支持就增加。

共享快照采用 `completeUntilFirstUserAuthentication`，不对书名/进度默认附加 privacySensitive 遮挡。BookEntity 保持最小字段，画廊用合成书名；同 SHA 任一已知来源被排除即不索引/捐赠。AI 总开关与实际发送许可维持原规则，系统集成不调用月读 AI 或上传正文。

## 小组件（1.3）

`MoonreadWidgets` 扩展仅加入 `group.dev.moonread.Moonread`，不加入 CloudKit 或小说目录权限，不链接 Rust、SwiftData 或 AppDataService。只读 `SystemReading/v1/catalog.json`，不读取 ShareInbox、正文、批注或凭据。共享文件版本为 1，先编码完整候选，再在主 App 的配置/请求代次检查后原子发布；全文书目查询和编码不占用存储 actor。扫描/身份批次结束、改名/移动/来源恢复、元数据/云导入/清除、换书/离开正文与后台等事件刷新；密集位置更新最多每 30 秒一次。平台 reload 不承诺即时呈现。

一个阅读 Widget kind：`dev.moonread.Moonread.reading`；支持桌面小/中、锁屏 rectangular/inline，待机沿系统布局。配置最近阅读或指定书籍，默认展示书名和已知进度，首版文字封面。缺失/未知版本/首次解锁前不可读时为通用项；指定书籍失效仍保留原目标，不能改开另一部最近书。画廊与设置预览只用合成书名。没有默认隐藏详情开关，也不强制 unredacted 绕过系统保护；保护级别为首次解锁后可读。

继续阅读 Control kind 为 `dev.moonread.Moonread.continue-reading`。主 App 与扩展共同包含 OpenIntent 声明，但扩展分支不初始化任何 App 服务；当前系统显式限定主 App，iOS 18 沿平台 OpenIntent 前台语义。快捷指令提供继续阅读、我的书架、搜索书籍（可选关键词）、今天/本周阅读统计、打开指定书籍，短语与名称均有简中、繁中、英文。我的书架进入内置书架根目录，搜索使用 App 内现有搜索页；另可用“打开月读”的统计页面目标进入总览。统计时长由现有 Rust 投影返回总量，日期范围及格式沿 StatisticsDates，不在 intent 重做事实合并。普通读取失败/不完整不能回答为零。

目前本地验证保护应用规则、快照、假平台适配器与 App 内续读/设置流程。Siri 识别、系统 Widget/Control 可见性、锁屏、进程归属和真实 iCloud 交付仍由真机试用确认；iOS 18 实机尚未验证，不能把当前 SDK 的低部署目标编译等同于实机验收。

## 离线与空间管理的含义

- **提前下载供离线阅读**：主动选择一本或多本云端书籍，获取本机副本并准备正文，完成后检查实际离线可读性。当前开书时下载与进度已有，独立批量离线入口尚无。是否能保证长期保留由文件提供方能力决定，不把一次下载成功描述为永久驻留。
- **移除本机下载**：只回收云文件的本机副本，保留已确认存在的云端原件，下次阅读需要重新下载。iCloud 有 `evictUbiquitousItem(at:)`；外部提供方不能假定支持相同操作。
- **清理可重建缓存**：回收派生正文、索引等可重新生成内容；保护正在阅读的资源，明确重新准备成本。用户封面、批注、阅读位置、统计与源文件不归入缓存。
- 仅本地存在的小说不能用“释放空间”直接删除；真正删除小说仍是独立文件操作。未完成上传或无法确认云端原件时不回收唯一副本。

苹果[磁盘空间管理文档](https://developer.apple.com/documentation/xcode/reducing-your-app-s-disk-usage)明确区分回收 iCloud 本机副本与删除文件。交互应分别命名“移除下载”和“清理缓存”，避免一个模糊清理按钮跨越数据边界。

## 实施依赖与验收

1.3 的系统入口共用开书路由、共享快照与失效处理；App Intents、Spotlight 与小组件同一批次接入。实时活动仍需单独确定生命周期。Swift 负责系统扩展和平台交接，Rust 保持书籍身份、位置与统计事实。系统入口读取失败时回到可恢复页面，不能静默打开另一部同名书。

验收至少覆盖：前台/后台/锁屏统计不多算、冷启动和已运行应用续读一致、原文移走或尚未下载、同书多来源、锁屏与待机正常展示书名/进度、首次解锁前占位、系统关闭扩展能力。小组件刷新和实时活动可见性受系统调度，不承诺秒级刷新或永久常驻。

## 官方依据

- [WidgetKit](https://developer.apple.com/documentation/widgetkit)：小组件、实时活动界面与系统控件。
- [App Intents](https://developer.apple.com/documentation/appintents)：将动作与实体提供给系统体验。
- [Controls](https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system)：控制中心、锁屏和操作按钮。
- [Core Spotlight](https://developer.apple.com/documentation/corespotlight)：设备上的私有内容索引。
- [NSUserActivity](https://developer.apple.com/documentation/foundation/nsuseractivity)：活动状态与 Handoff。
- [系统入口深链](https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity)：点按后进入对应内容。

以上依据在 2026-10-01 查阅；官方能力说明与月读建议分别表达，具体系统支持范围在实施时按 SDK 和设备验证。

## 技术合同与状态

已接入的索引后台任务仍按当前实现；1.3 App Entity、Spotlight、Controls 和 Widget 的共同数据源、失效、路由与平台边界见[系统集成技术合同](../engineering/system-integration.md)，本节设计默认不表示已经实现。Live Activities/Handoff 仍是后续候选，不随小组件范围自动进入1.3。
