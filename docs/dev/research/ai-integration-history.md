# AI 接入的历史依据

本页汇总 2026-10-03 至 10-16 的选型和审查记录；外部资料未因本次文档整理重新核验。依赖以锁文件为准，现行身份/模型/执行/显示契约见 [AI 架构](../ai/architecture.md)。历史可行不等于当前全部供应商、账号或设备验收通过。

## 执行与目录的固定源码

| 核对对象 | 已确认接口/行为 | 月读负责 |
| --- | --- | --- |
| 2026-10-04 调研时的 Swift AI SDK `df3e071ac414858a4d57e1cd48b3f686e92ab1ce`，`GenerateText/StreamText.swift` | tools、prepareStep、onStepFinish、stopWhen、fullStream、usage；默认停止条件只有1步 | 注册业务工具，显式配置循环条件、保存每一步，不能只保存最后文字 |
| `GenerateText/PrepareStep.swift` | async throws；读取 messages/steps，返回 messages/model/activeTools/system/providerOptions | 排队消息注入、每步预算、压缩后输入和下一请求配置 |
| `SwiftAISDK/Tool/TypedTool.swift`、`AISDKProviderUtils/Tool.swift` | Codable typed 输入/输出、schema validator、执行结果 resolve、needsApproval | 补 schema 约束、对象/跨字段规则、取消业务工作、确认界面 |
| `GenerateText/RunToolsTransformation.swift` | 校验调用、approval事件、为执行调用创建 Task；不能假定同批调用按顺序完成 | 并行执行、稳定消息顺序、取消/等待的协调；写入不混入自动并行读取 |
| 本地 Pi `200387122ca450d6387f033949423114a270b96c`，`packages/agent/src/agent-loop.ts` | 工具循环边界接收 steering，结束后处理 follow-up；支持执行策略 | 沿用用户已确认语义，不引入第二套基础推理循环 |
| Pi `packages/coding-agent/src/core/compaction/compaction.ts` | usage/增量估算、保留近期、摘要检查点；默认16384预留/20000近期预算，部分采用chars/4 | 使用 Pi 的预留、近期保留目标与估算规则 |

