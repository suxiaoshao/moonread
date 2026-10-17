# 工具调用展示与图标映射

2026-10-04：正式工具消息 UI 已接入。使用 SF Symbols，与月读原生界面及主题一致；部署下限保持 iOS 18，最低系统实际运行仍单独验收。每个已注册工具有显式映射，不要求每个工具创造独有图标。

## 本地参考

- Zed `c770f3b182`：`crates/agent_ui/src/conversation_view/thread_view.rs` 的工具标题按 ACP ToolKind 选图标；Read/Search 共用 ToolSearch，Edit 用 ToolPencil，Fetch 用 ToolWeb，其他工具有兜底。文件与子代理有特定呈现，失败装饰独立于工具类型。
- Gupi `04a5d6f`：`crates/gupi-conversation/src/tool_presentation.rs` 集中分类 Read/Skill/Write/Edit/Shell/Search/List/Other，并映射 FileText/BookOpen/FilePlus/FilePenLine/Terminal/Search/Folder/Wrench。消息触发入口与历史列表共享该分类；同一个 read 可按参数识别为 Skill。
- 借鉴统一映射与状态分离；不引入月读用不到的终端、代码编辑或子代理分类，也不复制桌面图标资源。

## 当前10个工具

| 分类 | 工具 | 用户动作名称 | 建议 SF Symbol | 摘要对象 |
| --- | --- | --- | --- | --- |
| 书库与资料 | ls | 浏览书架 | folder | 书架/文件夹名 |
| 搜索 | search_books | 查找书籍 | magnifyingglass | 查询词/筛选条件 |
| 书库与资料 | get_book | 查看书籍资料 | book.closed | 书名 |
| 正文与目录 | get_chapters | 查看目录 | list.bullet | 书名 |
| 正文与目录 | read | 阅读正文 | book | 书名与章节 |
| 搜索 | rg | 搜索正文 | doc.text.magnifyingglass | 查询词；书籍数量 |
| 书签与批注 | get_marks | 查看书签与批注 | bookmark / highlighter / list.bullet.rectangle | kind=bookmark / annotation / all |
| 书签与批注 | get_mark | 查看批注 | highlighter | 已知书名与摘录；解析结果为书签时改 bookmark，并改标题为查看书签 |
| 阅读统计 | get_reading_statistics | 查看阅读统计 | chart.bar | 时间范围；可选书名 |
| 环境信息 | get_environment | 获取时间与语言 | globe | fields仅time用clock；仅locale用globe；两者或缺省用globe |

分6类用于统一展示规则，无需在聊天里再显示一排分类标签。图标由工具注册表及已校验参数/结果决定；不让模型指定 SF Symbol，不根据模型返回文案猜类别。未知工具兜底 `wrench.and.screwdriver`，展示安全工具名称，不能让空图标导致调用不可见。

## 后续已规划工具

| 工具 | 动作名称 | 建议 SF Symbol |
| --- | --- | --- |
| web_search | 搜索网页 | globe |
| find_cover | 查找封面 | photo.on.rectangle |
| generate_image | 生成图片 | photo.badge.plus |
| propose_book_metadata | 建议更新资料 | square.and.pencil |
| propose_note | 建议添加/编辑批注 | highlighter |
| propose_bookmark | 建议添加书签 | bookmark |
| propose_cover | 建议替换封面 | photo |
| propose_library_organization | 建议整理书架 | folder.badge.gearshape |

只在对应工具实际注册后显示。propose_* 完成表示“方案已生成”，不显示“已修改/已移动”；用户确认应用的结果单独表示。删除、覆盖、终端执行不在现有工具范围。

## 调用行与执行状态

一行内容：左侧语义图标，中间“动作 + 对象”，右侧状态/展开入口。默认收起；点开看简洁参数与结果，原始 JSON 不作为默认正文。状态独立：

- 排队：静态等待提示。
- 执行中：保留语义图标，另显示小型进度指示，不让书/文件夹持续旋转。
- 等待确认：静态问号标记，展开提供确认/拒绝；不等同于模型思考。
- 成功：保留原图标，能展示结果数量时显示数量，无需每条永久绿色勾。
- 部分结果：明确显示“部分结果”，不标为失败，也不写成检索全书。
- 失败：感叹号与简短错误，使用主题危险色；原工具语义仍可识别。
- 停止/拒绝：分别显示“已停止”及具体动作状态（例如“未准备”），使用次要色，不算执行故障。

每轮运行时展开一层过程，当前页完成时保持展开，重开时已完成轮次折叠为“查看过程”；最终回复身份保持，手动展开可看历史活动。稳定行与跟随规则见[消息呈现](rendering.md)。连续推理/工具按两段回复之间分组折叠，工具参数与结果在详情 sheet 展示。请求失败与正文准备确认的布局、动作及实现边界见[对话错误与单次操作确认](errors-and-confirmation.md)。

同一 callID 的开始、进度、结果更新同一调用条目，不产生三条重复消息。重复调用保留独立身份；连续活动按回复边界聚合展示，组身份取首条活动 ID，不随新增事件或文本增量改变。图标/动作命名在调用行、展开详情和任务活动栏复用；月亮只投影本次开书所选对话；多个并行工具时按固定优先级显示一个工具族姿态（见[阅读月亮入口](../design/ai.md#阅读月亮入口)），数量由无障碍活动标题（“正在执行 N 项操作”）读出，不以最后到达的事件反复闪换图标。

正文准备是工具内部阶段：资料查询仍归 get_book，等待下载可在状态位置显示 arrow.down.circle，不伪造额外模型工具调用。压缩是运行器活动，用 archivebox；推理是模型事件，用 sparkles，仅有真实推理事件时显示；它们不计入10个业务工具。

## 接入位置

应用侧集中定义工具展示描述（category、title、symbol、参数摘要、结果摘要），由 toolName 与已验证输入/结果解析；与模型的 schema/执行实现共享稳定 toolName。不要在月亮、消息、详情中分别维护 switch。能力不存在时不造示例调用。状态来自 AIAgentActivity、持久工具调用和业务结果，UI不推测成功。
