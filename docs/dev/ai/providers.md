# AI 供应商、身份与请求

本文维护应用已采用的协议边界；官方参考沿用 2026-10-16 的核查记录，服务权限和分发范围不因本次整理重新获得保证。模型字段/缓存以[模型目录](model-catalog.md)为准，旧接入取舍见[历史依据](../research/ai-integration-history.md)。

## 连接与协议

- 连接分别保存供应商目录 ID、显示名称、区域/套餐端点、协议、认证方式和额度类型。页面按独立连接管理；API Key 只进入月读 Keychain，保存后显示“已配置”，不声称已验证账户权限。
- 复用锁定 Swift AI SDK 的 Responses、OpenAI-compatible Chat Completions、Anthropic Messages、Gemini 模块，以及应用已有唯一任务/持久化服务。没有复制 SDK 的 agent loop。消息中的不透明协议字段按连接与模型隔离，防止不同兼容服务之间回放。
- 预设覆盖 OpenAI、Anthropic、Google、xAI、DeepSeek、Mistral、Moonshot 国内/国际、Alibaba 国内/国际与 Token Plan、Z.ai/智谱普通与套餐、MiniMax 国内/国际与套餐、Kimi Code 国内/国际、Xiaomi 普通及区域套餐、OpenRouter、OpenCode Zen/Go、Groq、Cerebras、Together、Fireworks、DeepInfra、Hugging Face、Ant Ling、Baseten、NVIDIA、Vercel AI Gateway、Meta。四种协议均可自定义 HTTPS 端点；模型可手动添加，刷新目录保留手工记录。
- ChatGPT 账户只读取所选账户的公共 `/v1/models`，按 `visibility=list` 及服务器顺序提供型号，不补入 Pi 型号或 API 容量。其他预设从 models.dev 的精确供应商目录加载文本与图片模型；自定义连接尝试其 `/models`，无目录时可手动添加。这些公开清单表示服务模型资料，不授予账户调用权限。
- OpenCode 单个模型的 `provider.npm` 决定实际请求协议，每个会话发送 `x-opencode-session`。其他供应商默认协议由连接预设明确指定，不根据型号名称猜测。
- 用户决定移除 Kimi、Meta 和 xAI 的订阅／设备码登录。Kimi 国内／国际会员 API Key、Meta API Key 和 xAI API Key 保留；Kimi 连接页提供官方控制台引导，权益与适用工具范围以服务商说明为准。ChatGPT 账户使用官方 SIWC，旧 Codex 设备码与私有网关已删除，不迁移旧开发连接。
- OpenRouter 保留官方无回调 PKCE：浏览器完成授权后粘贴一次性代码，换取 API key；verifier 仅在内存中保留。ChatGPT 通过无痕 ASWebAuthenticationSession 与随机端口 loopback 完成授权，不提供设备码。
- 请求参数已区分 OpenRouter/Ant Ling 的 `reasoning.effort`、Together 的 `reasoning.enabled`、智谱/DeepSeek/Moonshot/Xiaomi 的 `thinking`、Alibaba 的 `enable_thinking`；Moonshot K3 使用其 effort 参数。仍复用 SDK 编码、流解析和工具循环。目录保留预算类型及上下限：Anthropic 区分预算与 adaptive，Kimi 使用其 adaptive 接口；Gemini 区分 budget 与 level；Baseten 使用目录声明的 toggle/effort，OpenCode 保留已知型号协议修正。未选择可调控制时保持服务默认值，不新增预算编辑器。OpenRouter/Baseten 使用稳定的会话标识；工具推理字段回放复用 SDK。
- 当前范围：完善现有供应商，不再新增边缘服务。SIWC 按下文官方边界实现；Radius、Azure/Bedrock/Vertex/Cloudflare、TypeSafe 不纳入本轮；不为 Mistral 新增 Conversations 协议。Anthropic 保留 API key，不复制官方客户端身份。历史 Pi 范围不作为开发待办。
- Qwen Individual 与现有 Alibaba 国际 Token Plan 共用端点与 key，Pi 的区别是更窄的模型清单；当前没有新增一个重复登录入口，也没有把公共目录当作套餐授权范围。不单独建设 Individual 配置。

原生工具已接入 ChatGPT 账户的允许搜索、OpenAI API 搜索与生图、xAI API Key 搜索与 Images、Google grounding/Imagen/Gemini 图片输出。具体通道、默认用途和限制见[原生工具](native-tools.md)。本轮协议回归使用合成认证，未新增真实账户证据，不能把适配器实现当作所有账号的能力验收。

### 授权实现与未完成边界

