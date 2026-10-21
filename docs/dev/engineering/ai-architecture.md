# AI 内部分层与内容任务技术设计

现行专题整理：2026-10-13。下方描述当前源码中的存储、工具与业务应用边界。快捷任务、提案业务和结果 UI 已接入；未完成范围见[AI 计划](../plans/ai.md)，验证证据见[验证记录](verification.md)。源码接入不代表真实供应商或真机验收。

## 当前实现

AI 在现有 Swift target 内按职责组织，不另建包或实现第二套 SDK。参考 Pi 的供应商通信与 Agent 运行分工；Swift AI SDK 继续负责协议实现与工具循环。

| 目录 | 当前职责 |
| --- | --- |
| `ios/Moonread/AI/Providers/` | 连接定义、预设与品牌映射、Keychain 凭据管理、API Key 与浏览器 OAuth 认证（ChatGPT SIWC／OpenRouter）、模型目录、请求适配、可取消网络传输、原生搜索/生图执行与能力筛选 |
| `ios/Moonread/AI/Agent/` | 会话生命周期、任务、消息更新、保存时机、模型选择及阅读上下文 |
| `ios/Moonread/AI/Data/` | 应用消息结构、SwiftData 实体与本机历史存储、按会话范围保存的图片附件 |
| `ios/Moonread/AI/Tools/` | 10个读取工具、共享引用与正文准备、结果分页、原生搜索/生图和资料／笔记／书签／封面／整理 TypedTool |
| `ios/Moonread/AI/UI/` | 对话列表与聊天、连接设置与添加、连接详情、模型选择与详情、阅读入口 |

## 状态归属

`AIConnectionService` 唯一管理连接列表、默认连接、认证状态和模型目录。`AIService` 持有它并管理会话元数据、输入草稿及只读 UI 投影；`AIAgentCoordinator` 唯一持有各会话运行器，运行器拥有任务、流和队列。页面关闭不释放运行任务。没有为分层复制一份可变会话或登录状态。

连接移除由会话服务协调：先停止对应请求，再由连接服务清理凭证和配置。对话历史保留；默认连接被移除后清空，不选择其他账户。对话 Tab 和阅读弹窗共同读取 Agent 会话头与有序消息投影。首次连接和用户向前分页读取历史；成功提交的增量按 ID 追加或更新，流式活动不重查历史，已加载旧页保持。

`AIProviderRequest` 把连接、目录模型、凭证和请求参数转成 SDK 模型及选项。四种协议选择、ChatGPT 公共 Responses 流协议适配、OpenCode 会话头与思考参数都在此处；Agent 不分支判断供应商品牌。`AITransport` 负责 URLSession 与流取消，不管理会话；它与 auth、catalog、cover 的直接 URLSession 入口共用 `AINetworkAccess`，每次 HTTP 经 `AIAvailability.networkRequest` 等待启动店面结果并校验执行租约，地区判定只在 AIAvailability 实现。

## 扩展边界

新增供应商优先修改预设、品牌、目录映射和必要的认证/协议适配。界面不新增供应商特判。图标来源与处理见 [资源说明](../../../ios/Moonread/AI/PROVIDER-ICONS.md)。

完整基础设计与工具参数见 [Agent 基础](../ai/agent.md)、[工具契约](../ai/tools.md)。`AIAgentCoordinator` 是页面共用的应用级入口，复用同一 `AIConnectionService`，按会话持有 `AIAgentRuntime`。运行器负责 SDK 多步执行、排队、确认、停止、模型切换和压缩；`AIAgentStore` 保存有序历史及检查点；`AIReadingTools` 调用 ReaderService 最终业务投影。页面关闭应只移除观察者，不调用 stop/remove。

旧文本执行循环和 `AIMessageRecord` 已删除。历史只存入 `AIAgentEntry`，未发送文字和附件仅保存在内存投影中；UI 由历史、当前增量和运行状态生成轮次投影，不保存第二份可编辑消息。后续持久化结构按发布兼容规则演进，迁移须保留历史。

## 验证

复用四协议请求、认证、停止与重开、删除运行会话、移除连接、模型选择的回归。另检查所有内置预设都有可加载的品牌资源，显式连接配置能独立保存与重读。真实供应商权限与真机体验仍按独立验证记录判断。

## 单一数据归属

