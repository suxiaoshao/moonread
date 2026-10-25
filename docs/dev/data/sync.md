# iCloud 文件与阅读数据同步

更新：2026-10-02。用户数据已正式切换为 SwiftData + CloudKit 自动同步；正文和文件索引保留 Rust，文件交接规则不变，真实云容器和跨设备联调尚未完成，限制见[接入实施](sync.md)。原始 TXT 与真实目录使用 iCloud Documents，设置和 SHA 下的阅读数据使用 CloudKit；不把小说原件放入 CKAsset。统一书架模型见[数据与来源](README.md)。

## 两条同步边界

| 数据 | 保存与同步 | 身份依据 |
| --- | --- | --- |
| TXT、文件名、真实子目录、移动与删除 | 本地目录或 iCloud Documents；iCloud 文件由系统同步 | 真实文件及其所在目录 |
| 进度、书签、批注、人工章节修正、阅读事实 | SwiftData 与自动 CloudKit | 正文 SHA；标记另有稳定 ID |
| 配色方案本身 | SwiftData 与自动 CloudKit；显示选择、阅读纹理/强度和排版偏好留在设备 | 设置字段及配色 ID |
| 缓存、授权、任务与设备状态 | 留在本机 | 本机状态 |

CloudKit 不再重复保存一份藏书目录清单、文件夹树或 TXT 附件。目录提供的文件清单是来源事实，本机索引用于展示和快速定位；有阅读记录但暂时没有原文件是正常状态。

