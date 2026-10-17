# iCloud 文件与阅读数据同步

更新：2026-10-02。用户数据已正式切换为 SwiftData + CloudKit 自动同步；正文和文件索引保留 Rust，文件交接规则不变，真实云容器和跨设备联调尚未完成，限制见[接入实施](icloud-implementation.md)。原始 TXT 与真实目录使用 iCloud Documents，设置和 SHA 下的阅读数据使用 CloudKit；不把小说原件放入 CKAsset。统一书架模型见[数据与来源](README.md)。

## 两条同步边界

| 数据 | 保存与同步 | 身份依据 |
| --- | --- | --- |
| TXT、文件名、真实子目录、移动与删除 | 本地目录或 iCloud Documents；iCloud 文件由系统同步 | 真实文件及其所在目录 |
| 进度、书签、批注、人工章节修正、阅读事实 | SwiftData 与自动 CloudKit | 正文 SHA；标记另有稳定 ID |
| 配色方案本身 | SwiftData 与自动 CloudKit；显示选择和排版偏好留在设备 | 设置字段及配色 ID |
| 缓存、授权、任务与设备状态 | 留在本机 | 本机状态 |

CloudKit 不再重复保存一份藏书目录清单、文件夹树或 TXT 附件。目录提供的文件清单是来源事实，本机索引用于展示和快速定位；有阅读记录但暂时没有原文件是正常状态。

应用运行中的 SQLite/WAL 仍放在私有目录，不用 iCloud Drive 覆盖数据库。[SQLite：运行中复制限制](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)

## 内置目录与系统文件管理

我的书架由应用在自己的 iCloud ubiquity container 下创建公开的 `Documents` 目录，可在“文件”和 Finder 中查看。容器与相对根由应用固定配置，实际 URL 向系统取得；不让用户选根或修改绑定位置。配置 `NSUbiquitousContainers`、公开文档目录和允许任意子目录层级。[Apple：公开文档目录示例](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)

用户通过系统选择器添加的其他根使用 security-scoped URL/bookmark；授权允许访问目录内容并执行相应文件操作，实际可写性仍由文件提供方决定。它们与内置目录使用共同的树和操作规则。[Apple：目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)

普通读取、改名、移动和删除采用 `NSFileCoordinator`；文件呈现与观察更新跟踪外部变化，目录清单不能只依赖长期不变的绝对 URL。iCloud 根通过元数据查询发现文件及状态，外部根用提供方支持的协调访问和变更机制；平台适配差异不扩展为两种书架业务。[Apple：iCloud 文件协调与发现](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)

应用内不提供重命名、移动、移除我的书架根入口或改变其位置的操作，内部文件与子目录仍可管理。容器确认可用而固定目录不存在时可以创建空根；绝不从阅读缓存重建用户已经删除的 TXT。

## 固定目录与同步控制