- 连接显式保存 providerID、providerName、wireProtocol、authMethod 与计费方式；预设创建完整连接，自定义连接也必须完整填写。不保留早期 Codex 默认对象、kind 分类及覆盖字段。
- 当前会话的模型选择仅存在 AgentHead.selection。ConversationRecord 保存标题、阅读关联和任务分类；界面从会话头读取连接、模型和思考档位。已经启动的请求保留当次选择快照，后续切换只影响下一请求。
- AIContext 只保存对话与正文 SHA、书名、章节的关联。入口的 AIEntryContext 携带本次阅读附件，附件进入输入草稿并随用户消息保存；可移除的输入附件不写入会话头或固定上下文。
- 删除未使用的 AIAttachmentRecord；后续 schema 变更需版本迁移并验证历史读写。

`AINativeExecutor` 按默认用途解析连接并复用 SDK 原生工具；`AINativeTools` 只定义应用工具参数和调度。每个工具有独立可取消传输，连接服务登记取消句柄，移除/退出连接能停止不同聊天模型委托的请求。`AIAssetRecord` 保存会话资产，`AIImageStore` 只准备私有图片值并按 owner/ref 读取，工具历史只携带范围内引用，页面不拥有生成任务。

### 原生工具的服务配置

对话模型选择与工具服务选择各自保存，不共用用途分支。`AIToolServiceView` 先按 `AINativeCapabilities.supportsConnection` 展示已实现的官方通道，再按具体模型路由提供原生模型菜单。`AIConnectionService.setPurpose` 校验并保存连接和模型；执行器在调用前再次解析路由。关闭页面不保存，停用显式清空；未配置或无效配置不替换成其他账户。ChatGPT 不提供图片生成；OpenAI API hosted 图片生成的执行模型与实际绘图模型分开表达。

## 快捷任务与业务提案

以下保持一个 Agent、现有 Swift target、SDK、ReaderService/ReaderQuery、Rust 正文及文件索引、SwiftData 用户数据。不新增包、供应商、依赖、通用任务引擎或全应用 owner 重构。工具只是业务服务适配；目录组织不等于职责已经解耦。

### 模型启用与搜索

[AIConnection](../../../ios/Moonread/AI/Providers/AIConnection.swift) 保存 `disabledModelIDs: Set<String>`，随本机连接配置保存。新连接为空，刷新不删除停用 ID，新出现模型默认启用，消失后重现保留偏好；手工添加与详情“使用此模型”显式启用。不增加自动启用设置；新增持久化字段按发布兼容规则给默认值。

停用只限制新选择。默认、对话、搜索、生图的当前值继续显示“未启用”且可用；运行和历史不变。执行器的 `model/purposeSelection` 不能加停用过滤而拒绝已有选择。修改当前模型的思考档位不视为重新选择。真正缺失或能力不匹配仍报错，不换账户。目录刷新仅在默认 modelID 为空时选第一个已启用文本模型，没有则留空。

共用列表采用原生 `.searchable`，匹配名称、ID、连接名并按连接分组；用途页面先选服务，再进入单连接搜索列表。编辑目录即时保存开关，批量只作用于全部或当前搜索结果。`AIConnectionService` 仍是唯一配置 owner。[AIModelSelectionTarget](../../../ios/Moonread/AI/Agent/AIModelSelection.swift) 支持 defaults/conversation/session，任务与对话共读 `AIAgentHead.selection`。

### 统一持久会话

`AIService` 使用同一种 `AISessionValue`，普通聊天首次发送前仅保留内存投影，文字、附件及模型选择不落库；首次发送在一次事务中创建会话、head、首条队列和附件资产，失败保留输入。发送提交 Task 保存于会话投影，存在时禁用输入、附件、模型和发送，完成或失败后释放；模型生成期间仍允许发送新输入。快捷入口 Start 创建持久会话；`origin/kind/listed` 只表达展示归属。开始前表单不创建会话，点击时同步占用 starting，异步创建完成或失败后释放；Start 在同一次保存中创建会话、模型选择和首个含目的／补充要求／附件的队列输入。已开始的未列出任务、已提交队列和历史跨启动保留；所有未发送草稿只留内存，直到用户显式删除。普通聊天首次发送创建记录并列入列表；普通全局会话在这个首次会话／发送队列事务中用首条用户消息前40字符设标题，后续发送不覆盖，关联书籍与任务标题保持。没有 AI 命名请求。