应用运行中的 SQLite/WAL 仍放在私有目录，不用 iCloud Drive 覆盖数据库。[SQLite：运行中复制限制](https://www.sqlite.org/howtocorrupt.html#_backup_or_restore_while_a_transaction_is_active)

## 内置目录与系统文件管理

我的书架由应用在自己的 iCloud ubiquity container 下创建公开的 `Documents` 目录，可在“文件”和 Finder 中查看。容器与相对根由应用固定配置，实际 URL 向系统取得；不让用户选根或修改绑定位置。配置 `NSUbiquitousContainers`、公开文档目录和允许任意子目录层级。[Apple：公开文档目录示例](https://developer.apple.com/documentation/uikit/synchronizing-documents-in-the-icloud-environment)

用户通过系统选择器添加的其他根使用 security-scoped URL/bookmark；授权允许访问目录内容并执行相应文件操作，实际可写性仍由文件提供方决定。它们与内置目录使用共同的树和操作规则。[Apple：目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)

普通读取、改名、移动和删除采用 `NSFileCoordinator`；文件呈现与观察更新跟踪外部变化，目录清单不能只依赖长期不变的绝对 URL。iCloud 根通过元数据查询发现文件及状态，外部根用提供方支持的协调访问和变更机制；平台适配差异不扩展为两种书架业务。[Apple：iCloud 文件协调与发现](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)

应用内不提供重命名、移动、移除我的书架根入口或改变其位置的操作，内部文件与子目录仍可管理。容器确认可用而固定目录不存在时可以创建空根；绝不从阅读缓存重建用户已经删除的 TXT。

## 外部书架的同步提示与本机授权

`UserValue` 新增 `shelf-reference/<logical UUID>`，载荷为 `{schemaVersion: 1, name, locationDescription}`，沿现有 `StoredValue(updated, token, value)` 的 LWW 裁决；来源描述仅接受 `icloud-drive` 或 `file-provider`；其他值的原记录保留并单条隔离，不参与 LWW，也不遮蔽同一逻辑 ID 的可用提示。不包含路径、bookmark、本机 ID 或文件清单。内置根不发布提示。不新增 SwiftData model 或 CloudKit 字段；旧版本保留不认识的原记录，新版本按条目隔离未知载荷，不阻断其他记录或改写未知版本。

`ShelfReferenceBindings`（UserDefaults，schemaVersion 1）仅在本机保存逻辑 ID 与本机授权根的绑定、本机忽略、已处理整架引导及已发布描述。按用户存储/账户分域，首次从本机开启同步时沿用逻辑 ID，后续切换账户不复制旧账户绑定；未知版本只读拒绝覆盖。提示迟到不阻塞首页；目录选择成功后才绑定，不凭同名自动接入。已有设备须先升级并上传提示；重装不保证恢复从未同步过的根。

重新授权或内置根首次可用后，可经现有全量索引重新关联 SHA 用户数据；未下载云文件仍需用户选择包含。同步提示并不授予目录访问权，也不改变[最近阅读逐本恢复](recent-reading-restoration.md)规则。真实跨设备提示与授权恢复的验收单独记录，不能用本地注入代替。

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

SwiftData 的 `UserDataStore`（ModelActor）是用户数据持久化入口。`AppDataService` 负责正文身份、设备偏好和业务接口；Rust 只接收临时计算输入。已删除 Rust 用户表、修订队列与 CKSyncEngine，不能恢复成双写。

| 数据 | 保存与同步 |
| --- | --- |
| 小说作者、简介、标签、手动状态 | SwiftData；字段独立、标签按成员保存，按 SHA 关联 |
| 自定义配色方案本身 | SwiftData；当前使用的配色、明暗、阅读纹理/强度及动效留在本机 |
| 正式位置 | SwiftData；按更新时间与稳定标识取最终结果；同版本保存用于定位原文件的相对路径、文件名、大小和解码策略线索，详见[最近阅读恢复](recent-reading-restoration.md) |
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

启停后旧容器的在途操作、账户切换期间的系统镜像隔离、附件自动同步及两设备离线并发尚未实测。相关验证条件见[接入实施](sync.md)。

## 验证边界

本地模型、因果归并、删除/撤销、独立事实累加、附件外存与重启已纳入回归。iCloud 签名、同账户两设备上传/下载、离线乱序、账户切换和附件迟到必须在真实云环境验收。没有将本地双 context、单 actor 注入或模拟器构建当作云端验证。

官方接口依据：[SwiftData 自动 CloudKit 同步](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)、[ModelActor](https://developer.apple.com/documentation/swiftdata/modelactor)、[外部存储属性](https://developer.apple.com/documentation/swiftdata/schema/attribute/option/externalstorage)。

## 云交接的执行与恢复

已完成交接、根未变化且无待交接标记时，在查找容器、读取 receipt、协调或枚举之前返回；快开 reuse/导入完成不再无条件调度交接。冷启动检查及真实新本地文件仍可启动待交接恢复。

真实交接的校验、协调读写、枚举、receipt 持久化及原件清理在后台 I/O 队列执行；共享 AppDataService actor 只接收准备好的结果，重验账户、根与 ImportSource 快照，避免 await 期间变化后错误发布。源与目标协调访问保持到 actor 原子发布完成，顺序为索引提交→published receipt 落盘→原件清理。不能为了响应速度缩短必要权限持有期或提前删源。

回执中的路径、期望原始 SHA、复制状态、published、file id/关联/解码策略用于幂等恢复，不是另一套内容身份。删源前在同次协调中重新核对源与目标字节；目标被逐出、不可读或已替换时保留源，源缺失仅允许已发布状态。账户隔离、完整源检查、同名冲突、路径越界和符号链接保护不变。完整定位规则见[SHA 关联](README.md#文件定位与-sha-关联)，调度原则见[性能设计](../engineering/performance.md)。

## 同步 payload 的 v1 边界与隔离

发布后的扩展优先使用新 key / 新记录类型；不要向既有对象追加旧版会忽略的字段。改变既有意义的新类型（例如新的清除或合并规则）必须同时在相关作用域写一条旧版认识的高 `v` 标记，让旧版停止编辑该作用域。已发布的类型、key、作用域与排序元数据含义保持稳定。CloudKit 生产 schema 只增不删。

同步字符串 payload 的顶层 envelope 使用整数 `v`，缺失单独视为 1；非整数、非法版本或高于 1 不理解。版本覆盖内层 value，不在嵌套对象重复，也不在 SwiftData `@Model` 上添加版本属性。校验集中在 Swift `UserSyncJSON` 存储边界，不给 Rust/UniFFI 类型增加 serde Map；通过校验后才交给计算投影。整数字段按声明宽度直接解码，不先经过 Double。

v1 写入所有字段，Optional 的 nil 显式写 `null`。读取同时检查**键集合与类型**：必需键缺失、null 用在非 Optional 上、错误类型、未声明字段（含嵌套对象）、解码失败都隔离。位置的 `source_hint` 是兼容例外：TestFlight 1.0.0(2) 未写此字段，缺失按 nil 读取；其他必需字段仍不能缺失。未分发开发版的其他省略 nil 编码不作为通用缺省例外；已发布数据按明确的兼容规则保留，不运行时自动清库。

| 顶层记录 | v1 字段（除可缺失的 v 外，其余键必须存在） |
| --- | --- |
| UserValue / UserPosition | updated（Int64）、token、value（JSON 字符串） |
| AnnotationOperation | id、ancestors、content、created（UInt64）、bookmark、relatedMarks、mergedInto |
| ReadingFact | content_key、title、device、slice |
| StatisticsClear | book、session、through（Int64）、ids |

批注 `content:null` 是删除 tombstone，`mergedInto:null` 是未合并；`relatedMarks` 总是数组。统计清除的 `book:null` / `session:null` 才表示不限定该维度，缺键不能解释为全局。位置内层字段为 content_key/offset/source_hint（历史缺失来源线索按 nil 读取）；章节为 content_key/offset/title/level/excluded；批注 content 为 start/end/excerpt/note。slice、exposures、cover、调色板及颜色对象逐层使用当前声明的完整字段集合；UserCover 的 bytes 不加 envelope，约定同 id 字节不可变。不支持的封面格式显示占位并保留引用与原字节。

v1 key 白名单：`position/{contentKey}`、`chapter/{contentKey}/{offset}`、`palette/{id}`、`metadata/{sha}/{author,synopsis,status,cover,tag-*}`。遍历、投影、批量操作和 pending 转移不处理未知 key；保留其原始记录，metadata 只投影已知属性。内层 null 仅用于声明允许删除的章节、封面、标签、调色板；author/synopsis/status 必须是字符串。

隔离不修改、不重编码或删除原 payload，不选择一个旧的可理解候选把它遮住，也不当成普通冲突自动解决：

- **位置**：只要该书存在无法理解的候选，就不压缩、不写入/删除候选；不把旧位置作为新的有效投影。pending 身份转正后仍保护其对应正文身份，阅读界面提示更新，正文可继续读。 每次打开最多自动提示一次，确认后翻页、批注刷新和自动保存不再弹出；预览导航不因自动保存受阻而停止。主动编辑或请求更改阅读位置仍就地说明受阻原因。
- **批注**：该 mark 的全部候选保留，不压缩、不返回为可编辑内容；append、删除/撤销、合并和 resolve 都先检查隔离。无关 mark 仍可处理，关联到隔离 mark 的整组编辑停止并提示更新。
- **书目与目录/主题值**：不以错误记录的缺省值开启编辑；已知 key 的写入被拒，完整书目编辑入口在无法理解已知书目字段时停止。新增未知 key 不妨碍现有独立 key。章节恢复不会删除未知 key。
- **统计清除**：无法理解时，若 book/session 两个键都存在且类型可解释，阻断与其相交的统计展示和清除；无法判断作用域则阻断全部，提示“统计数据来自更新版本，请更新 App”。包括已显示的旧统计，不能只禁用清除按钮。全库统计包含该作用域，因此也阻断。
- **统计事实**：不理解的事实保留、不参与计算；同 id 有未知副本时不选择一个旧副本代替。相应统计页（包括按日页）提示“统计不完整”。
- **pending**：转移与删除前检查同一作用域的记录；源端不理解则不导出/删除，目标端不理解或传入快照不完整则事务不导入。转正快速路径不能绕过后来到达的未知记录。只转移已知记录类型，未知 key 留在原处。

阅读状态是独立字符串 key，未知字符串保留为带原值的 Other，不当作未读、不触发自动升级到“阅读中”，显示“其他（当前版本不支持）”。编辑作者等其他属性不写回状态；只有用户明确选择已支持状态才替换。AI `search_books` 状态过滤支持 `other`，未指定状态时为全部；写入建议仍只接受已知状态，不创造丢失原值的“其他”。

### 并发语义与验证边界

UserValue 按 `(updated, token)` 做整值 LWW；位置候选写入与压缩也遵循这一顺序。Swift 用户事实层的 `PositionCandidate.winner` 是位置的唯一胜者函数，即时投影、scoped 合并和 pending 晋升共用；投影保留 token，pending 别名归并到正文 SHA 后，每个 content key 只交给 Rust 一条最终位置，Rust 装载时拒绝重复 key。并发位置或同一独立属性互相覆盖是允许的产品语义，`v` 不能保全离线设备从未看到的新信息。需要保全的新数据必须拆为独立 key、独立不可变记录或显式字段级合并，不能声称“保留未知字段”就解决跨版本 LWW。批注沿用因果候选而非整对象 LWW，统计事实/清除是不可变记录。

隔离状态依据**仍存在的无法理解记录**计算，不依据哪个 v1 候选最后到达；后到或时间戳更高的旧版记录不能解除隔离。验证必须经 UserDataStore/AppDataService 的真实保存链路，覆盖 v1→v2 与 v2→离线 v1 两种到达顺序、压缩/append/清除/pending、未知嵌套字段、缺失/null/错类型、整数精度与明确修改状态；本机模拟导入不等同于真实双设备 CloudKit 验收。

## 整书阅读数据删除与备份恢复

整书清除删除当前 SwiftData 中所选正文 SHA 的全部物理候选/副本，由 CloudKit 镜像传播对象删除；不新增 book-reset、删除代次或同步 epoch，不要求所有设备升级。共享封面只有无剩余引用才删除，跨书/全局统计清除保留，配色和小说不动。本机保存成功不表示所有设备已完成删除；关闭同步时不承诺追溯删除未同步云记录。其他设备的新事实及主动导入旧备份允许保存，正常旧备份合并仍保留已有较新数据。

本机串行处理位置 flush 与清除、pending 跨库清理；导出和删除先 drain 等待 StatisticsWriter 的当前写入结束。统计按顺序每批只写一次，失败即丢弃该批、保留错误提示，完成后释放其 lease；没有重试队列、上限或重试入口。删除先清 pending 库，再清正式库，各自一次提交；中途退出仅会剩下正式库数据，列表仍可见，用户可再次删除。不保存删除回执，也不在启动或后续写入时补删。drain 后只检查仍然开着的阅读器，正在阅读时拒绝删除。

不能理解的数据在编辑、合并、导入时仍隔离保护，不能改写。用户主动整书删除是明确的例外：按 `metadata/<key>/…`、`chapter/<key>/…`、`position/<key>` 或记录的 `contentKey` 归属删除全部物理候选，不要求 payload 可读；统计清除只需能读出属于该书的 `book`。未知类型前缀、无法识别书键或无法解出 `book` 的统计清除原样保留，跨书／全局清除仍保留。列表中的 unsupported 书也允许整书删除。封面资产仅在引用可理解且无剩余引用时回收；被删或剩余的引用只要有读不懂的，就保守保留资产。

备份和 pending 晋升共用位置胜者及不可变批注/事实接入，保留 updated/token、ID 和因果，冲突 ID 拒绝并回滚。历史 pending 晋升可能留下内层 pending content_key 的事实：正式 ReadingFact.contentKey 为权威路由，与现有 visibleFacts 一样处理，备份保持原 payload；内外两个正式 SHA 不一致仍拒绝。未知必需 payload 保留原数据并阻止导入，不降级或重编码。

同 token 的位置重试按 updated 与解码后 PositionValue 的内容相等判断，不比较 JSON 键排列；pending 晋升和备份位置接入共用该判断。备份快照是 UserDataStore 上不挂起的同步调用；预览后的最终校验在导入事务中执行，保留账户/configuration 检查，不将全局投影缓存 epoch 当成该 store 的一致性凭据。

库存诊断区分较新格式（高 v、未知类型或字段）、数据无法读取（坏结构）与读取失败（存储/查询异常）；只在确认为较新格式时建议更新。诊断只返回书键、可得书名/来源、记录类型和原因，不返回 payload。统计清除的 book 可以是正式 SHA 或非空 pending 键，旧作用域在库存、备份和整书删除中保持可读。

## 1.3 已定稿待实现

以下是 #98/#99 的已确认设计，非 `6dc282a` 已存在的字段或运行行为。实现 PR 同步更新规则归属和迁移；CloudKit schema 不变，不新增通用同步引擎。排期见[1.3 计划](../plans/1.3.md)。

### 同步进度提示：同步位置更靠后时的非打断提示

#### 不增加位置同步字段的边界

PositionValue 仍是 `content_key/offset/source_hint`，StoredValue 仍是 `updated/token/value`。不添 device、maxOffset、远端位置数组，不修改 UserPosition/CloudKit schema，不改变 LWW。

现有 token 不编码设备身份；UserValue.device 也不能代表现在 UserPosition 的作者。ReadingFact.device 的会话统计不能可靠反推出某条位置来源。因此仅用现有字段时，已确认文案：**“已同步到第 X 章（约 Y%）”**，操作“跳过去”“留在这里”。不是“iPad 已读到”，也不把任意不同 token 称为另一设备的确证。

新增本机 `LocalReadingResumeState`（UserDefaults 的独立版本化字典，按当前 storeScope + SHA），仅保存 `schemaVersion=1 / offset / lastLocalWriteToken?`。最后真正呈现/确认的本机正式位置是可用于提示的基线，不参与同步裁决，不供 Widget/Spotlight 导出。所有字段从无记录开始；缺失按 nil，不把已同步位置冒充旧本机位置。保存返回实际提交 token，不能由调用方生成第二个 token。进程崩溃在云事实写成功、本机回执未写的缝隙，最多缺少一次提示依据；不能改写用户事实来“修复”。

用户已确认该冷启动语义：有本机基线且同步胜者明显领先时，先留在本机上一位置并提示；无基线仍沿现有胜者恢复。不以一次升级伪造本机历史，也不新增用户设置开关。

#### 决策与时序

建议在 `Data/ReadingContinuation.swift` 统一准备 ResumeContext；`ReaderSession` 只拥有可见提示、关闭和导航状态。

1. 开书在首次位置写入之前同时取该 SHA 的现有 LWW 胜者、本机基线、兼容状态。未知 payload/隔离时沿用原保护，不猜位置。
2. 无本机基线：沿用当前正常恢复胜者行为，不把读者拉回 0；已读过本机但无 token 的旧数据也不捏造来源。1.3 以后发生本机实际阅读才积累基线。
3. 若胜者 token 与已知本机写 token 不同、胜者较新且明显更靠后，构造一次不可变候选。将本机 anchor 传给初始 frame，不把本机旧位置重新保存成新的 LWW 胜者。首帧/布局回报没有用户阅读动作时不得产生位置写入；用户真正翻页、滚动或选择后仍按既有保存规则，不为保留候选长期停掉同步。
4. CloudKit import 后仅对当前打开书重新取胜者，调用同一决策；页面已完成加载也能接收。备份导入事件明确区分，不作为“另一设备”提示来源；未来再次经云端送达的备份值没有设备溯源，仍只能用中性“同步进度”。
5. 候选不能用“所有记录最远 offset”计算。只比较现有 LWW 胜者与本机 anchor；落后但更新的胜者仍是事实胜者，不能为了提示偷偷选已输掉的更远候选。候选若在观察前已被压缩或本机新写覆盖，不承诺找回它。
6. 接受、换书、编码重启、正文 SHA 改变、账户切换、隔离时撤销提示。异步结果携带 openingRequest/session ID，过期结果不推到新书。

“明显更靠后”由 **Rust navigation.rs 的一个查询方法**计算，复用真实有效章节和 reading_percentage，不在 Swift 用字节数自算比例。输入同 SHA 的本机 offset 与胜者 offset；输出是否提示、有效章节、百分比。确定阈值：严格 forward，且差额达到全文 1 个百分点，或至少一个有效章边界且差额达到 0.2 个百分点。章节尚未完成只在可信全文长度已有时按比例；否则延后判断，不拿当前准备字节作分母。阈值是已确认的产品参数，不做设置滑杆。

#### 阅读交互与写入

在现有阅读工具区域显示紧凑、可点的提示条，不用 alert/sheet，不抢焦点、不播放声音；页面正文坐标不因提示进入而重排。关闭工具时可呈现底部轻提示，按正文安全区覆盖且可收起。旁白一次低优先级公告，不自动移动焦点；VoiceOver 使用时不自动超时消失。

普通模式 8 秒后收成阅读工具内的“同步进度”入口，避免按钮过快消失；“留在这里”压制本次 opening 的后续提示（不仅当前 token），下次重新开书才重新判断。用户已读过候选 offset 则直接消失。选“留在这里”不单独刷新云位置时间戳，后续真实阅读自然保存。

“跳过去”不是临时预览后清空历史：先核对当前会话/SHA与候选仍可读，再用既有 Rust visitReadingPosition 将当前位置入历史，成功呈现后作为正式位置保存，同时**保留本次 history**。将 ReaderSession 中“结束临时浏览”与“清空 history”分离为明确调用参数/专用路径；普通目录预览行为不顺带改变。按钮成功前不计入新的正式位置；失败保持原位，可重试/关闭。历史返回继续调用原跳转规则，不另存一份跨设备历史。

最小测试：Swift 固定候选与本机回执，验证不自动跳、不因重复通知重现、切书丢弃旧结果、首次布局不写旧值、跳转成功保留原点及失败保留原位；Rust 测明显领先与有效章节边界；修改/新增最多 1 条 UI 流程，覆盖“出现提示→跳过去→历史返回”。真实双设备测试验证云端时序，不能用本机注入代替。

### 编码同步：编码选择属于原始字节

#### 同步键、值与唯一归属

采用新 `UserValue` 命名空间 `source-decoding/<raw_sha256>`，值 `{ "decoding": "gb18030" }` 或 `{ "decoding": "auto" }`；外层仍使用既有 v1 StoredValue envelope，不再加第二套时钟/版本。`decoding` 的合法化和规范拼写调用 Rust `normalize_source_decoding`，SHA 语法调用 `parse_sha256`。新增命名空间由 `UserSyncJSON.kind/validateValue` 识别并严格校验，不把任意编码标签字符串直接交给 UI。

- **强匹配只用完整原始字节 SHA。** 完全相同字节在不同路径/书架就是同一解码对象；复制、重命名、移动不丢选择。路径、大小可帮助定位/减少查询，不能作为自动套用编码的依据。
- CRLF 改为 LF、转码或正文追加会改变 raw SHA，即使最终 content SHA 相同，也不能自动套原文件选择；这正是“解码发生在正文身份之前”的边界。
- 不把原文件摘要和正文摘要混进同一个 `metadata/<sha>` 键空间，不把 decoding 写进 PositionValue（会使旧版严格 shape 隔离整本位置）。source_hint.decoding 保持旧载荷可读，但不再形成迁移后的独立策略回退；最终 SHA 校验仍不可省。
- 冲突只由 UserDataStore 现有整值 `(updated,token)` LWW 裁决。Rust 接收一次已裁决的有效编码；不维护第二份同步 winner。不同设备离线各选一次，最终较新者胜，同毫秒按现有 token 裁决。
- 用户本次明确选择最高优先级；事务提交经既有 put 获得比已见 winner 更新的 updated。之后已同步的更新可以在**下次开书/重建**成为默认；不能远端设置一到就销毁正在阅读的会话。
- 选择“自动”必须保存显式 auto 值，不能只删本机 override，使远端旧手选值再次生效。

新增 Swift `Data/SourceDecodingPreferences.swift` 统一编排“确定 rawSHA → 完成这条来源的旧值迁移 → 读取同步 winner”。Rust 继续负责原始摘要、编码规范和解码。迁移器只生产历史候选，正常解析只消费 UserDataStore 胜者，没有本机旧值参与第二轮裁决。

#### 三条路径共用同一个编码判定

共同接口 `resolveSourceDecoding(rawSHA) -> ResolvedDecoding`：有已识别同步值则返回其策略，没有则 auto；未知协议按现有隔离规则报告，不能当成不存在、不能改写默认。**没有 `legacyLocalSelection` 参数。** 用户明确改编码时，先通过唯一保存入口写真实新选择，再读其胜者用于重启；当前会话的任务描述仍冻结一次选定策略，不在流式解码途中切换。

1. **开书**：复用 hashImportSource 获取完整 rawSHA；完成该来源待迁工作后读取设置，才以 rawSHA+策略查快开/创建导入任务。不能先用 auto 解析再异步改编码。
2. **全量索引**：IdentityFileWork 同样先取得 rawSHA、完成待迁、读取同一已裁决设置，再 identify/publish。Rust 不读 SwiftData，不在 Swift 重写 hash。
3. **最近阅读恢复**：使用同一个 rawSHA 设置。已迁移后不再把 source_hint.decoding 作为与同步值竞争的长期编码来源；旧 hint 字段继续可读，但只作来源描述。恢复仍要求最终 contentSHA 等于目标；不能因为“能解码”就贴上旧进度。

hash 与解析跨 actor 时不得持 NSFileCoordinator accessor 同步等待 MainActor；两段协调间重验来源快照与 expectedRawSHA，变化即重试。现有索引 probe 把 rawSHA 与解码绑在一起，失败得不到摘要，因此提取/复用 Rust hashImportSource 的纯字节摘要能力。冷索引可能增加一次顺序读，必须保持取消与阅读优先级；已有可信文件摘要可沿现有核验规则复用。缓存键比较实际 rawSHA+decoding，不新增“已应用 token”字段或来源绑定状态。

同步编码改变只在下次开书/重建采用，不销毁正在阅读的会话。旧身份关联按现有解码变更失效规则处理；解码后只有 contentSHA 相同才恢复同组进度/批注，不迁移不同正文之间的阅读数据。

#### 升级时一次性迁移旧手选（epoch 候选）

迁移必须复用保留时钟/token 的候选接入：普通 put 会推进 updated，不能用于 epoch 旧值；既有 `(updated, token)` 决定胜者，迁移器不复制 LWW。

迁移流程：

1. **一次登记。** 通过 SQLite 下一有序版本，在事务中把升级前非 auto 的手选值登记为待迁项；auto 默认值无需生成候选，缺同步 key 本来就等于 auto。现有列无法区分“用户曾选 auto”和“从未选择”，不能杜撰历史。登记完成后不能每次启动重新从旧列生产候选。
2. **不丢待迁选择。** 在现有 SQLite 增加一个专用于升级的 `source_decoding_migration` 待办表，保存既有 fileID/来源定位与快照、规范编码、可选 rawSHA；不新建数据库或文件格式，不同步此表，不是第二份运行时偏好。保留待办是因为 SwiftData 与 SQLite 无法跨库原子提交，也因为部分原文件未下载；不能把旧手选当可重建缓存清掉。已有 schema 基线文件不改，新增有序迁移；未知更高版本仍拒绝覆盖。
3. **取得强身份。** 已有 library_identities 且符合现有来源快照核验时可复用 rawSHA；不能从相同 contentSHA 反推唯一 rawSHA，source_imports 同一正文可能有多个原始字节版本。其余只读协调取得原文件后算完整 rawSHA，不按名称或路径猜。
4. **写入历史候选。** `source-decoding/<rawSHA>`，`StoredValue.updated=0`，value 为规范编码；token 使用由迁移版本、rawSHA、规范编码组成的稳定标识。同 rawSHA+同编码重复迁移产生同一 token；不同旧编码均为 epoch，沿现有 `(updated,token)` 规则确定赢家，不再按设备、文件修改时间、遍历顺序另选“最新”。普通真实选择仍用原 put，所以至少为 1 且必定胜过 epoch。
5. **先可靠保存，再确认完成。** 候选通过严格校验和去重接入 UserDataStore；同 token 不同 payload 必须报错。SwiftData 本机 save 成功（或确认已有相同候选/更高优先级真实值）后，才事务移除对应待迁项。若中途崩溃，使用同一 token 重试；不产生更大的时间戳，不覆盖已存在的新选择。迁移登记与完成标记只属于升级，不是已应用 token 缓存。
6. **没有原文件时。** 升级先登记，已知 rawSHA 的项立即完成；未知 rawSHA 的离线/失权文件等正常取得来源时完成，绝不为升级自动下载整库或要求全部重新授权。此条迁移在该文件真正解码前完成，然后 resolver 只读同步 key。迁移保存失败就报告该文件准备失败并保留待办，不能静默改 auto 继续解码。其他书与已准备缓存仍可用。源确实消失也不把选择套到同名新文件。
7. **退役旧读取。** 删除正常开书/索引/恢复中的旧本机编码回退、额外“使用并同步”按钮和已应用 token 方案。旧 `library_files.decoding` 列按持久化约定保留，可用于既有任务/快照兼容，但不再是用户选择的读取来源；清理或退役该列的写入不能影响尚未登记/完成的迁移。

“一次性”指每条升级前选择只生产一个幂等历史候选，不是保证离线原文件在升级瞬间就能被 hash。迁移待办仅在升级和取得相应原文件时使用，迁移完成后没有两套偏好查找。所有设备同样按 epoch 导入，无专门的旧设备优先级。

#### 发布、存储与备份

| 对象 | 定稿要求 |
| --- | --- |
| SwiftData @Model / CloudKit schema | 不变；复用 UserValue.key/device/payload，不新建 CloudKit 字段/编码表 |
| 同步协议 | 新命名空间，外层 v1 不变。缺 key = auto；未知值保留并隔离，禁止覆盖 |
| 本机有序迁移 | 增加升级待办与迁移版本；rawSHA 可空，缺值代表待取得原件。不得改原基线 schema 或删除旧 enum/字段 |
| 当前用户改编码 | 原生本书编码菜单，一次正常保存；选择 auto 也是显式新值，没有另一个“同步此选择”按钮 |
| iCloud 开关 | 编码值随既有阅读数据同步；关闭时仍保存到本机 UserDataStore。迁移不打开 CloudKit、不绕过账户确认 |
| 清除阅读数据 | 不顺带删除 raw 文件的编码设置。重置编码通过保存 auto；不新增全局编码清理面板 |
| 备份 | 新 key 作为全局来源设置进入现有 values.jsonl；BackupRows 不将 rawSHA 当正文归属，不出现在按正文 SHA 的书目删除范围。ZIP 布局不用变化 |
| 旧版本 | 旧备份在 1.3 可读；含新 key 的备份由 1.2 按原保护拒绝、不部分导入。1.2 接收新同步 key 后完整备份/诊断可能提示更新，用户已接受；不再作为待批准或发布阻塞 |

相关设备升级仍是版本说明中的建议，不再要求用户逐本确认旧手选才能迁移。迁移产生的编码事实也纳入导出全部；未能确定原始 SHA 的待办不伪装成已迁成功的同步事实。

#### 必要迁移测试

测试跟随唯一规则，不用真实时钟 sleep、不重复整套 LWW 矩阵：

- 旧库无手选、含 auto、单个手选升级可读；新库和旧库均按同一有序版本完成初始化。迁移重复启动不增加候选/不提高 updated，旧原文及正文 SHA 不变。
- epoch 候选往返、同 rawSHA 同值去重、同 rawSHA 不同旧选择按既有 token tie-break 稳定；任意真实新选择（含 auto）在迁移前、期间或稍后到达都胜出。
- SwiftData 写失败、写成功但 SQLite 确认前崩溃、SQLite 迁移失败回滚，重启后均可恢复且不丢旧手选；高版本库拒绝覆盖。
- rawSHA 不可用/原文件离线不静默清空，正常重新取得来源后只迁一次；文件变化不错误使用旧摘要，同正文多 rawSHA 不误关联。
- 升级完成后三路径只调用同步 resolver；检查代码不存在 legacyLocalSelection/额外同步按钮/已应用 token。未知 payload 隔离，保存失败不改既有身份；旧备份可导入、新 key 备份旧版安全拒绝。

真实两设备验收：一边迁 epoch、一边离线新选，再上线；迟到 epoch 不覆盖真实选择。此步骤待实现后执行，本轮未运行。
