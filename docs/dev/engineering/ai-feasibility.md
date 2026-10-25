# AI 接入调研与开发交接

> 历史选型与探针记录。下文 SwiftStreamingMarkdown 及旧认证路径仅表示当时方案；当前渲染使用 MarkdownView，参见[消息呈现](../ai/rendering.md)，实际依赖以 Package.resolved 为准。本文不再作为当前实现交接单。

更新：2026-10-03。范围：源码调研、独立构建、本地协议验证及经用户授权的 Codex 订阅请求；文本对话底座已接入产品，实际实现状态与验收边界见[剩余工作清单](../plans/ai.md)和验证记录。产品决定以 [AI 设计](../design/ai.md) 为准。本文中的技术方案可以作为实现依据；明确标为待定的产品行为不能由 worker 当作已授权决定。

## 证据与结论

- Pi 参考源码：[badlogic/pi-mono](https://github.com/badlogic/pi-mono/tree/1b347794e2a630e4359f2584f4eea388145d0ddf)，revision `1b347794e2a630e4359f2584f4eea388145d0ddf`。
- Swift AI SDK：`teunlao/swift-ai-sdk`，临时只读检出 `df3e071ac414858a4d57e1cd48b3f686e92ab1ce`。
- SwiftStreamingMarkdown：独立选型使用 2026-10-02 的 Microsoft 仓库源码归档；正式工程已锁定 `95bb755a9b23a1aea8682b9ebc912cb72b176c95`。
- 两个库通过 Xcode 27 的 iOS Simulator 构建，并联合链接为独立验证应用；deployment target 为 iOS 18。应用在 iOS 27 模拟器启动及明暗画面检查通过，尚未在 iOS 18 系统运行。

保留已选库，现有独立验证足以支持进入产品开发。应用补齐认证、会话管理和任务级 transport；无需重写整套 SDK。尚未实现的功能随开发检查，其他供应商在各自接入时验证，不再作为全部开工前提。

| 能力 | 源码证据 | 实现边界 |
| --- | --- | --- |
| 流式文本、工具事件 | SDK `GenerateText/StreamText.swift`、`StreamTextActor.swift` | 应用服务消费 fullStream，统一写消息状态，页面不能拥有网络任务 |
| 工具循环与每步输入 | `GenerateText/PrepareStep.swift` 支持 async throws、替换 messages/model/activeTools | 可承载上下文管理；应用提供预算、摘要与持久化 |
| 结构化结果 | `GenerateObject`、工具输入输出类型 | 使用应用 DTO 保存/渲染，验证稳定 ID 与业务约束，不能只验证 JSON 语法 |
| 图像生成/编辑输入 | `GenerateImage/GenerateImage.swift` 有 files、mask、providerOptions | 接口有能力不等于每家模型实现；首个服务必须实测参考图编辑；封面继续使用应用附件卡片，不依赖 Markdown 实验性的 imageConfig |
| 停止 | 默认 stop 的静默流测试失败；公开 fetch 注入的真实本地 HTTP 测试通过 | 每个运行任务持有可取消 transport；停止同时发 SDK stop 和取消该任务的网络连接，不使用仅 stop 的方案。详见下方实测 |
| SSE 小块交付 | 默认 fetch 积累 16 KB 后才 yield；24 字节事件实测等到连接关闭才交付 | 注入及时交付 SSE 的 transport，不能原样使用默认网络实现 |
| 模型容量 | LanguageModelV3 协议只有身份、URLs、请求接口，无统一 contextWindow | 应用维护所用模型的容量/输出上限及能力；未知自定义模型不猜大窗口，要求补充设置 |
| Markdown 流式 | StreamedMarkdownSource 发完整累积快照；StreamedMarkdownView 消失时结束订阅 | 不能直接接 SDK token delta，也不能借视图管理请求生命周期 |
| Markdown 重开 | MarkdownView(text:) 可从已存字符串重新渲染 | 优先用服务发布的节流快照驱动 MarkdownView，重开从当前状态恢复；如使用 StreamedMarkdownView，订阅必须独立且可重放最新快照 |
| 跨块选字 | TextSelectionConfig、DocumentView、SelectableTextView | 内置“选择更多文本”打开全文纯文本 sheet；不是气泡内跨 Markdown 块自由拖选。已确认不做跨块拖选设计，整条回复提供复制按钮，局部选择沿用库/系统 |
| 富文本功能 | 库 README 与 Package.swift | 表格、代码、引用、公式可用；Mermaid/HTML 非完整渲染，不承诺。公式、高亮等会引入额外依赖 |

参考：[SDK](https://github.com/teunlao/swift-ai-sdk)、[Markdown 库](https://github.com/microsoft/SwiftStreamingMarkdown)、[LazyVStack](https://developer.apple.com/documentation/swiftui/lazyvstack)。不使用另一个同名 Swift AI SDK 的文档证明本库能力。

## 参考 Pi 的压缩方案

源码：`packages/coding-agent/src/core/compaction/compaction.ts`、`agent-session.ts`。

Pi 的做法：

1. 优先结合最近有效 usage 与后续新增消息估算上下文，接近 contextWindow - reserveTokens 时触发。
2. 从最近消息向前按预算保留内容，不在 tool result 处随意切开；长轮次可切分并额外总结轮次前缀。
3. 把之前摘要与新增旧消息一起更新总结，返回 summary、firstKeptEntryId、tokensBefore 等检查点信息；原会话记录继续存在。
4. 拒绝失败和被长度截断的摘要；溢出恢复最多进行一次压缩重试。
5. 默认 reserveTokens=16384、keepRecentTokens=20000，部分估算采用 chars/4。这是 Pi 的配置与启发式，不照搬为中文小说参数。

月读采用：

- 会话服务维护一份完整消息历史；另存最新有效摘要及保留消息边界。压缩只改变发送给模型的投影，不删除显示历史，不恢复消息分支结构。
- 固定指令、初始上下文与工具定义尽量保持稳定；摘要和近期消息在其后。只在预算不足时更新摘要，不能为追求缓存发送超窗内容。
- 预算包含系统指令、工具 schema、图片及工具输出，预留输出与下一步工具结果。provider usage 的缓存字段含义分别归一化，不照搬 Pi 的求和公式；未知容量不靠模型名字猜测。
- 中文估算必须保守，优先使用适用 tokenizer/官方计数能力与实际 usage 校准。不能声称 chars/4 对中文保守。
- 首先按完整轮次切分；单轮工具过程过长时，只在完整的模型工具调用/结果组之间切分，摘要包含原问题和本轮未完成任务。正在执行的调用不能孤立丢弃。
- 摘要保留用户目标、表达偏好（含本轮不剧透要求）、书籍 SHA/章节/正文引用、事实来源与推测区别、已应用操作、待确认方案及待办。摘要不是指令权限来源，文件执行确认由应用保存并验证。
- 总结请求不附可修改业务的工具，默认使用当前对话模型；失败、取消、截断时不替换旧检查点。摘要请求本身也要满足预算，过长输入分批总结并限制工作量，失败时向用户说明，不能无限递归调用。
- 输入超窗且可以确定没有产生业务副作用时，最多一次压缩后重试；不能因未知网络失败重放有副作用的操作。文本输出达到长度上限不自动循环续写。
- 切换模型前重新检查预算和历史协议兼容；签名/不透明块只用于其允许的模型和协议。不把推理签名当普通摘要文字。

## 会话与 UI 接口

应用级服务唯一拥有任务、生成状态与消息更新；SwiftData 持久化，UI 只观察。SDK 和 Markdown 库自身的解析/传输缓冲是临时派生数据，不建立第二份可编辑历史。

消息内容使用有类型部分：正文、出处、工具调用/结果、结构化预览、附件引用、错误。状态至少区分等待响应、工具执行、生成、压缩、待用户确认、完成、失败、已停止。无推理事件时显示等待，不伪造模型内部状态。

关闭页面只取消视图订阅；显式停止由会话服务取消。不能承诺 iOS 后台永久执行，进入后台尽快保存，系统中断后展示中断而非成功；重启不自动重复操作。

列表按页取历史，稳定 ID，加载旧页保持可视锚点；长段 Markdown 的布局不能因虚拟列表而自动视为低成本。只在用户位于底部时跟随，翻历史显示回到底部入口。月亮拖动与正文滚动/选字需要独立验证，不重写系统返回手势。

## 工具与 Agent 实施契约

完整参数与返回定义集中于 [工具契约](../ai/tools.md)，执行/保存/队列/压缩及验收矩阵见 [Agent 基础](../ai/agent.md)。本页保留选型证据，不维护另一份较粗的工具表。新的源码核对明确了 UTF-8 正文坐标、统计发生地日期、原生审批接口和并发工具执行边界；未联合实测项在基础设计中明列。

## 已完成的选型验证与开发回归

前置选型验证已完成到足以开工的程度。下列证据支持技术选择，不代表月读 AI 产品已完成。压缩、追加消息队列、页面生命周期和长列表是产品功能，由 worker 实现并检查；手机完整登录在正式接入时验证，其他服务按对应接入范围检查。无需重复一轮完整前置原型。

SDK 宿主 macOS 构建及上游 5 项 mock 测试通过，覆盖每步 options/context、多订阅、停止事件顺序、并发工具和取消在途工具。另有下述独立测试与真实订阅验证。编译存在上游并发隔离等警告，未执行 warnings-as-errors 验收。

### 独立实测：网络与 iOS 构建

2026-10-02，在上述 SDK revision 上添加临时验证用例，没有修改 SDK 实现：

| 验证 | 结果 | 证据 |
| --- | --- | --- |
| 静默 provider 调用 `stop()` | 失败：收到 abort，但 500 ms 后流仍未结束；测试主动释放 fixture 后才收尾 | `/tmp/moonread-lifecycle-probe.log` |
| 默认 fetch 读取立即 flush 的 24 字节 SSE | 失败：约 2.055 秒后服务器关闭连接才收到数据 | 同上；本地 HTTP 服务在发出事件后故意等待 2 秒 |
| 公开 fetch 注入、独立 URLSession、取消该会话 | 3 个场景通过：响应头前、响应头后静默、中文正文输出后 | `/tmp/moonread-transport-probe.log` |
| 小块中文 SSE | 在连接仍打开时收到“你好”，未等待 EOF | 同上，真实 URLSession → Anthropic provider 解析 → SDK textStream；响应来自本机 fixture，非真实模型 |
| 服务端观察连接断开 | 三条连接分别在建立后约 0.359 / 0.360 / 0.360 秒断开；客户端在 350 ms 发取消 | 本机 fixture 观察 socket EOF，与客户端流结束一起验证 |
| SwiftAISDK iOS 构建 | 通过 | `/tmp/moonread-sdk-ios-build.log` |
| SwiftStreamingMarkdown iOS 构建 | 通过；临时构建启用其 Equatable 编译宏，未更改全局 Xcode 配置 | `/tmp/moonread-markdown-ios-build.log` |
| 两库联合应用链接与启动 | 通过；独立 ID `local.moonread.ai-validation`，未替换月读 | `/tmp/moonread-joint-ios-build.log`，应用源码 `/tmp/MoonreadAIProbe/` |
| 中文 Markdown 明暗外观 | 模拟器画面已检查：正文、引用、表格、列表、代码块可见；未测试长历史和选字操作 | `/tmp/moonread-ai-probe-light.png`、`/tmp/moonread-ai-probe-dark.png` |
| 两轮工具调用、下一步切换模型、中文上下文替换 | 通过，原模型调用 1 次、新模型调用 2 次，最终回复“完成” | `/tmp/moonread-step-probe.log`；mock 仅证明 prepareStep 接口，不证明自动摘要算法与消息队列实现 |

接入结论：保留 SDK 的协议解析与工具能力，应用拥有运行任务的 transport，使用公开 fetch 注入，不需要为已复现的两个问题整体重写 SDK。探针使用 SSE 按行交付，仅证明 SSE 路径；正式 transport 应支持一般数据块交付及正常完成后的资源释放。每个运行独立取消，不能取消共享全局 URLSession 而影响其他对话。显式停止产生的 URLSession cancelled 错误应归为“已停止”，不能显示成网络故障。

以上尚不证明所有 provider 或 WebSocket 路径具备同样行为；图片、WebSocket 与各授权方式按实际连接分别验证。真实服务验证已选定先使用 ChatGPT／Codex 订阅登录，不借用 API key 路径替代。

会话调度边界：SDK 内层负责当前工具循环；应用在 prepareStep 前投影摘要、近期消息和待处理 steering。SDK 正常结束且尚有用户追加消息时，由应用开启下一轮；follow-up 在当前工作结束后处理。SDK 的 continue 条件要求工具调用，不能通过调高 stepCount 把它当作完整的用户消息队列。消息与摘要仍由应用持久化，不依赖 SDK 内存作为唯一历史。

### 历史 Codex 订阅验证（实现已移除）

下列为旧通道的历史证据，不能证明当前 SIWC 授权或权限；现行契约见 [供应商与身份](ai-providers.md#chatgpt-账户官方-siwc-替换契约)。

用户已在 OpenAI 页面完成设备码授权；令牌换取成功，返回 access token 与 refresh token。独立程序使用 Pi 的 Codex 设备码协议，未读取已有 Codex 登录文件，也没有使用 Platform API key。首次轮询遇到 TLS 握手超时，加入轮询网络中断重试后重新完成。设备码与令牌不写入仓库，测试凭证仅存受限临时目录。

- 订阅模型目录 HTTP 200。目录按 client_version 筛选：0.99.1 只返回一项，按本机 Codex 0.157.1 协议版本请求后返回九项。该目录包含上下文容量、最大容量、思考档位等；不要把默认容量与可配置最大容量混为一项，也不要只维护硬编码名称。
- 使用同一 SDK revision、公开 OpenAI provider 设置和自有 fetch，连接 `chatgpt.com/backend-api/codex/responses`，实际模型为目录返回的 `gpt-6-luna`。明确 `store=false`、instructions 与低思考档位，不发送不必要的请求参数。
- 虚构工具 `read_test_minutes` 返回 17，模型先请求工具再生成“17分钟”。两次请求均 HTTP 200，工具执行一次，真实工具循环测试通过。没有发送用户小说、书架或统计数据。
- 令牌刷新 HTTP 200，新令牌读取模型目录 HTTP 200；之后的图片编辑请求也使用刷新后的令牌成功完成。仅验证一次正常刷新，尚未测试多对话并发刷新与撤销授权。
- 同一 Codex 连接通过 SDK 的 `imageGeneration` 工具实际生成图片：一次请求 HTTP 200，返回 794178 字节 PNG，约 17.6 秒完成。输出为白底蓝色圆形，已打开检查。工具使用低质量、1024×1024 参数；未在结果中确认底层图片模型身份，不能把请求的对话模型当成图片模型名。
- 将上述图片通过 SDK 的 image 输入发送，要求保留圆形、在右上角添加红色方块：HTTP 200，返回 1030324 字节图片，约 22.7 秒完成，实际画面符合要求。证据 `/tmp/moonread-subscription-image.png`、`/tmp/moonread-subscription-edited.png`。这是提供参考图的编辑验证，不涉及 mask 编辑、连续多轮编辑或用户照片。
- 同一真实文本工具测试已编入独立 iOS 应用，在 iOS 27 模拟器运行通过，画面显示“17分钟，2 次请求，1 次工具执行”。构建 `/tmp/moonread-subscription-ios-build.log`，结果截图 `/tmp/moonread-subscription-ios-result.png`。本次临时注入已授权凭证，未模拟或替代 iOS 内完整登录流程。
- 这证明本账户的 Codex 订阅鉴权、文本流和工具往返可通过 Swift SDK 工作，不证明另一个公开 ChatGPT token-sharing 路线、全部套餐或移动端完整授权已通过。

测试完成后移除宿主机与独立模拟器应用中的本次凭证副本，原始响应日志不提交仓库；仅保留筛选后的测试结果 `/tmp/moonread-subscription-results.log`。产品仍需实现 iOS 授权界面、Keychain、刷新协调与明确取消；不能用宿主机授权和模拟器推理通过代替 iPhone 完整授权验收。

## 开发交接

实现顺序、职责和随开发检查统一见 [实施计划](../plans/ai.md)。主要产品行为已确认。联网服务选择留在对应接入阶段；模型设置布局、下载提醒呈现、月亮间距及是否吸附按真实页面落实，不新增一轮前置审批。实现细节不能扩展为任务中心、版本恢复系统或多账户管理。

## 模型目录与追加消息

同一 Pi 检出版本的 `packages/ai/scripts/generate-models.ts` 将 models.dev、OpenRouter 等目录数据与人工修正合成模型目录；模型记录包含 contextWindow、输出上限、输入类型等。`packages/coding-agent/src/core/model-config.ts` 允许为自定义模型/覆盖项提供 contextWindow。因此容量来自目录元数据和配置，不是推理 SDK 自动从任意模型名推导。

月读技术建议：生成随应用发布的模型元数据快照（按 provider + modelID 索引），标记来源/更新时间，维护必要修正；自定义或代理模型允许覆盖容量和能力。普通用户选择已知模型无需填写，未知模型才补充。在线 /models 返回的可用 ID 不保证附带容量，不能当完整能力目录。此为实现推荐，不引入 Pi TypeScript 运行时。

Pi 两种追加消息与多对话并发是不同问题。当前 `agent.ts` 和 `agent-loop.ts`：

- steer：排入 steering 队列，在当前 assistant turn 及其工具批次结束等处理边界读取，尽早影响后续步骤；不会撤销已完成的工具，也不等同立即中断正在流式返回的 HTTP 请求。
- followUp：排入 follow-up 队列，等 agent 当前工作自然结束、准备停下时，再开始处理。

月读已确认提供“调整当前任务”和“完成后发送”两种语义，默认 steering，发送按钮菜单提供 follow-up；不同对话可并发，同一对话顺序处理。

已确认：不可见时不做 Markdown 渲染，但应用级请求与持久化继续；图片模型不支持编辑时禁用并提示；月亮默认右下角，与操作药丸保持距离，拖动不能进入标题/药丸区域。整条回复提供复制按钮，局部选择沿用库和系统，不增加复杂选字设计。文件整理保护范围已确认，见产品设计。

“首个服务”只指选择哪个账号/模型用于验证，不表示缩减已确认的多供应商目标，也不自行决定订阅授权延后。

## 模型切换与思考强度

Pi `agent-session.ts:setModel` 检查授权、记录 model change，只有 persist 选项才改默认；按新模型能力选择 thinking level。`setThinkingLevel` 将档位限制到模型支持集合。`packages/ai/src/types.ts` 区分 Chat/Image 等能力类型；协议层分别映射 effort、budget 或开关，不能给每个模型发送相同字段。

月读采用多模型配置、默认文本/图片用途与每对话覆盖。多能力模型可复用同一连接与身份，内部按能力选接口。思考强度按实际能力显示；切换后原档位不受支持时提示实际使用档位，不静默发送无效参数。运行中切换在下一请求生效、当前请求保持原模型，旧消息记录实际模型与设置；这不更改固定的初始书籍上下文。每个运行任务拥有自己的 SDK 流与工具状态，不共享可变全局 model 设置。

## 认证与请求边界

- 复用 Swift SDK 的 provider 和内部工具循环；应用负责连接、Keychain、登录/退出、刷新、模型目录及会话生命周期。Codex 请求已通过 baseURL、headers、providerOptions 和公开 fetch 接口接入，不修改 SDK 内部。
- 每个运行任务拥有可取消 transport。停止同时通知 SDK 并取消该任务的请求；不得使用全局会话取消影响其他对话。SSE 及时交付，不沿用默认 16 KB 等待行为。
- OAuth 与计费方式独立，具体供应商差异见 [支持范围](ai-providers.md)。没有可用订阅权限时明确显示，不自动转为按量连接。
- 当前身份层使用官方 ChatGPT SIWC，不保留 Codex 设备码；SFSafariViewController + loopback 的模拟器合成验证与真实用户登录分别验收。
- 公开 ChatGPT token-sharing 与 Codex backend 是两条不同通道。公开路径的 loopback 注册、参数与工具限制不能直接推广到 Codex；其移动接入限制在接入该路径时处理。已实测 Codex 生图及参考图编辑可用，见上文，不再标为未验证。

公开路径参考：[注册契约](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[模型与推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)、[限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)。原生 OAuth 可参考 [RFC 8252](https://www.rfc-editor.org/rfc/rfc8252.html) 与 [AppAuth-iOS](https://github.com/openid/AppAuth-iOS)；平台有回调 API 不代表供应商接受任意 redirect URI。

## 工具循环与应用会话层

Swift SDK 支持多步 agent loop。`Agent` 的 generate/stream 默认 stopWhen=stepCountIs(20)，底层 generateText/streamText 默认只有一步，接入时明确配置。20 是库默认值，不是月读已定产品限制。应用提供工具 execute，SDK 把结果加入后续模型输入，满足继续条件时再请求。

SDK 的继续条件要求工具调用及结果完成，不能通过调高步数上限替代用户消息队列。应用负责完整历史、摘要检查点、steering/follow-up 及下一轮调度；prepareStep 的上下文/模型替换和真实工具往返均已验证。具体队列与压缩逻辑在实现时检查，不重复开发 SDK 已有的基础循环。到达上限时展示当前进展与停止原因，不能伪装为任务完成。