**内置的本地目录和 iCloud 目录均由应用固定管理，用户不能配置位置。** 未启用 iCloud 时本地保存；启用后读取系统容器 URL 并使用固定相对目录。容器 API 返回空只说明云容器不可用，不阻止应用在自己的本地目录接收文件。[Apple：获取容器](https://developer.apple.com/documentation/foundation/filemanager/url%28forubiquitycontaineridentifier%3A%29)

同步设置与目录绑定分开：

- **阅读数据 iCloud 同步。** 控制 SwiftData 用户数据的 CloudKit 自动同步；默认关闭，开启后合并；主动关闭切回本机配置。
- 已经在 iCloud Drive 的文件继续遵守系统同步行为；关闭阅读数据同步不移动、删除或承诺暂停这些文件。用户也可以给外部书架选择云目录，这与上述开关独立。

不增加用户自选书库位置、根切换或整库迁移设置。应用用普通本地文件存储和 `setUbiquitous(_:itemAt:destinationURL:)` 等系统 API 完成本地文件进入固定云目录，保留层级并处理目标重名；失败仍有可靠原件，完成后不继续维护本地/云端双向镜像。[Apple：本地与 iCloud 文件移动](https://developer.apple.com/documentation/foundation/filemanager/setubiquitous%28_%3Aitemat%3Adestinationurl%3A%29)

Apple 的 iCloud 设计指南明确建议不可用时将新内容保存到应用本地容器，账户恢复后移入 iCloud。实现要处理可用性通知和文件交接；系统不会把一个不可用的云 URL 自动改成普通本地目录。[Apple：iCloud 可用性变化](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)

**同步暂停的 API 边界已核查：** iOS 26 起有按文件/包暂停和恢复的接口，依赖提供方能力；本机 iOS 27 SDK 的 `NSFileManager.h` 明确普通非包目录不支持该暂停。这不构成整棵书库的通用开关，且不覆盖最低 iOS 18。本轮不靠逐文件暂停来模拟整库关闭。[Apple：文件同步控制](https://developer.apple.com/documentation/foundation/filemanager)

暂时断网时继续使用可访问的本地 iCloud 文件，不因为网络变化重建书架。未登录、关闭 iCloud 或云容器不可用时，新内容仍能进入固定本地目录，沿用同一我的书架界面；已有云文件如不可访问则按实际状态显示。退出或切换账户不自动把旧原件或用户记录搬到新账户。完整规则见[本地导入](README.md#未启用-icloud-时照常导入)，此能力不再列为待确认项。

## 原文下载与离线阅读

通过元数据先显示目录和文件，打开需要原文时请求下载；应用不为列书主动下载整棵树。系统可能自行预取或回收原文件的本机副本，因此不宣称完全控制 iCloud 的调度。

取得可读文件后复用现有渐进正文准备；完整准备的规范正文留在本机支持离线阅读。云端原件首次需要下载时不能假定可直接边传输边解析，仍以提供方交出的可读文件为准。

“移除本机下载”调用平台的本机副本回收能力，只有原件已可靠上传才允许回收；“删除文件”先将目标云文件移到系统“最近删除”，由系统传播删除与恢复；移到最近删除失败即按不支持处理，本批由用户确认永久删除或跳过，不静默降级。阅读缓存的清理与平台文件回收分开处理，不删 SHA 下的私人记录。[Apple：本机副本与删除的区别](https://developer.apple.com/documentation/xcode/reducing-your-app-s-disk-usage)

## 用户数据范围与唯一写入入口

SwiftData 的 `UserDataStore`（ModelActor）是用户数据持久化入口。`ReaderService` 负责正文身份、设备偏好和业务接口；Rust 只接收临时计算输入。已删除 Rust 用户表、修订队列与 CKSyncEngine，不能恢复成双写。

| 数据 | 保存与同步 |
| --- | --- |
| 小说作者、简介、标签、手动状态 | SwiftData；字段独立、标签按成员保存，按 SHA 关联 |
| 自定义配色方案本身 | SwiftData；当前使用的配色、明暗及动效留在本机 |
| 正式位置 | SwiftData；完整更新不可变、按更新时间和稳定标识取最终结果，淘汰旧更新，不提供备选位置或恢复历史 |
| 书签、批注及人工章节修正 | SwiftData；按 SHA 关联，不依赖本机有原件或正文缓存 |
| 阅读事实与清理边界 | SwiftData；片段 ID 防止重试重复，各设备独立事实全部累加，时间重叠不扣除 |
| 用户封面 | SwiftData `UserCover.bytes` 使用 `.externalStorage`，附件可能晚于引用到达，暂缺时显示文字封面 |
| 字体、字号、行距、边距、行宽、缩进、阅读模式、亮度、方向、常亮、统计记录开关 | 本机 UserDefaults；不同设备独立 |
| 根授权、路径、上次文件、最近隐藏、任务描述 | 本机；不传入 CloudKit |

没有唯一约束或必须共同到达的关系。普通字段每台设备保存最终快照，通过包含更新时间和稳定标识的完整载荷取最终值；没有主动上传默认偏好。位置更新使用独立不可变对象，淘汰旧对象不会与其他设备离线改写同一个对象发生删除竞争。

### 批注：保留完整候选，用户解决真实并发

范围、摘录、评论是一个完整载荷，存于独立 `AnnotationOperation`。每次操作保存所依据的候选标识和因果标识；后继明确取代自己的基线，不取代尚未见到的并发候选。连续编辑删除旧内容，只保留当前候选与判断离线并发所需的标识，不建设批注历史库。

- 完全相同的修改不作为冲突；不同范围即使评论都为空，也属于冲突。
- 基于旧内容删除与新编辑是并发候选；基于新编辑删除就是明确删除。
- 本地相交批注的评论按正文顺序以两个换行连接，确认后合并为一条。被合并条目若出现离线新编辑，通过业务关联进入同一个编辑页处理。
- 编辑页展示候选的摘录和评论，每个候选卡片内有“使用这一版”按钮，另有次要按钮“保留两者”，并可手动编辑最终评论；选择不依赖卡片顺序。选择同时采用相应范围；保留两者取范围并集并重新读取摘录。三个以上候选仍在同页呈现。
- 编辑会话按范围链式相交与已合并条目的关联收集全部参与批注。进入编辑、远端更新和保存检查同一组候选；普通保存拒绝任一参与条目的未解决冲突。解决时重新核对整组条目与候选标识，新增条目或候选使旧选择失效。
- 选择删除后显示明确删除状态并收起输入区；关闭保留原冲突，完成才删除，重新选择可改为保留及手动编辑。没有读取曝光或“用户看过”检测，也不将 Git 标记写入评论。
- 多条删除与撤销在存储事务中写入；撤销依据本次删除操作，不能静默覆盖随后到达的新编辑。

自动 CloudKit 同步只传递独立对象，业务层才判断候选。以上本地语义测试不能证明真实 CloudKit 会按预期交付所有并发对象，必须继续双设备验证。

### 阅读事实、清理与正文准备

`ReadingFact` 保存稳定片段 ID、设备、会话、连续访问、UTC 起止、发生地自然日/时区、查阅类型及可见范围证据。Rust 保留 120 秒闲置、15 秒切片、午夜和连续 3 秒覆盖计算，统计查询从 Swift 提供的 TEMP 输入聚合，不持久化用户事实。

清理不动 TXT、批注、书签、位置或小说信息。记录开关和本机代次在 ModelActor 的写入门槛中检查；旧队列不会因暂停/清理后重试而重新入账。同步清理边界包含目标书/会话、已知事实 ID 和清理时刻；迟到的已知事实及清理时刻以前的目标片段不再参与聚合。跨设备时钟偏移及离线新事实的真实清理传播仍须云端验证，不能以本地注入替代。

完整 SHA 确定前，位置、标记和事实进入 `.none` 的设备 SwiftData 存储 `pending-users.store`。准备完成后，先按稳定身份事务写入正式用户存储，再移除设备暂存，重试不重复创建事实；失败保留任务映射供导入继续，格式演进须保持旧任务可恢复。导入任务回收在用户数据已归入 SHA 后执行。批注未提交编辑仅属于当前会话；取消直接丢弃。

### 同步启停与账户

默认关闭阅读数据同步。用户的开启意愿单独持久化，实际自动同步可以暂停；账户不可用、变化或初始化失败不会关闭开关。同一个已确认账户恢复后尝试恢复同步。只有用户主动关闭才写入关闭意愿，随后使用 `.none` 重新建立本机容器；启用使用 `ModelConfiguration.cloudKitDatabase.private`。

不同账户暂停并提供设置中的确认入口。确认针对当前本机仍存在的阅读数据，冻结目标账户，并在启用前重新核对；账户再次变化则重新确认。取消不启用同步，前台恢复不反复弹窗。已确认账户的初始化失败可以重试，不重复索取相同确认。此确认不移动小说文件，iCloud Documents 原件的账户保护独立执行，不增加账户管理中心。

退出账户或在系统中关闭应用 iCloud 后，云支持存储中的本地及未同步数据可能被系统清除；不保证保留，也不增加备份或恢复层。这是 [Apple 框架工程师确认的系统行为](https://developer.apple.com/forums/thread/811294)。应用主动关闭阅读数据同步与系统退出账户是不同操作；两者都不授权搬迁或删除 iCloud Documents 小说。

系统调度自动同步；界面根据 `NSPersistentCloudKitContainer` 事件显示运行状态及成功时间，不把一次本地保存声称为同步完成。SwiftData 没有本项目使用的公开强制同步接口，界面显示系统自动同步，不保留误导性的“立即同步”按钮。

启停后旧容器的在途操作、账户切换期间的系统镜像隔离、附件自动同步及两设备离线并发尚未实测。相关验证条件见[接入实施](icloud-implementation.md)。

## 验证边界

本地模型、因果归并、删除/撤销、独立事实累加、附件外存与重启已纳入回归。iCloud 签名、同账户两设备上传/下载、离线乱序、账户切换和附件迟到必须在真实云环境验收。没有将本地双 context、单 actor 注入或模拟器构建当作云端验证。

官方接口依据：[SwiftData 自动 CloudKit 同步](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)、[ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor)、[外部存储属性](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)。

## 云交接的执行与恢复

已完成交接、根未变化且无待交接标记时，在查找容器、读取 receipt、协调或枚举之前返回；快开 reuse/导入完成不再无条件调度交接。冷启动检查及真实新本地文件仍可启动待交接恢复。

真实交接的校验、协调读写、枚举、receipt 持久化及原件清理在后台 I/O 队列执行；共享 ReaderService actor 只接收准备好的结果，重验账户、根与 ImportSource 快照，避免 await 期间变化后错误发布。源与目标协调访问保持到 actor 原子发布完成，顺序为索引提交→published receipt 落盘→原件清理。不能为了响应速度缩短必要权限持有期或提前删源。

回执中的路径、期望原始 SHA、复制状态、published、file id/关联/解码策略用于幂等恢复，不是另一套内容身份。删源前在同次协调中重新核对源与目标字节；目标被逐出、不可读或已替换时保留源，源缺失仅允许已发布状态。账户隔离、完整源检查、同名冲突、路径越界和符号链接保护不变。完整定位规则见[SHA 关联](README.md#文件定位与-sha-关联)，调度原则见[性能设计](../engineering/performance.md)。

## 同步 payload 的 v1 边界与隔离

发布后的扩展优先使用新 key / 新记录类型；不要向既有对象追加旧版会忽略的字段。改变既有意义的新类型（例如新的清除或合并规则）必须同时在相关作用域写一条旧版认识的高 `v` 标记，让旧版停止编辑该作用域。已发布的类型、key、作用域与排序元数据含义保持稳定。CloudKit 生产 schema 只增不删。

同步字符串 payload 的顶层 envelope 使用整数 `v`，缺失单独视为 1；非整数、非法版本或高于 1 不理解。版本覆盖内层 value，不在嵌套对象重复，也不在 SwiftData `@Model` 上添加版本属性。校验集中在 Swift `UserSyncJSON` 存储边界，不给 Rust/UniFFI 类型增加 serde Map；通过校验后才交给计算投影。整数字段按声明宽度直接解码，不先经过 Double。

v1 写入所有字段，Optional 的 nil 显式写 `null`。读取同时检查**键集合与类型**：必需键缺失、null 用在非 Optional 上、错误类型、未声明字段（含嵌套对象）、解码失败都隔离。兼容字段默认值白名单当前为空，只有未来另行声明的新增字段可采用安全默认。开发期旧的省略 nil 编码不兼容；生产 CloudKit 为空，发布前由开发者删除重装开发版、清理开发环境数据，不增加旧编码读取分支或运行时自动清库。

| 顶层记录 | v1 字段（除可缺失的 v 外，其余键必须存在） |
| --- | --- |
| UserValue / UserPosition | updated（Int64）、token、value（JSON 字符串） |
| AnnotationOperation | id、ancestors、content、created（UInt64）、bookmark、relatedMarks、mergedInto |
| ReadingFact | content_key、title、device、slice |
| StatisticsClear | book、session、through（Int64）、ids |

批注 `content:null` 是删除 tombstone，`mergedInto:null` 是未合并；`relatedMarks` 总是数组。统计清除的 `book:null` / `session:null` 才表示不限定该维度，缺键不能解释为全局。位置内层字段为 content_key/offset；章节为 content_key/offset/title/level/excluded；批注 content 为 start/end/excerpt/note。slice、exposures、cover、调色板及颜色对象逐层使用当前声明的完整字段集合；UserCover 的 bytes 不加 envelope，约定同 id 字节不可变。不支持的封面格式显示占位并保留引用与原字节。

v1 key 白名单：`position/{contentKey}`、`chapter/{contentKey}/{offset}`、`palette/{id}`、`metadata/{sha}/{author,synopsis,status,cover,tag-*}`。遍历、投影、批量操作和 pending 转移不处理未知 key；保留其原始记录，metadata 只投影已知属性。内层 null 仅用于声明允许删除的章节、封面、标签、调色板；author/synopsis/status 必须是字符串。

隔离不修改、不重编码或删除原 payload，不选择一个旧的可理解候选把它遮住，也不当成普通冲突自动解决：

- **位置**：只要该书存在无法理解的候选，就不压缩、不写入/删除候选；不把旧位置作为新的有效投影。pending 身份转正后仍保护其对应正文身份，阅读界面提示更新，正文可继续读。
- **批注**：该 mark 的全部候选保留，不压缩、不返回为可编辑内容；append、删除/撤销、合并和 resolve 都先检查隔离。无关 mark 仍可处理，关联到隔离 mark 的整组编辑停止并提示更新。
- **书目与目录/主题值**：不以错误记录的缺省值开启编辑；已知 key 的写入被拒，完整书目编辑入口在无法理解已知书目字段时停止。新增未知 key 不妨碍现有独立 key。章节恢复不会删除未知 key。
- **统计清除**：无法理解时，若 book/session 两个键都存在且类型可解释，阻断与其相交的统计展示和清除；无法判断作用域则阻断全部，提示“统计数据来自更新版本，请更新 App”。包括已显示的旧统计，不能只禁用清除按钮。全库统计包含该作用域，因此也阻断。
- **统计事实**：不理解的事实保留、不参与计算；同 id 有未知副本时不选择一个旧副本代替。相应统计页（包括按日页）提示“统计不完整”。
- **pending**：转移与删除前检查同一作用域的记录；源端不理解则不导出/删除，目标端不理解或传入快照不完整则事务不导入。转正快速路径不能绕过后来到达的未知记录。只转移已知记录类型，未知 key 留在原处。

阅读状态是独立字符串 key，未知字符串保留为带原值的 Other，不当作未读、不触发自动升级到“阅读中”，显示“其他（当前版本不支持）”。编辑作者等其他属性不写回状态；只有用户明确选择已支持状态才替换。AI `search_books` 状态过滤支持 `other`，未指定状态时为全部；写入建议仍只接受已知状态，不创造丢失原值的“其他”。

### 并发语义与验证边界

UserValue 按 `(updated, token)` 做整值 LWW；位置候选写入与压缩也遵循这一顺序。并发位置或同一独立属性互相覆盖是允许的产品语义，`v` 不能保全离线设备从未看到的新信息。需要保全的新数据必须拆为独立 key、独立不可变记录或显式字段级合并，不能声称“保留未知字段”就解决跨版本 LWW。批注沿用因果候选而非整对象 LWW，统计事实/清除是不可变记录。

隔离状态依据**仍存在的无法理解记录**计算，不依据哪个 v1 候选最后到达；后到或时间戳更高的旧版记录不能解除隔离。验证必须经 UserDataStore/ReaderService 的真实保存链路，覆盖 v1→v2 与 v2→离线 v1 两种到达顺序、压缩/append/清除/pending、未知嵌套字段、缺失/null/错类型、整数精度与明确修改状态；本机模拟导入不等同于真实双设备 CloudKit 验收。