SDK 源码来自 `build/AIDerivedData/SourcePackages/checkouts/swift-ai-sdk/Sources/`；Pi 来自 `https://github.com/badlogic/pi-mono/`。公开参考：[Swift AI SDK](https://github.com/teunlao/swift-ai-sdk/tree/df3e071ac414858a4d57e1cd48b3f686e92ab1ce/Sources)、[JSON Schema 对象规则](https://json-schema.org/understanding-json-schema/reference/object)。实际编译以锁定版本为准，不使用上游 TypeScript 或当前网页的新 API 冒充 Swift 已有能力。


## Pi 怎样获取和保存

核对的是本机 `pi` 源码，路径相对于该仓库：

- `packages/ai/scripts/generate-models.ts`：生成阶段读取 models.dev、OpenRouter 等，输出内置目录。部分来源为 agent 场景过滤掉无工具调用的模型；月读还需要图片模型，不照搬该过滤条件。
- `packages/ai/src/models.ts`：`getModels` 读取当前快照；`refreshModels` 才负责恢复缓存和可选网络刷新。静态 provider 文件本身没有请求，不代表上层运行时没有刷新。
- `packages/coding-agent/src/core/model-runtime.ts`：加载内置目录，为大多数内置 provider 包装远端目录，默认创建磁盘 `models-store.json`；启动时可先只恢复本地数据。
- `packages/coding-agent/src/core/remote-catalog-provider.ts`：运行时目录来自 `pi.dev/api/models/providers/<provider>`；先发布已缓存记录，再检查网络条件。正常缓存窗口 **4 小时**，强制刷新可跳过；使用 ETag 条件请求，304 只更新检查时间。缓存含模型、`checkedAt`、`lastModified`、`etag`，旧于内置生成时间的覆盖不会取代内置数据。
- `packages/coding-agent/src/core/models-store.ts`：持久 JSON 文件按 provider 保存，并保留进程内读取缓存。
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`：界面初始化后后台刷新；部分模型管理入口也会触发刷新。`model-catalog-refresh.ts` 合并同时发生的刷新。

本次另核对 Pi `200387122`：`openai-codex.ts` 使用生成的内置目录，没有账户 `/models` 获取器；coding-agent 层仍会包装 Pi 公共远端目录。因此不能概括为 Pi 完全不请求模型资料。

因此，Pi 有本地记录；“打开界面触发刷新”不等于“每次重新下载”。4 小时规则属于上述远端目录包装层，并非所有自定义 provider 必须遵守的通用规则。


## 2026-10-30 模型目录补充调查

以下整理自 Grok 的只读源码回报，未在本次文档整理中逐项复核调用链，也未发真实目录请求、读取凭据或运行应用。固定来源为 [Pi e7a0df27](https://github.com/earendil-works/pi/tree/e7a0df27c09d11bf4161d3605246cbf57a129cb2) 与 [Zed 025d2a06](https://github.com/zed-industries/zed/tree/025d2a06ee7920777bf4947f11e46a1f52e62cbb)。上文 `200387122` 和 `generate-models.ts` 是旧版本依据，不作为这两个新快照的路径说明。

**两者没有统一的“公开目录非空便跳过账户目录”或“所有供应商优先账户 /models”规则。** 按供应商和认证方式区分资料、可访问型号与元数据来源。月读的候选改进由 [#149](https://github.com/suxiaoshao/moonread/issues/149) 跟踪；研究不改变[当前模型目录契约](../ai/model-catalog.md)。

| 层次 / 通道 | Pi 固定快照 | Zed 固定快照 |
| --- | --- | --- |
| 内置与公开目录 | `catalog/generate.ts` 构建期获取 models.dev v2 及部分供应商目录；models.dev 筛 tool-capable chat，缺省容量填 4096。coding-agent 为除 Radius 外的内置供应商包装 pi.dev 目录，4 小时与 ETag 缓存；无凭据刷新只恢复缓存，PI_OFFLINE 禁网 | 没有共同的 models.dev 运行时目录；OpenCode 使用 models.opencode.ai，磁盘新鲜期 5 分钟、每小时刷新 |
| OpenRouter | 公共目录之后请求 `/models/user`；401/403/404 保留全目录 | 只请求 `/models/user`，没有先公开目录再过滤 |
| Copilot | 登录/token 刷新时请求账户 `/models`，只过滤 ID，不替换元数据 | 请求 endpoint 的 `/models`，筛 picker、chat、policy enabled；失败没有静态回退 |
| Anthropic、Google | 普通内置供应商沿公共目录包装，不能推导为账户目录替换 | 账户 `/v1/models`、`v1beta/models` 为主源，设置追加/覆盖；Anthropic 缺 token 上限丢弃，不从公开资料补；Google 部分思考档位按 ID 推断 |
| OpenAI API 等 | 普通 OpenAI API 运行时没有用户 `/models`；`models.json` 自定义模型手写 | OpenAI API、xAI、Mistral、DeepSeek、Bedrock 使用内置枚举和 settings available_models，不请求 `/models` |
| ChatGPT / Codex | openai OAuth 仍用 API 目录，仅对 OAuth 隐藏 classifier；openai-codex 是另一份手写订阅列表，注释中的端点不是运行时请求 | ChatGPT 初始静态表；加载凭据或登录时成功请求 `chatgpt.com/backend-api/codex/models?client_version=0.999.0` 后整表替换，筛 visibility=list 并按 priority 排序；失败留旧表，未实现 refresh_models |
| 本机与其他来源 | llama.cpp 扩展、Radius 使用本机/账户目录替换 | Ollama、LM Studio、llama.cpp 用本机目录；compatible 连接手写；Zed Cloud 登录后取自有 `/models`，签出清空 |

月读非 ChatGPT 且公开目录非空时跳过 `auth.models` 是自己的分支；24 小时缓存、models.dev v1 及容量策略也是自选。月读 SIWC 的 `api.openai.com/v1/models` 与 Zed Codex 的目录端点不同，不能互换。Pi/Zed 的目录也不能授予账户调用权限。

未在线核对 pi.dev 与 models.dev v1/v2 字段差异、Copilot 企业端点、OpenRouter 区域代理和 SIWC/Codex 目录同构性。上述回报没有完整逐项行号；实现 #149 前需按供应商补查，不把摘要当作线上验收。

## 选型与退出的路径

- 早期调研曾推荐 SwiftStreamingMarkdown；正式界面已经采用 UITableView 块列表 + MarkdownView，旧建议不再是实施依据。技术选择和性能候选分别见[消息呈现](../ai/rendering.md)与[性能](../engineering/performance.md)。
- Pi 的供应商适配、工具边界、用量估算与压缩提供固定版本参照；月读复用 Swift AI SDK，不移植另一套 TypeScript Agent。Pi 自带自动重试与应用所选“普通网络失败不自动重试”不同，不将两者混写。
- 2026-10-16 移除借用其他客户端身份的 Codex 设备码/私有网关路径，改官方 ChatGPT SIWC。此前成功的历史请求不证明新的官方登录、刷新或分发范围。
- 同日不保留 GitHub Copilot OAuth 接入：OAuth 登录 GitHub 与官方支持第三方直接调用 Copilot 推理是不同问题。也不将历史文稿中“issue #19”当作当前仓库关联（当前编号是其他任务）。Kimi/Meta/xAI 保留 API Key，移除其订阅/设备码登录；OpenRouter 保留官方 PKCE。
- 历史审查覆盖四协议、参数转换、不透明推理回放、缓存 usage、取消/队列/确认、原生搜索/图片和持久化。协议样例只证明适配和生命周期，不证明真实套餐权限、付费调用或服务端缓存命中。

## 证据边界

2026-10-16 的模拟器 loopback 探针用合成 code 验证浏览器返回本机 listener，未访问真实认证或读取凭据；用户真机随后确认的登录/普通回答/账户目录范围见[验证历史](../engineering/verification-history.md)。旧 SDK 调研基线、临时探针与阶段测试数量不作为新增测试要求。

完整旧调研与实现审计保留在 Git 历史：[6dc282a 的 AI feasibility](https://github.com/suxiaoshao/moonread/blob/6dc282a/docs/dev/engineering/ai-feasibility.md)、[providers](https://github.com/suxiaoshao/moonread/blob/6dc282a/docs/dev/engineering/ai-providers.md)、[implementation audit](https://github.com/suxiaoshao/moonread/blob/6dc282a/docs/dev/engineering/ai-implementation-audit.md)。这些是有日期的证据，不是当前规范。