| 路径 | 当前状态 | 尚需工作 |
| --- | --- | --- |
| Kimi、Meta、xAI | 仅 API Key；Kimi 会员控制台引导 | 会员权益与调用范围按服务商规则，API Key 不代表所有场景获得许可 |
| OpenRouter | 已接入官方 headless PKCE，10 分钟一次性授权码 | 真实浏览器授权与推理 |
| Anthropic 订阅 | 不使用伪装官方客户端的登录 | 官方面向第三方应用建议 API key；不列为可以直接复制的 OAuth 待办 |
| ChatGPT SIWC | 官方动态注册、loopback、OIDC 校验与公共 Responses 已接入 | 已有用户真机登录、普通回答和目录证据；刷新/失效等分支仍需对应验证 |
| Radius | 未接入 | 动态网关配置、设备码认证与专用 pi-messages SDK model adapter；不能仅增加 OpenAI 兼容预设 |

依据：[Claude 第三方接入说明](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account)、[OpenRouter PKCE 与无回调授权](https://openrouter.ai/docs/guides/overview/auth/oauth)、[ChatGPT SIWC 注册与身份验证](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)，以及本地 Pi `auth/oauth/{openrouter,radius}.ts`。源码协议回归不替代真实账户验收。

官方认证参考：[Grok CLI](https://docs.x.ai/build/cli/reference)、[Kimi 会员与认证](https://www.kimi.com/en/help/kimi-code/membership-guide)。官方客户端支持设备码不等于已验证月读的所有账户权限。

## ChatGPT 账户：官方 SIWC 替换契约

2026-10-16：按用户批准的官方边界替换为“ChatGPT 账户”。删除旧设备码、借用的 CLI client ID、Pi Codex 目录及私有 backend-api 路径，不迁移旧开发连接。用户真机已验证登录、普通回答与账户目录（5.6–6.1，自动返回上下文容量）；这不代表所有恢复分支或分发许可已验收。

- **适用前提：**官方说明面向开源、本地托管应用，付费或远程托管应用需走 interest form；当前页面未列出注册请求中的仓库 URL 或仓库可见性检查步骤，不能据此声称私有分发已获许可。月读不会借用其他客户端 ID。见[范围与 host 定义](https://developers.openai.com/siwc/token-sharing-open-source)、[快速开始](https://developers.openai.com/siwc/quickstart)。
- **注册：**host 首次使用前生成并在 Keychain 保留稳定的 `urn:uuid:` 标识；初次授权用 `dynamic_agent_client`、`agent_name_hint=Moonread` 和该 host ID。回调必须返回实际签发的 client ID，后续授权与换 token 均使用它，而非动态入口字符串。同一注册与经过验签的账户身份绑定；新登录在完成校验前不能覆盖当前账户。见[注册与登录](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)。
- **回调与身份：**先监听 `127.0.0.1`，路径固定 `/auth/callback`，端口可变；同一次请求与 code exchange 的完整 URI 必须相同。每次生成 PKCE S256、state 和 nonce，回调一次消费并校验 state，再换 code。使用官方公开 JWKS 验签 ID token，同时校验 issuer、签发 client ID 对应的 audience、有效期和 nonce；身份取校验后的 sub。没有 `chatgpt.tokens.use.direct` 授权时不得发套餐推理请求。 令牌交换成功且身份有效时，即使缺少该 scope 仍保存账户和签发 client 的绑定，连接页显示“你没有允许月读使用 ChatGPT 套餐”及“重新授权”。主动重新授权沿用保存的 client、完整 scope 与 `prompt=consent`；普通登录不强制重复同意。见[错误与恢复](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)。凭据只进月读 Keychain，不进入 URL、日志或会话附件；官方允许的 `id_token_hint` 仅发往授权端点，相关 URL 不记录。见[注册与登录](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[会话与刷新](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)。
- **刷新与恢复：**使用签发的 client ID、轮换 refresh token 和 `resource=https://api.openai.com/v1`，同一会话串行刷新，原子替换 token／scopes／有效期。刷新返回 `invalid_grant`、`invalid_refresh_token`、`token_expired`、`refresh_token_expired`、`refresh_token_invalidated` 或 `refresh_token_reused` 时，清除该失效 token 集并提示重新登录，保留验签身份／client 映射；迟到的旧 token 失败不影响新登录。`invalid_client` 提示配置错误，网络及临时服务错误不清凭据。普通退出撤销会话、清除 token，但注册映射保留已授予 scopes；正常再登录不强制同意，只有记录为未授予套餐许可时才 `prompt=consent`。删除连接同时删除该连接的 registration 和临时 client 映射，保留应用级 host ID。见[会话与刷新](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)、[错误与恢复](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery)。
- **错误与标识：**连接卡片与模型选择弹窗共用“已登录且已授予 `chatgpt.tokens.use.direct`”规则显示“正在使用 ChatGPT 套餐”及用量入口，身份登录不代表套餐授权。非 2xx 结构化 `error` 与流内 `response.failed`／`error` 共用分类，保留原始 code、param 和 message；账户不合资格、不支持的能力或路由、身份／授权上下文、用量及临时账户不可用分别显示原因。原生搜索保留 SDK error 事件底层错误，ChatGPT 结构化错误映射为工具错误的 code／field（来自 param）与本地化说明；401 沿用统一失效入口，取消传播，其他服务保持通用错误。未知 code 仍保留，不降为“回复未完成”；非结构化错误保留原 HTTP 状态与正文。不自动重试未改变的请求、不自动切换计费。
- **确认失效：**模型目录 401、Responses 401 和终止性 refresh 错误统一进入连接服务的登录失效入口，清理当前 token、保留 SIWC 注册、移除已认证标记并更新 needsLogin。后续取凭据直接拒绝，已有模型快照不能恢复登录状态。用不可逆的会话指纹比较实际发出请求的凭据与当前凭据，迟到的旧 401 不得清理新登录；指纹不持久化，不在错误中携带明文 token。
- **模型与请求：**同一账户 token 请求公共 `/v1/models`，只展示 `visibility=list` 的 models，保留服务器顺序，以 display_name 展示、slug 请求。推理只用公共 `/v1/responses`，每次 `store=false`、`stream=true`，发送完整所需历史，不能使用 HTTP previous_response_id；以 response.completed 才算成功。见[模型与推理](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)。
- **容量与能力：**账户明确字段、用户预算、刷新与未知能力规则统一见[模型目录](model-catalog.md)。不能借 API 元数据扩大账户能力。
- **预览约束：**system 历史改用 instructions／developer；删除不支持的参数；函数工具使用 namespace 或 additional_tools。按账户允许的 web search 可用；图片输入须有模型能力证据，账户目录未明确提供时保持未知并禁用附件，不借公共 API 元数据推断权限。图片生成在用途选择和请求边界都禁止；API Key 通道保持原有能力。见[官方预览限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)。

### 浏览器与平台边界

正式实现使用 `ASWebAuthenticationSession`，每次在 start 前设置 `prefersEphemeralWebBrowserSession=true`，不复用浏览器的 Google／OpenAI cookie，使每次都能重新选择账户。展示锚点取登录页当前窗口；使用不会被授权流程触发的 `moonread-auth-session-unused` 自定义 scheme 保持会话，独立 listener 接收 HTTP 回调。loopback 校验通过后由应用主动取消浏览器会话并在应用内继续换 token；用户关闭窗口则结束尝试并显示“已取消登录”。删除 SFSafariViewController 的生产路径，避免独立持久 cookie 使多 Google 账户无法切换。OpenRouter 也使用同一无痕浏览器，但其无回调 PKCE 仍需关闭浏览器后粘贴代码，关闭仅收起窗口，应用内“取消登录”才结束该次尝试；不伪造为 custom-scheme 或 HTTPS 回调。Apple 的[浏览器会话](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)、[本地端点绑定](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint)、[本地网络隐私](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)提供平台依据；模拟器不能代替真机本地网络隐私验收。已记录的用户试用不替代刷新、账户失效、取消及最低系统验证。

## 通用请求与回放边界

- 普通 Chat 请求开启 usage；DeepSeek 的必要 assistant reasoning_content、Mistral 的9位工具 ID及跨协议调用/结果 ID配对集中在 Providers，不让 UI 补参数。
- OpenRouter 不透明 reasoning_details 经 SDK 扩展点保存，只在原连接原模型回放，切换时剥离；不把供应商签名当普通可迁移文本。
- Responses 的稳定 promptCacheKey、Anthropic cacheControl 与 OpenRouter Anthropic 的缓存断点由适配层负责。usage 中缓存读写单列，不重复加进总输入；请求字段正确不证明服务端实际命中。
- 字段类型、范围、UTF-8、模型真实容量、来源引用与服务要求保留；不增加通用工具轮数、重复调用拒绝或固定超时。执行策略见[Agent](agent.md)，结果分页和输出预算见[工具](tools.md)。

## 思考参数适配

目录同时保存 `reasoning_options` 的类型、values、min/max，不只保留 effort 字符串。effort 使用服务声明值；toggle 显示开/关；只有预算控制时显示应用的 minimal/low/medium/high 四档。原始控制信息仍保留，未有明确请求映射的控制不生成假的 effort 参数。NVIDIA 的通用适配参照 Pi 不发送 reasoning_effort；它的模型思考能力与可调控制分别处理。请求层按协议转换：Anthropic 的预算模式使用 enabled/budget_tokens，自适应模式使用 adaptive/effort；Gemini 按目录区分 budget/level。预算模式需要把已选档位转成预算时，使用应用内部的 1024/2048/8192/16384 token 档位并服从目录上下限；这不是供应商宣称的档位规格。没有显式选择时不覆盖服务默认值。

ChatGPT 使用账户目录，不能回退到旧 Codex 静态清单。OpenCode 的 provider.npm 路由附带已核对的少量端点修正；修正集中于 Providers，不进入 View。复用 SDK 的工具消息转换；OpenRouter reasoning_details 通过 SDK metadataExtractor 保存并在原连接原模型回放，跨模型时剥离。OpenRouter/Baseten 追加稳定会话标识；OpenRouter 的 Anthropic 模型还写入缓存断点，直接 Anthropic 使用 SDK cacheControl。缓存不增加设置页。