来源 locator 用稳定 fileRef 优先于加载过程中变化的 SHA；没有文件时用 SHA。多文件集合编码排序，不持久保存 Swift hashValue。单书统计只接受当前路由 SHA 或身份匹配的已加载详情，不准备、下载或解析正文，不退回全库；打开 sheet 时固定时间与书籍范围。

“转入对话”只在 repository 一次保存 `listed=true/origin=nil`。运行器、ID、store、head、完整历史、确认 continuation、队列、草稿与资产均不改变；没有 promote、复制、资源交接或隐藏消息。同一个 sheet 始终使用 `AIChatView`，固定 sessionID；入口之后显示新的设置表单。关闭不停止运行。

### 持久化与运行顺序

`AIRepository` 是唯一 AI SwiftData ModelActor，通过异步后台 factory 建立 container/context。会话、head、entries 和资产在同一 container；跨 actor 传递不可变值，不传 managed rows。列表分类只改其拥有的字段，不覆盖陈旧整份 head；schema 不包含草稿或草稿版本列。

`AIAgentRuntime` 沿用 SDK 工具循环，用每个运行器的串行 persistence tail 串联最新 head 读取、语义修改、actor 提交及缓存发布。tail 在首个 await 前预留，不跨网络、业务写入或编辑器等待。失败回滚 context，已提交缓存不变；后续命令仍可执行。成功保存后发布缓存与 committed-entry 回调，不因随后取消而跳过。

历史显示按 50 条分页；结果身份为同 owner 的 entryID/tool-call ID。原始工具 body 只保存在这份 canonical 历史；消息进入会话投影时通过同一 decoder 给卡片生成 typed 结果，按该已加载 entry ID 暂存；仅当消息 payload 改变时重解码，终态和流式更新不重解码，工具调用位于前一页也不影响结果卡片。启动不扫描每个会话全历史，不保留第二份全局结果目录，也不统计历史结果总数。

### 资产及第一次引用

`AIAssetRecord` 与会话建立 cascade 关系，保存引用 ID、实际 MIME、尺寸及 `.externalStorage` Data。没有自建临时／持久资产目录、promotion owner 或 FileManager 回滚／扫描。列表、head 和历史查询不读取 blob；只有预览和图片工具消费读取 bytes。

工具准备的 `AIStagedAsset` 私有暂存。第一次持久引用出现于 pendingCalls.output、历史 entry 或已提交队列时，资产 row 与引用在同一 context/save 插入；失败两者都回滚。后续 entry 复用该 row。成功 pending output 的资产可用于中断恢复，尚未提交工具调用的 staging 不成为可操作卡片。

当前封面复制返回 attachment+bytes 的独立 staged 值；所有未发送图片附件在内存暂存，发送时随队列原子保存，不受工具终止清理影响。显式 Add 每次生成新的 occurrence UUID，按顺序保存；移除一个 chip 只移除该 occurrence，资产保留到会话 cascade。用户实际封面独立复制到 UserDataStore，删除会话不撤销它。

### 共同结果与用户工作

所有 propose_* 及实际 `AIFindCoverResult` 都经过 `AICommittedResultDecoder`。execute 只私下准备结果；只有成功提交的 tool HISTORY 结果能进入共同 projector 和操作 UI。assistant 参数、失败／取消调用、未转历史的 pending output 都不授权卡片。成功结果所在 turn 随后中断，已提交结果仍可显示。

每个结果卡片显示该条不可变建议。每次打开，从消息携带的 committed 结果和当前业务数据创建全新复核；关闭丢弃所有 editable draft 和 selection，不持久保存用户复核编辑、应用成功／失败、回执、未确认状态或已解决候选集合。没有 AIWorkRecord/AIWorkState、复核恢复或另一套缓存。与当前相同的字段仍可阅读；打开结果不会重放模型。

资料与封面保存期间禁用操作。业务保存成功后只即时提示并刷新当前业务值，不做第二次任务成功保存、不限制以后应用同一建议或候选。资料 Apply 捕获点击时的字段／标签选择，逐书 fresh-current 核对并保留未选数据。封面候选来自该条 immutable 结果，按资产 ID 保留，不比较图片 bytes；显式 Add 仍产生独立 occurrence。

