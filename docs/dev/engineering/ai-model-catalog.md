# AI 模型目录与能力卡片

2026-10-04：目录服务、能力卡片及缓存已接入。本页区分本地 Pi 的源码事实与月读采用的策略。

## 页面与数据契约

保留模型详情的身份区、能力分组卡片、思考滑杆、容量卡片及使用按钮。能力分组为三列两行，图标在文字上方，固定顺序如下。支持的使用主题色，其余置灰，不增加“未知”状态或开发进度说明。

| 位置 | 卡片 | models.dev 判定 |
| --- | --- | --- |
| 第一行左 | 文字对话 | `modalities.input` 与 `output` 均包含 `text` |
| 第一行中 | 图片输入 | `modalities.input` 包含 `image` |
| 第一行右 | 深度思考 | `reasoning == true` |
| 第二行左 | 图片生成 | `modalities.output` 包含 `image` |
| 第二行中 | 工具调用 | `tool_call == true` |
| 第二行右 | 结构化输出 | `structured_output == true` |

字段未明确支持时不启用。`structured_output` 是可选字段；缺省也置灰，不把缺省写成已证实的供应商限制。音频、视频、温度、流式回复不放入能力概览。联网搜索与图片编辑由相应服务适配器判断，不能从工具调用或图片输入输出推导，不在这六张卡片中混入。

思考开关不等于具体档位：档位来自连接目录或适配器的明确配置，不能从 `reasoning` 推导六档。多档显示离散滑杆，单档仅显示，无思考能力隐藏调节区。容量显示当前连接上下文与最大输出，缺少数值不编造，也不把 SDK 的安全默认值作为规格。不设“模型资料”展开区。模型 ID 与展示名不同时，放在名称下方并提供复制；相同时省略。资料来源、更新时间保留在内部数据中。连接限制直接反映在相关能力和容量上。有经过核实的官方模型链接时，在页面底部提供轻量文字入口；无链接则省略，不生成猜测 URL。

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

## 月读采用的获取方案

### 目录来源分工

