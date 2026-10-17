# 性能设计与待优化

现行设计核对：2026-10-13。本文维护已采用的性能边界、诊断方法与未实施候选；实际测量、用户反馈、构建和安装证据只记在[验证记录](verification.md)。候选由 [roadmap](../roadmap.md#性能待优化) 索引，不构成自动开始开发的授权。

## 开书关键路径

`LibraryModel.open` 点按 → 文件可用性准备 → `OpeningRequest`/系统 push → `ReaderSession` 创建 lease/启动 worker → 后台协调读原始 SHA → 快开 reuse 或渐进导入 → 单书 snapshot/frame → window/settings/anchor 安装 → UIKit/TextKit 布局 → 可见正文。文件下载留在书架反馈；原生导航与准备可重叠，不把动画、SHA 和排版各段机械相加。

- 内容身份始终是规范正文 SHA-256；每次打开完整验证原始字节，快开键包含解码策略。`sha2 0.11` 使用可用的硬件 SHA 后端，摘要仍为 64 位小写十六进制。首次未命中仍需解码一遍并校验期望 raw SHA，不恢复路径/mtime 快开，也不预哈希全书库。详见[文件身份](../data/README.md#文件定位与-sha-关联)。
- 就绪通知以带代次的 waiter 唤醒；先读代次、查询、再登记等待，消除完成与订阅之间的漏信号。worker token、attempt、monitor、leave 共同过滤迟到返回，超时仅作兜底。完整生命周期见[开书流程](../reader/import.md#就绪通知与生命周期)。
- settings 从验证后的内存副本读取。lease 发布后监测不等待统计启动；统计启动任务带 attempt token，离页取消并 stop，防迟到 clock/timer。只有正文可读才累计，晚启动不回填此前时间；释放阅读 lease 不等于取消独立 worker。
- 正文就绪且准备扉页未显示时直接显示，允许在 push 中出现。仅 push 完成且 routeRequested 满 300ms 后显示慢准备扉页，800ms 才显示原生进度和暂停；确实显示过扉页后才做局部 200ms 淡入，减弱动态直接替换。首次正式书籍封面单独处理，不能为测快强制跳过。
- Swift 原生 TextKit 负责字体和有限窗口分页，Rust 不承担 iOS 字体度量。已有页边界复用、交互期间推迟窗口替换和有界块预算，不能把整本文件大小直接等同当前排版量。

## 单书投影与保存

`UserDataStore` 按 content SHA/pending key 取单书所需位置、资料、章节覆盖；首次 `openingFrame` 合并 snapshot/frame，使用同一次不可变 ReaderQuery。冷首页确需的批量投影可按输入版本复用；目录只补相关子树用户数据，普通最近列表先读位置索引。需要 facts 的统计/章节查询仍有全量成本，列为下方候选。

位置压缩移到该 key 写入，读路径不写库；CloudKit 导入失效缓存，已知 keys 可按书处理，否则下次该书写入再压缩。缓存要覆盖本机写入、远端导入、pending→SHA、统计开关/清理代次、最近隐藏和首选文件变化；查询版本一致，不能缓存混合代次结果。query 保留独立不可变 TEMP 输入，不换回共享可变投影。

pending 恢复与全局 reclaim 在本地首页建立后一次启动；读路径仍含 pending 数据，完成/释放只回收当前已转正且无 lease 的 draft，exportPending 按 key 读取。返回首页只更新刚退出的一本。现有 `savePosition`/`StatisticsWriter.drain` 最终保存契约保留，不增加读取优先票据、维护 actor、固定延迟的全局压缩或同书等待层。

进入后台时同步申请系统 background task assertion，等待 `ThemeStore.flushPreferences`；阅读页后台保存等待 `ReaderSession.flush`。结束或到期释放 assertion。保护已接受的保存，不用取消写入换开书速度，也不承诺系统到期后仍无限运行。

## 共享 actor 与文件协调

actor 串行隔离不等于工作短，也不等于新读取能抢占旧同步调用。将一个 Task 标为 utility/detached，若最终仍在相同 actor 中同步 fetch、解码或协调 I/O，读取仍会排队。必须分别看 enqueue→begin、同步执行和 await 返回恢复。

云交接已采用完成态快速返回、只为真实待交接工作调度，以及后台 I/O 队列执行协调/枚举/校验。actor 只接收准备好的结果并重验账户、根和来源；协调访问保持到原子发布，receipt 落盘后才清理源。详见[同步执行与恢复](../data/sync.md#云交接的执行与恢复)。这些保障不能为了并行而删除。

经验：先 profile 用户真实入口和实际构建开关。测试夹具、模拟器、benchmark 关闭的云路径不能验证生产竞争；旧 await 的半秒跨度不能直接归因于投影 CPU。后台扫描、统计、AI 和封面工作均应有界、可合并，并避免在共享执行器上追加长同步工作；其余路径是否需要拆分由真实数据决定。

## 首页稳定

主题与本地 `HomeSnapshot` 共同决定揭幕，封面共享订阅预热子预算 150ms、根等待上限 1s；不设最短停留。扫描、iCloud/CloudKit 新数据、AI 不加入遮罩条件。快照原子发布、等值不发布、稳定 ID、固定封面尺寸、被动更新无隐式动画、自动刷新静默。热恢复保留已有画面，超时不把未知当空库。产品规则见[首页](../design/library.md#本地首屏与后台刷新)，启动外观见[动效](../design/motion-and-moon.md#启动和白屏分层处理)。

## 诊断与测量方法

`ReaderOpenDiagnostics` 由显式 `READER_OPEN_DIAGNOSTICS` 编译条件控制，正常 Release 关闭。诊断包若用于用户日常试用，不带 benchmark、变体或人为延迟参数；记录提交、工作区、编译条件、入口、书是否下载/命中缓存、热状态、字体/模式。日志/trace 可能含用户路径与数据，只保留本机忽略的 build 目录，不提交正文或凭据。

用同一单调时钟和 attempt ID 对齐 tap、fileReadable、routeRequested、push 完成、lease/worker、hash、reuseReady、snapshotRequested/Completed、windowPublished、layout、bodyDisplayOpportunity。现在首次 snapshot 区间已含 frame；后续 refresh 才有单独 frameRequested。`actorOpeningBegin`、`actorProjectionReady`、`actorFrameBegin/End`、`mainActorOpeningResumed` 分别定位入队、投影、窗口执行与主线程恢复。必要时细分 SwiftData fetch/JSON 编解码/queryBuild、字体构建/属性文本/TextKit ensureLayout、协调排队/进入 accessor。

display-link、onAppear、layout completion 都是程序代理，不能声称光学首像素或完整不透明。录屏逐帧另记准备扉页、正式封面、正文首像素、淡入结束；变帧率使用 PTS。Instruments 包含等待线程并对齐 signpost；inclusive 样本不可相加当 wall time，等待权重不可当 CPU。

日常交付优先用用户原目录中的小书/20MB+ 长书各少量立即重开、等一会重开的对照，A→B→A 位置、翻页选字、冷首页立即开书和后台恢复。若仍复现，取已有 JSONL 的失败/成功各 2–3 次，先定位再考虑一次短 trace；不自动追加长真机循环。命中缓存的小阶段反复超过约 100ms、或相较稍等重开差约 100ms 可作定位线索，不是 SLA；少量样本不报告 P95。

专门性能实验需另按授权执行：同包交错消融、小/长书、首次/续读、热缓存/进程冷启、静止/云刷新、真实库/隔离库分组，每条件足量采样再报中位数、P95、最大值。重启进程不等于清空 OS 缓存。状态机用可取消延迟 gate 测 299/301、799/801ms、ready 与 timer 同轮、取消/旧 worker、push 中返回/取消 pop、无回调 watchdog、后台和错误；不修改原书、不延长协调访问、不拿测试延迟算性能。

首页内部测量尚需 `rootTaskStart/themeReady/localPrepareStart-End/shelvesReady/recentsReady/coverRequest-Ready/homeSnapshotCommitted/launchCoverFadeStart-End/scanStart-End/reloadChanged`，区分封面 memory/disk/generated/missing。先前录屏的视觉暴露窗口不能代替本地查询用时。超时、缺图/云端附件、无最近、初装欢迎书计数、真实增删、重复云通知、大字号/减弱动态和滚动锚点按受影响范围验证；证据集中记 verification。

## 待优化

以下保留原评审编号便于定位。代码入口用于复核，旧行号不当作永久证据；当前无专项规模数据的项均属推断。开书 P1-1 的单书投影、设置内存副本、首页稳定与云交接阻塞已经实施，不重复列成待做；验收及仍未覆盖环境见 verification。

| 项目与证据入口 | 剩余风险及建议 | 重新启动的测量条件 |
| --- | --- | --- |
| **P1-2 AI 启动与会话列表**：`AIService.load/connect`、`AIRepository.sessions` | 启动逐个连接会话、每个读取最近历史；未分页会话数和长消息解码可能抢首屏/开书。先加载摘要、打开会话才取历史，仅恢复确需运行/确认/排队的 runtime；不能丢恢复语义。对话列表分页为明确未实现项 | 1/100/500 会话，消息 0.8/20KB，启动可交互、actor/主线程等待、RSS；延迟 AI 初始化消融。单会话回放不能覆盖此成本 |
| **P1-3 统计与章节 facts**：`UserData.visibleFacts/projection(includeFacts:)`、`StatisticsView` | 全事实解码、清理标记遍历、TEMP apply；单书页面期间/累计/活动重复查询。按书/期间下推、同快照批量算、可重建章节范围汇总，实体化查询字段；合并/取消过期查询。exportPending 按 key 已处理，不再列旧全库缺陷 | 1万/10万事实 × 0/100 清理标记，连续切期间；投影字节、CPU/RSS、耗时和废弃查询数。保持时区、查阅、清理、跨设备事实语义 |
| **P1-4 AI 长会话内存与长帧**：`AINativeMarkdown`、`AIConversation` | sizing pool 有界，但 parsed/retained views、高度和用户已加载历史仍可能累计；先测 1000 条及多会话，再决定各缓存 cost 上限、近邻逐出。不能全清缓存导致空白重建 | 缓存项/RSS、流结束/队列换 turn/胶囊消失/拖动结束复合时序。保留历史坏样本，未复现不算修复 |
| **P2-5 搜索规模**：`ReaderTools`、`library_tools.rs`、`AIRepository`、`bookshelf.rs` | 单批有界但 UI hits 持续累计；扫描 sleep 与 UI 节流耦合。跨会话先全 fetch 再筛允许会话，书架搜索全取排序。考虑分页显示/内存窗口、存储范围下推与扫描发布解耦，不静默截断既有全结果 | 高频单字/无命中/regex/1MiB 长行/连续改词，首批、全搜、取消、结果数与 RSS。分批等待的估计不当实测 |
| **P2-6 云刷新与其他文件操作**：`CloudLibrary`、`LibraryService`、`LibraryModel` | 云交接主因已修。剩余 metadata 全量映射、重复通知扫描及其他同步移动/复制/导出是否阻塞共享 actor 待测；按真实变化合并 dirty 代次、保留 single-flight 与原子发布，不因每个等待者补跑一轮 | 393 本含未下载占位、后台变更/下载叠加开书，通知/扫描次数与入队等待；不为摘要/封面下载原书 |
| **P2-7 翻页选字与窗口交接**：`ReadingView`、`ReaderSession`、批注查询 | 已有有限窗口、页边界/coordinates 复用；TextKit、字号/方向变化、选区坐标和大量批注装饰仍在主线程。按窗口修订缓存必要范围，交互中保护当前行/页与选区；实测排版占主导时再考虑当前页及邻页优先、完整排版键缓存、仅实际阅读字体的空闲预热，不无条件预热所有字体或先重写 renderer | 连续阅读、边缘选区拖动、数千批注、调字号/转屏/导入完成；P95/P99/最大帧、CPU、块数/RSS和录屏位置联合判断 |
| **P3-8 封面与首次长书冷态**：`BookMetadata`、`SourceImportWork`、`progressive.rs` | 已有 1600px 下采样、目标像素磁盘缩略图、共享订阅；冷滚动和释放后回看可能重复解码/争用 service。测后再加 cost 有界缓存或独立图像队列。首次 raw hash+解码、恢复重放是正确性成本，保留完整校验 | 393 本冷缩略图命中/解码栈/峰值字节；20MB+/100MB 冷页、下载、热降频下首块/EOF/RSS/取消与耗电趋势，热 SHA 不覆盖这些 |
| **MainActor 调度恢复**：`ThemeStore` 偏好保存及开书返回 | 偏好 queued→invoke 的旧成功样本存在长间隔，但没有 CPU 栈证明具体视图重建。后台保存保护已加，不把同类现象都归为此原因 | 再复现时同时采主线程栈、视图失效和动画事件；先收窄等值发布/重复更新，不仅调 Task 优先级。旧约 337ms 事实见 verification |
| **首页/目录结构更新**：`LibraryCollection`、`HomeSnapshot` | 等值首页稳定不等于目录 grid hosting cell 无重配；真实增删/远端最近项改变仍可能移动。测 opening 状态影响范围，再按行更新；交互期间结构更新延后或恢复 anchor/offset。初装欢迎书 0→1 是否还会暴露、超时兜底与持久首屏缓存必要性待数据 | 原 393 本目录列表/网格实际入口、冷揭幕后立即点书、真实更新时滚动；无动画不能代替锚点保护，不承诺所有结构变化零位移 |

### 开书暂缓项

收益都是条件估计，不能相加，也不是修复后的真机承诺。具体历史阶段数值与限制在 verification。

| 项目 | 预期剩余价值、代价与决定 |
| --- | --- |
| 提前启动 worker/SHA | tap 后已做文件可用性准备；尚可提前的是 lease/worker。正常可隐藏几毫秒到数十毫秒，去掉设置排队后更少。需重划导航前 attempt、权限、lease、取消及失败所有权。**等数据再定，优先于预排版**：只有 worker 迟启且就绪落后 push 才做；未下载仍留书架，不删协调校验 |
| SHA 期间预排版 | 小书几乎无收益，长书假设硬件 SHA 剩 10–20ms 时理论重叠约 0–20ms；可能被 push 遮住或反抢主线程。身份、真实 viewport、安全区、字体、取消及副作用隔离成本高。**暂缓**，仅仍有可重叠空档且纯布局可复用时重启；必须遵守下节候选契约 |
| 后台排版 | 可释放部分主线程 TextKit 预算，端到端可能只省几帧甚至不减；window→layout 包含调度不能全搬走。**等数据再定**：先查重复 rebuild/字体，再拆纯值输入、独占布局对象、generation/viewport/settings 校验、主线程安装；保持选字、翻页和位置 |
| XXH3-128 raw key | 小书接近零，长书硬件 SHA 后可能仅个位到约 10ms，仍须读文件；误命中可复用错误正文，canonical SHA 名字不能补救。**不做**，除非新证据显示哈希仍是主要瓶颈且足够收益值得正确性成本；正文身份仍 SHA-256，不做旧缓存兼容 |
| “会话 50ms 拆分” | 已由单书投影、组合 frame、内存 settings 和移出读路径 recovery 覆盖，**已归并完成**，不得再算“另省 50ms”。仅针对实际残余 lease/draft、hop、建连或重复 apply 定位；保留不可变快照 |

### 预排版候选的必要契约

只有重新决定实施时适用，当前没有预排版：候选由 `OpeningAttempt` 独立持有，不写 session.window/snapshot/book/anchor/hasEnteredBody，不触发 opening 更新、批注、封面、位置、统计或 AI 正文读取。确认后才原子提升。

候选 book_id 在 `openSourceFile` 之前、同一 actor 事务捕获，避免 startImport 已把行指向 draft；确认用受控 canonical id 或正文 SHA+解码策略，不能比较 readingID。只对已开始阅读的续读做候选，首次正式封面保持。

使用真实 viewport/safeArea 的纯布局，或可直接提升的同一个 controller；尺寸未知跳过。离屏期间禁用方向亮度、readingBegan/edge、位置/封面等回调，防双 controller 重复工作。失效键包括 attempt/monitor、文件/确认身份/解码策略、frame范围/段落/用户投影、anchor、hasStarted、hasSameLayout 全字段、字体/DynamicType、viewport/方向/safeArea/compactHeader；纯颜色主题只重绘。云位置/文件变化不提升旧 frame；错误静默降级、迟到候选不覆盖已显示正文。独立记录 prelayoutStart/End、确认、promotion、最终 layout，与无预排版对照。

### AI 列表第二步与显示候选

用户认可 UITableView + 原生 Markdown 第一步手感，**ListViewKit 全面原生化暂缓**。如果再出现跳动/卡顿：先复现分页追加、自适应 hosting cell、拖动结束同时流完成/队列换 turn；不能因历史一次最坏长帧就宣称容器已定因。候选为 ListViewKit 的 apply/append/update、显式行高和按条目保留 view，其余用户气泡、过程/工具、等待、确认/结果/图片/错误/操作栏逐步 UIKit；少量固定卡片可留 hosting。宽度/字号变后可考虑每帧约 4ms 分片预排版，遵守跟随、分页、搜索、键盘和非跟随锚点 ≤2pt 的原规则。参考 FlowDown（AGPL，仅参考不复制）、MarkdownView/ListViewKit（MIT），不因调研提前添加依赖。

流式显示缓冲和平滑跟随已经实施；**逐词淡入仍可选暂缓**。MarkdownView 一次绘制 attributed string，需改绘制层；只有真机观感仍不足时再评估 Litext 公开 API，不 fork/访问私有类型。Markdown 代码行号是用户接受的差异，公开配置出现后才考虑调整；非文本行、缓存回收和 VoiceOver 真实朗读按现有验证边界推进。

### 单书路径的剩余小项

`UserDataStore.projectionVersion` 与 ReaderQuery 签名仍含全局版本，其他书/统计写入可能使当前无 facts 单书缓存 miss；新 draft scope 也不保证跨会话命中。当前缓存约32项有界，单书 preferred 值已按 key 读，不再声称每次单书查询扫描全部 UserDefaults。若有残余热点，再区分位置/资料/章节、facts、可见性/首选等失效域，合并同 scope 的并发构建；先保证 miss 本身足够小，不无证据引入复杂 LRU。

Rust ReaderQuery 的固定建连与 TEMP apply 成本仍存在。只有新数据说明其占主要残余成本时再优化连接或重复 apply，保持独立不可变快照和 search job 持有期。必要的最终位置保存、后台统计 drain、启动恢复与 facts 查询仍应在原入口交错检查，不能把 utility 优先级理解为可抢占或绕过同书最终提交。
