# AI 供应商与能力支持范围调研

## Copilot OAuth 研究与移除决定（2026-10-16，issue #19）

因官方目前未提供可用于本项目的 iOS 原生接入路径，用户于 2026-10-16 决定完全移除 Copilot 支持，上架版与开发版均移除。保留下列研究结论，不再进行可行性测试。现已删除连接、认证、目录与现行支持路径，不为已保存的 Copilot 连接增加迁移或兼容实现。

### 注册与公开配置

应用名 Moonread，说明 Moonread iOS reader，首页与必填 redirect URI 均为 `https://suxiaoshao.github.io/moonread/`。启用 Device Flow、不启用 wildcard、不生成 client secret。页面默认启用 expiring user access tokens，保持默认。用户已亲自点击注册；Client ID 未读取或记录。注册的 OAuth App 暂时保留，删除另由用户决定。上述新站地址待仓库公开切换后在 GitHub OAuth App 设置更新；当前注册仍使用旧 moonread-site 地址，本次不修改 GitHub 设置。

未发起设备码、未取得用户 token、未调用内部兑换或聊天接口；没有凭据临时文件需要清理。只读 SDK 源码证据保存在 build/ 下，不包含用户凭据。

### 已确认的 OAuth 端点与生命周期

| 用途 | 正式端点与契约 |
| --- | --- |
| 设备码 | `POST https://github.com/login/device/code`，传自己的 `client_id` 与所需 scope |
| 用户批准 | 系统浏览器打开响应的 `verification_uri`，用户输入 `user_code`；不使用网站回调接收 token |
| 轮询 | `POST https://github.com/login/oauth/access_token`，传 `client_id`、`device_code`、`grant_type=urn:ietf:params:oauth:grant-type:device_code`；遵守 interval／slow_down、取消与失效 |
| 身份核对 | `GET https://api.github.com/user`，使用用户 OAuth token；每次登录核对账号，不能把不同账号的共享许可或模型缓存混用 |
| 刷新 | 同一个 access_token 端点，`grant_type=refresh_token`、`client_id`、真正的 `refresh_token`；设备码获得的 token 刷新不要求 client secret。原子保存轮换后的两种 token 及有效期，旧 token 对在刷新后失效 |

设备码初始换取和刷新均不需在 App 内嵌 secret；勾选到期策略后须解析 `expires_in`、`refresh_token_expires_in`，不能把 GitHub access token 塞到 refreshToken 字段冒充刷新凭证。过期／撤销重新授权；不打印响应 token。[GitHub OAuth device flow、到期及刷新契约](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps)。

### 官方 Copilot 支持与直接 HTTP 的区别

