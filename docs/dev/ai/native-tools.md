# 原生搜索与图片生成

当前接口、工具及默认用途契约。产品入口见[AI 设计](../design/ai.md)，实际服务与协议测试证据见[验证记录](../engineering/verification.md)。

## 默认用途与选择

AI 设置的“默认使用”分组提供“对话”“联网搜索”和“图片生成”。工具用途进入后先选已配置的服务连接，再选该通道可用的执行模型或图片模型。同一服务的多个账户分别列出；连接资格不依赖目录是否已经加载。仅列出实际实现的 OpenAI API、ChatGPT、xAI、Google 官方通道，兼容地址不继承资格。退出不保存，完成时重新校验并保存；选择“不使用”清空该用途。

- 对话：沿用连接、模型与有效思考配置。
- 搜索：保存连接与执行原生搜索的模型；不另加摘要模型设置。
- 生图：保存连接、模型及适配器确定的执行方式（直接图片接口或模型原生生图工具）。ChatGPT 账户不进入图片生成用途选择器，也不能发 image_generation 请求。
- 未设置时显示“未设置”；不默认使用任何连接，不静默挑选另一个账户。现有对话模型切换不修改搜索、生图默认值。
- 每次工具开始时固定此次执行配置；设置变化只影响之后的调用。移除连接清空对应默认项，并取消使用该连接的请求。
- 能力由连接、认证通道、模型及适配器共同决定。models.dev 的 tool_call、图片输入/输出不能代替原生搜索或编辑能力；自定义兼容地址不自动继承官方端点能力。

## Providers 接口

Swift 层提供独立于页面的 AIWebSearchInput、AIGenerateImageInput 与 AINativeResult；执行上下文传入任务标识、已解析配置及取消信号。认证仍使用月读自己的连接服务与 Keychain。

| 接口 | 输入 | 结果 |
| --- | --- | --- |
| 搜索 | query、可选 language，选定连接/模型 | answer、sources（title/url、可选 excerpt）、实际连接/模型、可用 usage |
| 生图/编辑 | prompt、可选 referenceAttachmentRefs，选定连接/模型 | 图片附件引用、实际尺寸/格式、执行连接/模型；后端明确返回时才记录实际绘图模型 |

搜索结果允许有供应商生成的回答，不能统一伪装成网页原文或原始搜索排名。引用从真实返回中解析，不由应用编造。先提供各通道都能兑现的最小参数，不暴露不能保证执行的域名过滤、结果数量或分页参数。

图片使用应用附件存储，工具结果引用资源，不将 base64 同时复制到工具 JSON 和多个内存状态中。参考图必须解析为本任务可访问的图片；适配器不支持编辑时明确返回 unsupported，不忽略参考图重新生成。原图完成下载后以 ImageIO 解码判断可用性，按实际 MIME 和尺寸保存；没有通用后缀、MIME 或字节数拒绝门槛。find_cover 的尺寸筛选单独适用。图片未完成首次引用的原子持久保存不得报告成功。

### 适配边界

当前覆盖 OpenAI API、ChatGPT 账户、xAI API Key 和 Google 的已适配路径。其他已有供应商仅在适配完成后进入用途选择器；不因普通聊天已支持就显示搜索/生图可用，也不新增供应商。

- OpenAI API：复用 SDK 原生搜索工具与图片生成/编辑能力。
- ChatGPT：官方 SIWC token 只调用公共 Responses，每次 `store=false/stream=true`；允许搜索仍受型号及账户策略约束，不提供图片生成。旧 Codex backend 通道已删除；真实账户验收与合成协议证据分别记录。
- xAI API：Responses web_search，Images generations/edits；单参考图使用 image，多图使用 images 与 aspect_ratio。
- Google：SDK googleSearch grounding、Imagen 图片接口及 Gemini 文本/图片内容接口；参考图按模型输入能力校验。

未通过的路径是明确交付限制，不能把合成协议测试写成真实订阅可用。也不为此追加无关供应商或重新验收所有聊天适配。

## Agent 工具

采用 SDK TypedTool 的输入/输出、校验与现有工具循环。

| 工具 | 模型输入 | 输出 |
| --- | --- | --- |
| web_search | query:string（非空），language?:BCP47 | answer、sources:{sourceRef,title,url,excerpt?}；遵循现有结果预算，截断时明确标记 |
| generate_image | prompt:string（非空），referenceAttachmentRefs?:string[]（数量按目标服务协议校验） | attachments:{attachmentRef,mimeType,width,height}；返回实际执行来源 |

连接、模型、凭证和执行方式不由模型在参数中指定，由用户默认配置与任务覆盖解析。未配置对应用途时不注册工具；运行期间配置失效按现有工具错误返回，不能静默换供应商或计费方式。

主 Agent 调用搜索后取得答案与来源，继续使用当前对话模型回答；调用生图后取得图片附件。独立执行器只处理该工具所需输入，不默认转发整段聊天历史，也不开放递归调用自身的工具集。

不实现独立 read_web 或通用网页抓取器。find_cover 可在应用本地从搜索来源页面提取一层显式声明图片，获取授权、上限与筛选见[工具契约](tools.md)。供应商原生搜索内部浏览由供应商负责；需要追问来源时可继续搜索，不承诺返回任意网页完整正文。find_cover/propose_cover 已接入业务提案，图片搜索结果仍须经过候选预览和用户应用，不能直接写入封面。

## 执行与现有 UI 的最小闭环

- 搜索、生图纳入当前工具分组，显示真实加载、完成、失败与取消状态；不在最终回复下面重复一份工具日志。
- 来源链接可打开；生成图片使用附件展示/预览，让用户能看到实际结果。封面任务的预览、应用和受能力约束的参考图修改复用这些图片资源。
- 关闭对话页不取消；显式停止必须传到正在执行的网络请求和图片获取。只有任务所有者持有执行状态。
- 失败沿用现有短错误与用户发送“继续”的方式，不增加自动重试、备用供应商、付费降级或恢复中心。
- 工具结果和来源随正式消息保存；历史重新打开能读出附件，删除历史按现有资源所有权清理附件，不影响已应用的用户封面。


## 调研依据

2026-10-04 阅读本机 Pi 扩展源码，未读取其凭证，也未进行真实服务调用：

- pi-web-access：gemini-search.ts 的 SearchRoutingConfig、xai-search.ts 的独立模型与原生 web_search 请求。借鉴独立用途配置，不照搬多级 fallback、Cookie、抓取及摘要模型设置。
- pi-codex-image-gen：extensions/index.ts 的 model 为 routing model，请求 tools:image_generation；真实绘图模型由后端决定。
- pi-xai-oauth：extensions/xai/tools/custom-tools.ts 的 xai_generate_image 单独选择图片模型并按认证解析 route。插件实现不等于本机账户权限已经验证。
- [OpenAI 生图工具](https://developers.openai.com/api/docs/guides/tools-image-generation)、[xAI 生图工具](https://docs.x.ai/developers/tools/image-generation)。官方 API 资料与订阅 backend 分别核对。

既有服务证据见 [接入调研](../research/ai-integration-history.md)，产品长期规则见 [AI 产品设计](../design/ai.md)。
