# AI 实现核对

2026-10-04 的底层审查；2026-10-16 身份层已改官方 ChatGPT SIWC，具体协议与待验收边界见 [供应商与身份](ai-providers.md)。范围为月读现有 AI 模块、连接预设和已确认工具，不新增供应商、网页抓取器、文件整理或封面应用页面。这里记录全部检查维度和已发现问题，不以“主要问题”缩减范围，也不声称不存在潜在缺陷。

## 依据

- 本地 Pi `200387122ca450d6387f033949423114a270b96c`：`packages/ai/src/api/{simple-options,transform-messages,openai-completions,anthropic-messages}.ts`、`scripts/generate-models.ts`、各认证/供应商模块；`packages/coding-agent/src/core/compaction/compaction.ts`。
- 锁定 Swift AI SDK `df3e071`：四协议 provider、TypedTool、streamText/prepareStep、metadataExtractor、generateImage、GeneratedFile。按实际 Swift 源码使用接口，不把 TypeScript README 的名字直接当 Swift API。
- 本机插件 `pi-web-access`、`pi-codex-image-gen`、`pi-xai-oauth`：分别检查 xAI 精简搜索请求/来源解析、Codex 工具参数、xAI Images 单/多参考图接口。
- [阿里思考参数](https://www.alibabacloud.com/help/en/model-studio/deep-thinking)、[OpenRouter 推理回放及预算](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens)、[Fireworks 思考接口](https://docs.fireworks.ai/guides/reasoning)、[xAI 图片接口](https://docs.x.ai/developers/model-capabilities/images/generation)。公开能力说明不等于本机账户权限。模型列表字段及分页另核对 [Gemini Models](https://ai.google.dev/api/models) 和 [Anthropic Models](https://platform.claude.com/docs/en/api/typescript/models/list)。

## 模块覆盖

| 模块 | 检查结论及处理 | 验证方式 |
| --- | --- | --- |
| 认证与连接 | API key 与额度类型独立；API Key、ChatGPT SIWC 与 OpenRouter 三种认证方式各自处理。删除旧 Codex 设备码及借用 client ID；刷新协调及请求取消按连接隔离 | SIWC 回调、OIDC、过期/取消、OpenRouter 一次性 PKCE 合成回归 |
| 目录与用途 | 精确供应商匹配；ChatGPT 账户目录与其他公开目录分开。补入图片模型，纯图片模型不能成为默认对话模型；自定义 Gemini/Anthropic 目录按协议读取容量和分页，删除旧 Codex slug 解析假设 | 目录快照、缓存失败、用途默认值与筛选回归 |
| 思考控制 | effort、toggle、budget 区分；预算映射1024/2048/8192/16384并遵守模型上下限。阿里发送 thinking_budget；OpenRouter 区分 enabled/max_tokens/effort；Gemini 区分 budget/level；Anthropic 手动与 adaptive 分开 | 参数断言及真实 SDK 请求捕获 |
| 通用 Chat | 开启 include_usage；DeepSeek 补必要的 assistant reasoning_content；Mistral 工具 ID 保持9位；其他跨协议 ID 成对规范化 | 请求适配、历史二次请求、ID配对回归 |
| 推理与历史回放 | OpenRouter reasoning_details 通过 SDK 扩展点累积，文本片段合并、加密段保留；原连接原模型回传，切换时剥离不透明数据 | 两轮真实 SDK/URLProtocol 回归；历史隔离测试 |
| 缓存与 usage | Responses 稳定 promptCacheKey；Anthropic cacheControl；OpenRouter Anthropic 系统/工具/末条消息缓存断点。usage 中缓存读写单独保存，不重复加到总输入 | 请求断点、上下文计算回归；没有声称合成请求证明服务端命中 |
| Agent循环与队列 | 使用 SDK 工具循环；应用负责 steering/follow-up、模型切换、持久化、取消；不增加自动失败重试 | 队列、停止、切换模型、工具失败/确认回归 |
| 上下文与压缩 | 正式输出不再统一压到8192；优先最近实际 usage 加后续消息估计，没有配置指纹使旧 usage 失效；摘要上限13107，超大历史条目分片；摘要沿用当前思考档位 | usage、中文估计、压缩检查点/失败保留、Unicode分片回归 |
| 读取工具 | TypedTool 负责类型契约；read/rg/marks 有页数、行/字节预算和游标，长评论按需读取；范围、章节修正与最终数据通过查询层输出 | AIReadingTools 与 Rust 对应回归，详见 tools.md |
| 原生搜索/图片 | 分通道执行，见下表；图片存文件、历史仅保存引用；范围校验、取消和失败清理一致 | 各通道不同协议样例，不复用 Codex 响应伪装其他服务 |
| 数据与页面 | 应用级唯一运行器；未发送会话不落库，关页不中断，终止/删除不复活；列表主题、过程与最终回复分离 | 生命周期、重开、删除、主题及过程渲染回归 |

## 原生能力通道

| 连接 | 搜索 | 图片 |
| --- | --- | --- |
| OpenAI API | SDK Responses web_search | 文本执行模型的 hosted image_generation；图片模型走 SDK Images |
| ChatGPT | 公共 Responses web_search，受账户／型号策略限制 | 官方 SIWC 不支持，不进入用途选择器 |
| xAI API Key | api.x.ai/v1/responses，只发送 model/input/tools；解析 annotations、action.sources、citations | api.x.ai/v1/images/generations或edits；单图 image，多图 images；请求 b64_json，不套用 OpenAI hosted 工具 |
| Google | SDK Google grounding | Imagen predict；Gemini 图文模型使用内容接口及 TEXT/IMAGE modalities，读取 SDK files |
| 其他已有供应商/自定义端点 | 不从普通 tool_call 推断原生搜索 | 不从模型名推断 hosted 图片能力 |

## 保留的明确边界

- 目录的原始思考资料与可发出的控制分开。未核实 toggle/budget wire 参数的通用网关仅开放已有 effort 控制；NVIDIA 依 Pi 通用适配不发送 reasoning_effort。不能把“有思考能力”写成“月读已接入所有调节方式”。这部分不是全型号的控制能力验收。
- 自定义目录缺失输出上限时，仅按已知上下文限制输出，不猜测固定输出规格。上下文缺失需配置，不能猜测。
- 使用能力筛选得到的是已实现的请求通道。服务端是否允许某个账户、型号执行 hosted tool，仍由实际请求决定；不静默切换账户、端点或付费方式。
- 本轮不读取真实凭证、不产生真实付费请求。协议样例能验证编码、解析和生命周期，不能证明所有账号、套餐和最新模型均可用。
- 本轮不自动新增 Pi 所有扩展。业务资料预览、封面应用及文件整理仍按产品计划处理，与底层接口审查区分。

具体构建与测试结果记在 verification.md，避免在多个文档复制运行状态。

## 工具服务设置与默认选择检查

- 默认对话模型选择器只处理对话；联网搜索和图片生成使用独立的服务优先设置。模型选择受具体连接和原生适配器约束，未设置不注册对应工具，不自动选择其他连接。
- OpenAI API hosted 生图选的是执行模型；实际绘图模型由服务决定。直接 Images、Imagen 和 Gemini 图片输出仍使用各自通道的模型。页面按路由表达。
- 已核对 Agent、数据、UI 与 Providers 中的 Codex/model 字面量。删除仅凭 Codex 认证就补出文字能力的分支；显式目录能力保持。旧设备码、私有请求头与静态 Codex 目录已删除；ChatGPT 使用官方身份层、账户目录与公共 Responses。
- 连接级服务资格独立于已加载模型，未登录或未获取目录时仍可管理连接；最终保存与调用再次检查具体模型路由。多个账户按 connectionID 隔离，不默认挑第一个。