官方确认：应用获得自己的用户 OAuth token 后交给 Copilot SDK 的 `gitHubToken`，关闭 `useLoggedInUser`，使用该用户的 Copilot 订阅；token 的存储、刷新和有效期由应用负责。SDK 文档接受 `gho_`／`ghu_`，不要求调用者先兑换一个 Copilot 请求 token。[认证](https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate)、[自有 OAuth 配置](https://docs.github.com/en/copilot/how-tos/copilot-sdk/setup/github-oauth)。这只是 SDK 调用方契约，不能据此断言 runtime 内部没有交换、或现有 HTTP 接口允许直接传 GitHub token。

SDK 通过 JSON-RPC 连接 Copilot runtime；官方 Node 源码把显式 token 传给子 runtime 的认证环境，或随 session 请求交给 runtime。它不是现有 Swift AI SDK 的 Chat／Responses／Messages HTTP provider。上述两篇文档没有公开第三方原生 App 的模型 HTTP URL、必需 headers，或 `copilot_internal/v2/token` 的支持契约。[官方 SDK 架构](https://github.com/github/copilot-sdk#architecture)、[官方 client 源码](https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts)。目前没有确认可直接嵌入 iOS 的同等 runtime；不能为月读未经决定增加服务器，或把 MCP URL 当成推理端点。

scope：现有 `read:user` 仅是用户资料读取 scope，并不是已确认的 Copilot 推理许可。两篇 SDK OAuth 文档没有规定一项 Copilot 专属 OAuth scope；不能自造 `copilot:use`，也不能把细粒度 PAT 的 `copilot_requests: write` 当成 OAuth scope。方案只申请确实使用的账号资料权限，不请求 repo、组织管理或邮箱权限；第三方 OAuth 的实际 Copilot 可用性仍须受支持路径验收。[OAuth scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)、[PAT Copilot Requests 权限](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)。

### 已移除实现与决定依据

移除前的 `AIAuth.swift` 借用 `Iv1.b507a08c87ecfe98`，设备码 scope 为 `read:user`；授权后以 GitHub token 调 `https://api.github.com/copilot_internal/v2/token`，保存交换 token，并将 GitHub token 放进 refreshToken 字段；到期重新交换。请求根从 `proxy-ep` 解析，默认 `https://api.individual.githubcopilot.com`；目录请求为该根的 `/models`。`AIProviderRequest.swift` 再用交换 token 交给 Swift AI SDK。这些是已移除 Pi 路径的源码事实，不是官方 SDK 对第三方 App 的认证承诺。

不能只替换 Client ID，也不能未经证实取消二次交换后直接给旧端点发 OAuth token。自有 OAuth → 官方 SDK/runtime 有官方依据；自有 OAuth → 原内部兑换／模型 HTTP 未取得同等依据。因此按用户决定直接移除，不增加后端或另一个 agent runtime。

上述接入路线不再实施。应用内实现已直接删除，不使用或删除已注册 OAuth App。

2026-10-04。本地 Pi `200387122ca450d6387f033949423114a270b96c` 与 Swift SDK `df3e071ac414858a4d57e1cd48b3f686e92ab1ce` 源码盘点。以下区分覆盖目标、源码证据与实测结果。现有选型验证已足以开工；未测服务在对应接入阶段检查，不要求先验证整个供应商清单。

## 当前产品接入（2026-10-16）

- 连接分别保存供应商目录 ID、显示名称、区域/套餐端点、协议、认证方式和额度类型。页面按独立连接管理；API Key 只进入月读 Keychain，保存后显示“已配置”，不声称已验证账户权限。
- 复用锁定 Swift AI SDK 的 Responses、OpenAI-compatible Chat Completions、Anthropic Messages、Gemini 模块，以及应用已有唯一任务/持久化服务。没有复制 SDK 的 agent loop。消息中的不透明协议字段按连接与模型隔离，防止不同兼容服务之间回放。
- 预设覆盖 OpenAI、Anthropic、Google、xAI、DeepSeek、Mistral、Moonshot 国内/国际、Alibaba 国内/国际与 Token Plan、Z.ai/智谱普通与套餐、MiniMax 国内/国际与套餐、Kimi Code 国内/国际、Xiaomi 普通及区域套餐、OpenRouter、OpenCode Zen/Go、Groq、Cerebras、Together、Fireworks、DeepInfra、Hugging Face、Ant Ling、Baseten、NVIDIA、Vercel AI Gateway、Meta。四种协议均可自定义 HTTPS 端点；模型可手动添加，刷新目录保留手工记录。
- ChatGPT 账户只读取所选账户的公共 `/v1/models`，按 `visibility=list` 及服务器顺序提供型号，不补入 Pi 型号或 API 容量。其他预设从 models.dev 的精确供应商目录加载文本与图片模型；自定义连接尝试其 `/models`，无目录时可手动添加。这些公开清单表示服务模型资料，不授予账户调用权限。
- OpenCode 单个模型的 `provider.npm` 决定实际请求协议，每个会话发送 `x-opencode-session`。其他供应商默认协议由连接预设明确指定，不根据型号名称猜测。
- 用户决定移除 Kimi、Meta 和 xAI 的订阅／设备码登录。Kimi 国内／国际会员 API Key、Meta API Key 和 xAI API Key 保留；Kimi 连接页提供官方控制台引导，权益与适用工具范围以服务商说明为准。ChatGPT 账户使用官方 SIWC，旧 Codex 设备码与私有网关已删除，不迁移旧开发连接。
- OpenRouter 保留官方无回调 PKCE：浏览器完成授权后粘贴一次性代码，换取 API key；verifier 仅在内存中保留。ChatGPT 通过无痕 ASWebAuthenticationSession 与随机端口 loopback 完成授权，不提供设备码。
- 请求参数已区分 OpenRouter/Ant Ling 的 `reasoning.effort`、Together 的 `reasoning.enabled`、智谱/DeepSeek/Moonshot/Xiaomi 的 `thinking`、Alibaba 的 `enable_thinking`；Moonshot K3 使用其 effort 参数。仍复用 SDK 编码、流解析和工具循环。目录保留预算类型及上下限：Anthropic 区分预算与 adaptive，Kimi 使用其 adaptive 接口；Gemini 区分 budget 与 level；Baseten 使用目录声明的 toggle/effort，OpenCode 保留已知型号协议修正。未选择可调控制时保持服务默认值，不新增预算编辑器。OpenRouter/Baseten 使用稳定的会话标识；工具推理字段回放复用 SDK。
- 当前范围：完善现有供应商，不再新增边缘服务。SIWC 按下文官方边界实现；Radius、Azure/Bedrock/Vertex/Cloudflare、TypeSafe 不纳入本轮；不为 Mistral 新增 Conversations 协议。Anthropic 保留 API key，不复制官方客户端身份。以下 Pi 清单只作对照，不是开发待办。
- Qwen Individual 与现有 Alibaba 国际 Token Plan 共用端点与 key，Pi 的区别是更窄的模型清单；当前没有新增一个重复登录入口，也没有把公共目录当作套餐授权范围。不单独建设 Individual 配置。

原生工具已接入 ChatGPT 账户的允许搜索、OpenAI API 搜索与生图、xAI API Key 搜索与 Images、Google grounding/Imagen/Gemini 图片输出。具体通道、默认用途和限制见[原生工具](../ai/native-tools.md)。本轮协议回归使用合成认证，未新增真实账户证据，不能把适配器实现当作所有账号的能力验收。

### 授权实现与未完成边界

| 路径 | 当前状态 | 尚需工作 |
| --- | --- | --- |
| Kimi、Meta、xAI | 仅 API Key；Kimi 会员控制台引导 | 会员权益与调用范围按服务商规则，API Key 不代表所有场景获得许可 |
| OpenRouter | 已接入官方 headless PKCE，10 分钟一次性授权码 | 真实浏览器授权与推理 |
| Anthropic 订阅 | 不使用伪装官方客户端的登录 | 官方面向第三方应用建议 API key；不列为可以直接复制的 OAuth 待办 |
| ChatGPT SIWC | 官方动态注册、loopback、OIDC 校验与公共 Responses 已接入 | 模拟器使用合成凭据验证；真实用户登录、账户目录与套餐推理待用户真机验收 |
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
- **容量与能力：**账户目录未给容量时，仅允许对其中现有的精确 slug 编辑“上下文预算”，说明由用户按服务资料填写，并非服务端上限。刷新保留手填值；目录后来提供容量时以目录为准并提示；隐藏／移除型号不因手填值复活，不能手输额外型号。思考档位仅消费账户明确返回的有效字段，不补 API 档位或容量。
- **预览约束：**system 历史改用 instructions／developer；删除不支持的参数；函数工具使用 namespace 或 additional_tools。按账户允许的 web search 可用；图片输入须有模型能力证据，账户目录未明确提供时保持未知并禁用附件，不借公共 API 元数据推断权限。图片生成在用途选择和请求边界都禁止；API Key 通道保持原有能力。见[官方预览限制](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)。

### iOS 模拟器可行性证据

同一现有 iPhone 18 Pro／iOS 27 模拟器，DEBUG 临时入口分别启动 ASWebAuthenticationSession（未注册 HTTP scheme）和 SFSafariViewController，访问应用内仅绑定 `127.0.0.1` 的临时 listener，经 302 返回固定 `/auth/callback`，校验随机 state 与合成 code 后关闭浏览器。一个 UI 用例覆盖两种浏览器并通过，`build/ChatGPTSIWC/loopback-probe-retry.log` 为 TEST SUCCEEDED，截图 `screens/siwc-received-{asweb,safari}.png`。探针只使用合成 code，没有 OpenAI 请求、账户登录、token 或 Keychain 读写；已恢复临时源码，补丁仅留在忽略的 `build/ChatGPTSIWC/loopback-probe.patch`。

这证明模拟器内的浏览器→loopback 通路，不等于官方授权成功，也不覆盖真机行为。正式实现使用 `ASWebAuthenticationSession`，每次在 start 前设置 `prefersEphemeralWebBrowserSession=true`，不复用浏览器的 Google／OpenAI cookie，使每次都能重新选择账户。展示锚点取登录页当前窗口；使用不会被授权流程触发的 `moonread-auth-session-unused` 自定义 scheme 保持会话，独立 listener 接收 HTTP 回调。loopback 校验通过后由应用主动取消浏览器会话并在应用内继续换 token；用户关闭窗口则结束尝试并显示“已取消登录”。删除 SFSafariViewController 的生产路径，避免独立持久 cookie 使多 Google 账户无法切换。OpenRouter 也使用同一无痕浏览器，但其无回调 PKCE 仍需关闭浏览器后粘贴代码，关闭仅收起窗口，应用内“取消登录”才结束该次尝试；不伪造为 custom-scheme 或 HTTPS 回调。Apple 的[浏览器会话](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)、[本地端点绑定](https://developer.apple.com/documentation/network/nwparameters/requiredlocalendpoint)、[本地网络隐私](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)提供平台依据；模拟器不能代替真机本地网络隐私验收。最终仍需用户在真机亲自登录一次，并确认注册、验签、模型目录、Responses 与刷新行为。

## Pi 的实际范围

`packages/ai/src/providers/all.ts:builtinProviders` 注册 42 个入口（地域/套餐分别计数，不等于 42 套协议）：

| 类别 | 注册入口 |
| --- | --- |
| 主要模型 | OpenAI、OpenAI Codex、Anthropic、Google、Mistral、xAI、DeepSeek、Ant Ling、Meta |
| 地域/国内模型 | Moonshot AI / CN、MiniMax / CN、ZAI / ZAI Coding CN、Xiaomi |
| 编程/Token 套餐 | Kimi Coding、OpenCode Go、Qwen Token Plan / CN / Individual、Xiaomi Token Plan AMS / CN / SGP |
| 网关与推理平台 | OpenRouter、OpenCode Zen、Vercel AI Gateway、Groq、Cerebras、Together、Baseten、Hugging Face、NVIDIA、Radius |
| 云基础设施与专用模型 | Amazon Bedrock、Azure OpenAI Responses、Google Vertex、Cloudflare AI Gateway、Cloudflare Workers AI、Fireworks、TypeSafe |

此表按注册入口归组，类别不表示产品权限。另支持自定义协议/provider，OpenAI 兼容路径可接 Ollama、vLLM、LM Studio 等。

`KnownApi` 包含 OpenAI Completions、Responses、Codex Responses、Azure Responses、Anthropic Messages、Gemini、Vertex、Bedrock Converse、Mistral Conversations、pi-messages。多数入口共享前几套协议，并附加推理字段、工具 ID、缓存与消息回放差异。

### 认证

Pi 的 OAuth 源码只作技术对照，不代表月读支持其登录方式或拥有对应订阅许可。月读当前认证方式为 API Key、官方 ChatGPT SIWC 和 OpenRouter PKCE。

### 能力

- 模型目录包括 contextWindow、maxTokens、输入类型、成本、思考档位映射、缓存元数据及兼容参数。
- 模型请求支持流式文本/推理/工具事件、usage、取消；跨供应商历史转换另有实现。
- 独立 Images API 内置注册是 `openrouter-images`，不能把 Pi 对话 provider 全部标为支持独立生图；OpenRouter 目录同时包含 chat/image/classifier。
- 生图、图片输入、参考图编辑是不同能力；应用按连接的模型和认证权限组合判断。
- 压缩和 steering/follow-up 属于上层会话/agent，不是所有 provider 自动提供。

## 历史调研与现有接入边界

用户已确认收敛范围：保留现有入口并做好适配，不要求完整复制 Pi。下表记录协议选择背景；涉及新增供应商的内容不构成开发要求。

| 目标 | Swift SDK 现状 | 月读需要补充 |
| --- | --- | --- |
| OpenAI API、Anthropic API、Gemini、xAI、DeepSeek、Mistral | 有专用模块 | 模型目录、思考档位、能力验证及历史转换 |
| Moonshot/Kimi 国内国际、阿里通义普通 API | MoonshotAI / Alibaba 模块 | 地域地址、可用模型、兼容细节；不把 Coding/Token 套餐与通用 API 混用 |
| 智谱 BigModel 国内、Z.ai 国际、MiniMax 国内国际、Xiaomi 普通 API | 可复用 OpenAICompatible；无对应独立模块的地方需适配 | 各自默认地址、推理参数与工具回放验证；Pi zai 默认是 coding 地址，不能直接照抄 |
| OpenRouter、OpenCode Zen、Together、Groq、Fireworks、Cerebras、DeepInfra、Hugging Face | 一部分有模块，一部分走兼容/专用适配 | 网关路由、实际模型能力与认证，不把同名模型能力直接继承 |
| 自定义 OpenAI Compatible / Responses / Anthropic / Gemini 地址 | 相关模块的配置/自定义 provider 为复用基础 | 自定义连接、模型 ID、容量/能力覆盖；分别验证每类协议 |
| ChatGPT 账户 | SDK Responses 编解码，应用补官方 SIWC 身份层与流协议适配 | 模拟器合成回调／签名／工具回放；真实授权与目录待用户验收，不使用历史 Codex 证据代替 |
| 已有 OAuth 与 Coding/Token 套餐 | 不能由 API 模块推导订阅支持 | 保持现有入口，验证实际使用的账户与服务；不继续扩展 Pi OAuth 清单 |
| 生图/编辑 | SDK 已有 OpenAI、Google、Fal、Replicate、BlackForestLabs 等相关实现 | 模型与连接级能力、参考图编辑、附件结果；不把整个模块一概标为支持编辑 |
| Azure / Bedrock / Vertex / Cloudflare 等 | 部分有专用模块 | 不纳入当前范围，不新增企业 IAM 设置中心 |

不额外复制 Pi 的分类器、任意 shell、代码工具、会话分支、音视频/视频生成等与已确认小说场景无关的能力。SDK 有功能不产生产品范围。

## 建议的公共模型与认证数据

- Connection：供应商、区域/服务类型、baseURL、认证方式及安全凭证引用。认证方式（API key / OAuth / 设备码）与额度来源（按量 / 套餐 / 混合 / 未知）独立，不能把 API key 与订阅做成互斥选项；允许保存多个连接。
- Model：connectionID + modelID；文本/图片输入、文本/图片输出、图片编辑、工具、结构化输出、原生联网、思考可选项、上下文/输出上限；标记元数据来源与更新时间。
- Defaults：默认对话、搜索、生图模型；多能力模型可承担多个用途，不复制账号。搜索/生图按连接认证通道及适配器能力过滤，具体交付见[原生工具契约](../ai/native-tools.md)。
- Request settings：对话所选模型/思考强度与单次任务覆盖；已发请求固定参数，新请求应用新设置，实际使用值写入消息记录。
- Auth resolver：请求前取得有效凭证；同一连接协调刷新，失效提示登录，不能自动换到付费 API key。
- 目录能力与已实测能力区分：不存在“兼容 OpenAI 所以什么都支持”的推断。模型账户列表缺少容量时用已知目录/用户覆盖补足，不杜撰。

## SDK 取舍

保留 Swift SDK 的 API 适配与工具循环，应用补齐认证、模型目录及会话控制。ChatGPT 采用应用身份层与公开 fetch 扩展，不重写整套 SDK。后续仅在具体协议出现实际缺口时补适配，不提前增加替代框架。

已通过两库联合 iOS 构建与模拟器运行、网络取消及工具接口测试；本账户 Codex 设备码登录、刷新、真实工具循环、生图与参考图编辑通过。详情见 [接入证据](ai-feasibility.md)。其他协议及连接在实现对应功能时检查，不能从一个端点通过推断全部支持，也不阻塞先行开发。

依据：本地 Pi README、providers/all.ts、auth/oauth/load.ts、types.ts、providers/images/register-builtins.ts；Swift SDK Package.swift 与各 provider 实现。外部入口：[Swift SDK](https://github.com/teunlao/swift-ai-sdk)、[OpenCode Go 使用范围](https://opencode.ai/docs/go/#where-can-i-use-it)。

## Pi 认证与套餐对照（非当前接入清单）

套餐仅保留已核对的 API Key 预设；Pi 的历史登录实现不构成月读的支持目标。ChatGPT 按官方 SIWC 边界接入，真实服务与套餐使用范围仍分别验收。

| 服务 | Pi 的接入方式 | 月读评估结论/证据边界 |
| --- | --- | --- |
| OpenAI ChatGPT | OAuth 与 API key，共用公开 Responses | 分别验证订阅请求 profile 和普通 API，不混淆额度 |
| OpenAI Codex | 独立 OAuth（含设备码）及 backend transport | 本账户聊天工具循环、生图、参考图编辑实测通过；不推广为所有账户权限，也不用公开 SIWC 的限制概括 Codex |
| Anthropic | API key / bearer / OAuth | Pi 有登录刷新，不等于月读获得 Claude 订阅第三方使用资格；月读只接 API key，不伪装官方客户端 |
| Kimi Coding | 仅会员 API Key，国内 Chat／国际 Anthropic 兼容 | 订阅与 Moonshot 按量 API 分开；官方 FAQ 明确不同入口与计费；适用工具限制单独检查 |
| OpenRouter | API key 或 OAuth 换 API key | 已实现 PKCE 换 key；登录不代表订阅，真实账户未验收 |
| Radius | API key 或设备码 OAuth，动态网关 | 登录与网关计费分开，Pi 未统一标为订阅 |
| MiniMax Token Plan（国内/国际分配置） | Pi MiniMax provider 接收 key，Anthropic 协议 | 官方现有 Subscription Key 与按量 key 不互通；套餐/购买 Credits 可共用此 key；不是只针对编程的功能清单，FAQ 包含聊天、翻译等场景 |
| 阿里 Qwen/Model Studio Token Plan | 专用 key 与地域/套餐 endpoint | 官方新 Token Plan 与旧 Coding Plan 分开；当前 Token Plan 文档支持自定义 URL/key 工具和多模态，不套用旧 Coding Plan 的限制 |
| 小米 MiMo Token Plan | key；CN/AMS/SGP 不同入口 | 与普通按量地址区分，套餐 key 和地区需匹配 |
| 智谱/Z.ai Coding Plan | key，国内/国际专用地址 | 订阅 key 技术上可走兼容协议，既有官方 Coding 场景限制仍需遵守；普通 API 另设预设 |
| OpenCode Go | key，按模型走多种协议并携带会话信息 | 套餐 API，当前官方面向编程 agent；不由是否使用 key 推断能用于小说场景 |

### 对 SDK 的影响

API key 套餐通常可复用现有协议模块，新增的是服务预设、正确端点/模型、套餐说明及必要差异，不能因为是订阅就一律开发 OAuth。OAuth/设备码需要月读身份层；请求侧能复用 bearer 注入的保留 SDK，特殊 token 交换/请求格式用独立适配。月读不再接入 xAI、Kimi 或 Meta 的设备码。

默认不自动切换用户选择的连接/计费路径。也不能承诺“套餐额度耗尽绝不扣余额”：MiniMax 官方说明同一 Subscription Key 在有购买 Credits 时可能自动抵扣，属于服务端规则，需要准确展示已知套餐行为。

证据：Pi `auth/oauth/{anthropic,openrouter,radius}.ts` 与相关 provider；[MiniMax FAQ](https://platform.minimax.io/docs/token-plan/faq)、[阿里 Token Plan](https://www.alibabacloud.com/help/en/model-studio/token-plan-overview)、[Kimi FAQ](https://www.kimi.com/code/docs/en/kimi-code/faq.html)、[小米 Token Plan](https://mimo.mi.com/docs/en-US/tokenplan/Token%20Plan/subscription)。官方未确认的项保持未知，不以社区实现冒充供应商正式支持。

## 请求契约复核（2026-10-04）

完整模块范围、修复项目、逐通道依据和证据边界统一见 [AI 实现核对](ai-implementation-audit.md)。认证/目录、普通推理、缓存/回放、Agent、读取工具、原生搜索/图片、持久化和 UI 均在核对范围内，不用一个账户请求代表其他供应商。