笔记既有书签和原文可用性每次复核重新查询，保存／重叠编辑调用原有业务事务。编辑器 Done 在真正写入前进入会话 application admission，完成后只释放 admission／显示即时反馈。没有合成 saved 状态或应用回执。目录执行阶段仅在本次复核期间显示；关闭后不恢复执行进度。下次打开按原始提案和真实目录创建新预览，必须由用户再次确认数量，真实文件 no-overwrite 和版本检查照常，不能自动执行。

### 删除

listed/unlisted 会话采用同一删除入口。实际业务应用或批注 Done 已进入保存时拒绝删除并显示 busy；这段生命周期包含资产读取、真实写入。删除同步关闭新 owner 命令，等待发送提交，停止并等待运行器、工具、持久 tail 结束，再一次事务删除会话及 cascade rows。

数据库删除失败回滚，保留整个 owner、草稿及资产；会话保持停止，重新开放用户操作并显示错误。不自动恢复模型请求，不做应用文件系统清理，也不声称 framework 外部 blob 在某一瞬间物理擦除。

### 图片、来源与网络

原生 OpenAI/ChatGPT/Google/xAI 来源统一由 AIWebSource factory 产生 `web:SHA256(UTF8 exact URL)`，供应商 citation ID 不作应用引用。保留签名 query；相同 ref 合并时优先首个非空标题，最后才使用 host。hash 正确不代表授权：提案／UI 只解析同 owner 成功 committed 工具来源。

find_cover 的即时原生来源列表以精确 sourceRef+URL 配对授权此次下载；结果、来源、候选一起成为 canonical 成功历史后才授权其他操作。只允许授权搜索来源及从该页面本地提取的一层显式图片，不猜 URL、不递归抓取。`AIImageOrigin` 为 web/generated/currentCover/unknown；缺少实际 producer 证据保持 unknown。

下载使用普通 ephemeral URLSession/ATS／默认系统信任和 routing；不带供应商凭证、cookies 或应用 DNS/IP 策略。没有后缀、MIME 白名单、50 MiB header／stream／makeCover 输入门槛，也不在早期前缀识别失败时拒绝。完整响应下载到系统暂存文件后，以完成的 ImageIO 解码判断可用性；find_cover 对非图片来源可本地提取一层页面声明图片；完整下载不等于给模型读取网页正文。缩略图与用户封面输出下采样政策保留，工具适配使用实际资产 MIME，不猜测格式。未实施真实供应商或设备网络验收。

封面提取和 Referer、限额、解码与取消的现行规则见[封面来源页面图片提取](../ai/cover-fetch.md)。未新增通用图片 MIME、后缀或字节数门槛；find_cover 的尺寸启发式不扩展到生图。

### 组织操作

canonical 结果保存原始 scopeRef 和提案内容；本次复核读取棚架 ID／路径、原始 SHA 字节基线、目录快照并固定已确认操作；显示棚架名称从当前书架列表读取，缺失显示“书架不可用”。scope 是方案说明，不是入口权限 fence。没有入口白名单、模型能力 gate、新供应商或自动重试。

执行只接受此次确认的 node IDs；原有 no-overwrite、原始 SHA 校验及非可重放阶段保持。重开创建全新目录预览，执行仍需本次明确的数量确认，不自动续跑。实际文件操作阶段只用于当前页面的安全呈现，后续读取失败不改写已完成业务阶段。

### 验证边界

统一会话、资产与结果应用的真实运行证据集中在[验证记录](verification.md)，不以旧架构的通过记录代替当前实现。

`rg` 的 partial 表示覆盖不完整，已返回命中的来源仍有效；来源解析仅对 rg 接受 partial，保留既有 owner、范围和 sourceRef 完整性校验。文本/网页来源及图片来源的历史查询按实际操作需要执行，不在启动恢复卡片。

## 消息投影与呈现

运行时保存有序 pendingParts 与稳定 step，UI 按块输出稳定行；会话级缓存、UITableView、原生 Markdown 和显示缓冲的现行规则见[消息呈现](../ai/rendering.md)。原生搜索/生图协议及用途配置见[原生工具](../ai/native-tools.md)，本地封面网页提取见[封面获取](../ai/cover-fetch.md)。
