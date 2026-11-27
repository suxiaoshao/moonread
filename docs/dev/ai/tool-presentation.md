# 工具调用展示与图标映射

2026-10-04：正式工具消息 UI 已接入。使用 SF Symbols，与月读原生界面及主题一致；部署下限保持 iOS 18，最低系统实际运行仍单独验收。每个已注册工具有显式映射，不要求每个工具创造独有图标。

## 本地参考

- Zed `c770f3b182`：`crates/agent_ui/src/conversation_view/thread_view.rs` 的工具标题按 ACP ToolKind 选图标；Read/Search 共用 ToolSearch，Edit 用 ToolPencil，Fetch 用 ToolWeb，其他工具有兜底。文件与子代理有特定呈现，失败装饰独立于工具类型。
- Gupi `04a5d6f`：`crates/gupi-conversation/src/tool_presentation.rs` 集中分类 Read/Skill/Write/Edit/Shell/Search/List/Other，并映射 FileText/BookOpen/FilePlus/FilePenLine/Terminal/Search/Folder/Wrench。消息触发入口与历史列表共享该分类；同一个 read 可按参数识别为 Skill。
- 借鉴统一映射与状态分离；不引入月读用不到的终端、代码编辑或子代理分类，也不复制桌面图标资源。

## 基础读取工具

| 分类 | 工具 | 用户动作名称 | 建议 SF Symbol | 摘要对象 |
| --- | --- | --- | --- | --- |
| 书库与资料 | ls | 浏览书架 | folder | 书架/文件夹名 |
| 搜索 | search_books | 查找书籍 | magnifyingglass | 查询词/筛选条件 |
| 书库与资料 | get_book | 查看书籍资料 | book.closed | 书名 |
| 搜索 | list_filter_options | 查找筛选选项 | magnifyingglass | 候选字段与查询词 |
| 搜索 | query_books_by_filter | 按条件查找小说 | line.3.horizontal.decrease.circle | 条件、总命中数与资料不足数 |
| 书库与资料 | show_book_list | 展示书单 | books.vertical | 书名或实际本数与首项 |
| 正文与目录 | get_chapters | 查看目录 | list.bullet | 书名 |
| 正文与目录 | read | 阅读正文 | book | 书名与章节 |
| 搜索 | rg | 搜索正文 | doc.text.magnifyingglass | 查询词；书籍数量 |
| 书签与批注 | get_marks | 查看书签与批注 | bookmark / highlighter / list.bullet.rectangle | kind=bookmark / annotation / all |
| 书签与批注 | get_mark | 查看批注 | highlighter | 已知书名与摘录；解析结果为书签时改 bookmark，并改标题为查看书签 |
| 阅读统计 | get_reading_statistics | 查看阅读统计 | chart.bar | 时间范围；可选书名 |
| 环境信息 | get_environment | 获取时间与语言 | globe | fields仅time用clock；仅locale用globe；两者或缺省用globe |

分6类用于统一展示规则，无需在聊天里再显示一排分类标签。图标由工具注册表及已校验参数/结果决定；不让模型指定 SF Symbol，不根据模型返回文案猜类别。未知工具兜底 `wrench.and.screwdriver`，展示安全工具名称，不能让空图标导致调用不可见。

## 已接入的原生与业务提案工具

| 工具 | 动作名称 | 建议 SF Symbol |
| --- | --- | --- |
| web_search | 搜索网页 | globe |
| find_cover | 查找封面 | photo.on.rectangle.angled |
| generate_image | 生成图片 | photo.badge.plus |
| propose_book_metadata | 资料建议 | text.badge.checkmark |
| propose_book_filter | 建议书架筛选 | line.3.horizontal.decrease.circle |
| propose_note | 建议添加/编辑批注 | highlighter |
| propose_bookmark | 建议添加书签 | bookmark |
| propose_cover | 建议替换封面 | photo |
| propose_library_organization | 建议整理书架 | folder.badge.gearshape |

只在对应工具实际注册后显示。propose_* 完成表示“方案已生成”，不显示“已修改/已移动”；用户确认应用的结果单独表示。删除、覆盖、终端执行不在现有工具范围。

## 调用行与执行状态

过程行显示工具标题与调用摘要。请求和已保存的结果可在详情中查看；成功且已有对应回复结果卡或图片时，由回复中的入口负责打开。过程分组、运行状态、稳定身份及详情导航见[每轮回复的展示](rendering.md#每轮回复的展示)。

正文准备是工具内部阶段：资料查询仍归 get_book，等待下载可在状态位置显示 arrow.down.circle，不伪造额外模型工具调用。压缩是运行器活动，用 archivebox；推理是模型事件，用 sparkles，仅有真实推理事件时显示；它们不计入基础读取工具。

## 接入位置

应用侧集中定义工具展示描述（category、title、symbol、参数摘要、结果摘要），由 toolName 与已验证输入/结果解析；与模型的 schema/执行实现共享稳定 toolName。不要在月亮、消息、详情中分别维护 switch。能力不存在时不造示例调用。状态来自 AIAgentActivity、持久工具调用和业务结果，UI不推测成功。