1. **公开能力目录**：以 [models.dev API](https://models.dev/api.json) 为准，整理六项能力、容量及技术资料。应用附带一份构建时生成的目录，后台获取新快照。无需自建目录后端。
2. **账户目录**：ChatGPT 只读取所选账户公共 `/v1/models` 的 `visibility=list` 条目，保留服务器顺序、按 slug 请求，不补入额外型号；其余内置预设按精确供应商读取公开目录，自定义服务尝试 `/models` 并允许手工添加。公开目录不授予账户访问资格。

资料匹配键为供应商和精确模型 ID。当前 API 模型的思考控制读取 `reasoning_options` 的 effort、toggle 与 budget_tokens；只有请求适配器能够正确转换的控制才进入选择器，容量读取 `limit.context/output`；不追加 SDK 或其他连接中的档位。Astra 在当前 models.dev 快照中为 low/medium/high/xhigh/max，无 ultra。ChatGPT 不继承 API 容量和能力；缺少容量时仅编辑已返回型号的用户上下文预算，刷新保留，目录以后提供容量时改用目录值并提示。隐藏／移除型号不能由手填配置保留。未明确提供的思考档位不显示、不发送；图片输入未知时不开放附件，真实目录后再核对。兼容端点未声明目录映射时不跨供应商猜测。订阅与 API 的映射必须由适配器明确声明，不能按展示名或相近字符串跨供应商猜测。连接明确返回的能力覆盖公开资料。API 规格以 models.dev 为准；ChatGPT 参数以账户明确返回字段与用户预算为准。最终形成同一份模型快照，供选择器、详情页和请求校验消费，View 不维护型号特例。临时登录失效属于连接状态，不改写模型能力。

### 保存与刷新

| 内容 | 保存位置 | 刷新时机 |
| --- | --- | --- |
| 内置公开目录 | App 资源 | 随构建更新 |
| 下载的公开目录 | `Library/Caches` 的可重建 JSON | 首次使用 AI 时恢复；无缓存或距检查满 24 小时，后台更新；手动刷新可跳过间隔 |
| ChatGPT 账户目录 | 该连接持久化的模型快照及检查时间 | 登录后首次获取；距检查满 24 小时后台更新，手动刷新强制请求；以同一账户 token 读取公共 `/v1/models`，不共享其他账户目录 |
| 默认模型和思考选择 | 已有用户配置 | 用户明确保存时 |

24 小时是月读的刷新策略，不是 Pi 的数值。进入列表、详情或选择器只读取应用级目录服务的内存快照，不在每个 View 的出现回调下载。回到前台且使用 AI 时可检查是否过期，不设后台常驻轮询。并发刷新共用一个任务；不同账户的目录不共用。

手动添加模型必须填写正整数上下文容量；最大输出选填，填写时必须为正整数且不超过上下文。填写已有模型 ID 时更新其容量，不创建重复条目；保留模型名称和能力，刷新目录后继续使用手动填写的容量。最大输出留空时保留已有值。保存后参与与目录模型相同的请求容量校验。

手动刷新普通 API 连接时，先等待公开目录刷新完成，再把新目录应用到连接；刷新期间保持加载状态，不提前标记成功。ChatGPT 使用独立的账户目录通道，但同样先读快照并按 24 小时检查；设置、对话和回前台不会无条件请求 `/v1/models`。并发检查不重复启动请求；失败保留旧快照，本次使用不循环自动重试。未允许套餐使用的已登录账户不触发目录请求。

公开快照解析和校验通过后整体替换缓存；支持服务器返回的 ETag/Last-Modified 条件请求，不能假设服务必定提供。失败继续使用旧缓存或内置目录，本次使用不循环重试，用户可手动重试。账户目录失败也保留旧目录，实际调用仍按服务响应处理；退出或换账户不沿用前账户缓存。缓存不进 CloudKit，不含密钥，不修改用户已选模型。目录变化后若所选模型不可用，显示选择入口，让用户改选，不自动换模型发送。

## 验证范围

覆盖离线启动、缓存命中不重复下载、手动刷新、失败保留旧数据、账户隔离、六项字段映射及连接限制覆盖。页面以同一份示例数据验证三列两行、置灰与思考档位，不用真实供应商名称承载虚构规格。

资料：[models.dev](https://models.dev)、[最终模型 schema](https://github.com/anomalyco/models.dev/blob/dev/packages/core/src/schema.ts)。内置快照为当天 models.dev 数据的所需字段投影，位于 `ios/Moonread/AI/Providers/AIModelCatalog.json`；完整类型、解析与刷新在同目录 `AIModelCatalog.swift`。目录获取使用公开 API，不包含凭证。Codex 内置目录表示可选服务型号，不证明当前账户有权限；实际调用失败照常展示服务错误。官方模型链接无可靠数据源时省略。测试记录见 verification.md。

多协议预设在目录中额外保留模型名称和 `provider.npm`，后者仅用于 OpenCode 网关的单模型路由。区域及套餐使用各自目录键；不借用相近区域的数据。


### 请求适配保持简单

目录同时保存 `reasoning_options` 的类型、values、min/max，不只保留 effort 字符串。effort 使用服务声明值；toggle 显示开/关；只有预算控制时显示应用的 minimal/low/medium/high 四档。原始控制信息仍保留，未有明确请求映射的控制不生成假的 effort 参数。NVIDIA 的通用适配参照 Pi 不发送 reasoning_effort；它的模型思考能力与可调控制分别处理。请求层按协议转换：Anthropic 的预算模式使用 enabled/budget_tokens，自适应模式使用 adaptive/effort；Gemini 按目录区分 budget/level。预算模式需要把已选档位转成预算时，使用应用内部的 1024/2048/8192/16384 token 档位并服从目录上下限；这不是供应商宣称的档位规格。没有显式选择时不覆盖服务默认值。

Codex 使用上述内置清单。OpenCode 的 provider.npm 路由附带已核对的少量端点修正；修正集中于 Providers，不进入 View。复用 SDK 的工具消息转换；OpenRouter reasoning_details 通过 SDK metadataExtractor 保存并在原连接原模型回放，跨模型时剥离。OpenRouter/Baseten 追加稳定会话标识；OpenRouter 的 Anthropic 模型还写入缓存断点，直接 Anthropic 使用 SDK cacheControl。缓存不增加设置页。
