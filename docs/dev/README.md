# 开发文档

月读以舒服、连续的本地小说阅读为目标。本文是文档入口；产品方向见[项目 README](../../README.md)，工作规则见[AGENTS.md](../../AGENTS.md)。规划用于组织后续工作，具体实现范围由用户当轮请求决定。

## 从哪里开始

| 想了解什么 | 文档 |
| --- | --- |
| 现在数据存在哪里，多来源/复制导入遵循哪些规则 | [数据与来源](data/README.md) |
| iCloud 文件与 CloudKit 阅读数据怎样分工 | [同步设计](data/sync.md) |
| SwiftData 用户数据、冲突与 CloudKit 边界 | [同步设计](data/sync.md)、[验证记录](engineering/verification.md) |
| iCloud 本次接入步骤、签名限制与验收 | [iCloud 接入实施](data/icloud-implementation.md) |
| 首页与统一目录树怎样承载阅读及文件管理 | [首页与书架](design/library.md) |
| 小说信息与 tags 如何编辑、封面怎样存储，以及详情入口与章节百分比 | [小说详情与章节阅读百分比](design/book-details.md) |
| 多选、批量复制、同名替换怎样工作 | [书架操作](design/library.md#操作入口) |
| AI 的入口、上下文、工具范围与实施安排 | [AI 产品设计](design/ai.md)、[实施计划](plans/ai.md)、[接入调研](engineering/ai-feasibility.md)、[供应商范围](engineering/ai-providers.md)、[模型目录与缓存](engineering/ai-model-catalog.md)、[AI 内部分层](engineering/ai-architecture.md)、[完整 Agent 基础](ai/agent.md)、[工具契约](ai/tools.md)、[原生服务](ai/native-tools.md)、[封面获取](ai/cover-fetch.md)、[消息呈现](ai/rendering.md)、[AI 实现核对](engineering/ai-implementation-audit.md) |
| 接下来还缺什么、哪些尚待讨论 | [后续计划](roadmap.md)、[书架候选](roadmap.md#书架扩展候选) |
| 当前性能设计、开书关键路径和待优化项 | [性能设计](engineering/performance.md)、[性能待优化索引](roadmap.md#性能待优化) |
| 连续阅读、位置稳定和性能如何验证 | [验证方法](engineering/verification.md#验证方法) |
| 阅读控制怎样组织到弹层中 | [阅读弹层与工具布局](design/reader-panels.md) |
| 当前主题、设置页、动效与月亮的设计 | [主题与产品化入口](design/appearance.md) |
| Rust / Swift 如何分工，身份与位置怎样保存 | [架构与数据约定](engineering/architecture.md) |
| 如何构建、签名和交付试用 | [开发环境](engineering/development.md) |
| 小组件、灵动岛、快捷指令等系统集成规划 | [iOS 系统集成](design/ios-integration.md) |
| GitHub 设置、CI、模板与依赖更新 | [仓库与持续集成](engineering/repository.md) |
| 实际测过什么，哪些还不能声称完成 | [验证记录](engineering/verification.md) |
| 当前正文版面、翻页、工具和底部渐变 | [正文排版与阅读交互](reader/reading.md) |
| 开书为何能边处理边读，如何暂停/恢复/去重 | [渐进正文准备](reader/import.md) |
| 目录、书签、搜索、标注及私人批注 | [阅读工具](reader/tools.md) |
| 统计页面显示什么、静止/锁屏和章节覆盖怎样计算 | [阅读统计设计](design/statistics.md) |
| 统计按什么顺序开发、数据与验收有哪些依赖 | [阅读统计实施计划](plans/statistics.md) |

## 当前状态

基础 TXT 阅读主流程已实现。AI 对话、连接与模型管理、阅读工具、队列、压缩、消息分页和过程/确认/来源预览已接入；原生搜索与生图、资料/笔记/书签建议、封面、书架整理、统计分析及临时任务转入对话也已实现。当前遗留以真实服务和连续使用验收为主；对话列表分页和用户主动添加外部图片附件尚未实现，详见 [AI 当前进度与剩余工作](plans/ai.md)及[原生搜索与生图](ai/native-tools.md)。当前不以补齐参考应用全部扩展作为进入下一阶段的条件；真实云端、长时阅读和最低系统仍有验证缺口。

| 领域 | 当前实现 | 后续边界 |
| --- | --- | --- |
| 正文阅读 | TXT 渐进准备、就绪唤醒与慢准备反馈、单书读取、有限窗口滚动/分页、位置恢复、完整目录快照与预计算章字数、书签/单书搜索、统一批注菜单与交叉选区编辑合并 | 连续长时阅读与最低系统仍需验收 |
| 书架 | 本地首页快照与静默刷新、多目录、最近阅读（网格封面横排）、列表/网格（默认网格）、统一搜索 Tab 与作者/标签/书架筛选、下拉刷新、最近删除及失败时批次确认、小说详情和信息/封面编辑 | 最近删除单文件真机试用已反馈，接受范围与缺口见验证记录；拖动移动待实施；状态筛选、离线及笔记整理为候选 |
| 阅读统计 | 本地计时、统计 Tab、范围汇总/阅读节奏/书目/按日时段、单书图表/月历、章节估算覆盖、暂停/清理、AI 分析入口 | AI 分析结果仍需实际试用；统计自动同步已接入，真实云端待验收；真机长时验证仍需完成 |
| 数据与同步 | SwiftData 用户数据、Rust 正文及计算、固定 iCloud Documents 与自动 CloudKit | SHA 关联、单书投影与云交接调度已实现；真实双设备与账户/提供方覆盖见验证记录 |
| 平台 | Swift 原生 UI/排版和平台访问，Rust 正文/计算，SwiftData 用户存储；主要简中/英文资源 | Xcode 27 构建，部署下限 iOS 18；Android 尚未实现；AI 业务任务已接入，真实服务及最低系统验收仍有缺口 |

主题与产品化包括 App/阅读独立明暗和配色继承、三组浅深预设、自定义颜色、设置页、统一动效、原生加载与月亮角色。阅读设置平级展示排版、配色、阅读控制，配合原生 sheet 的三档阅读预览；书内底部共用面板展示进度、临时浏览、搜索与快捷设置。卷章纠错和跳转历史见阅读专题；阅读统计的[当前设计](design/statistics.md)及[后续分析计划](plans/statistics.md)分别维护。单书设置等暂缓边界集中于[后续计划](roadmap.md)。

“我的书架”使用应用固定的本地或 iCloud Documents 根，根入口不可移除；内部与用户添加的目录共用文件树及文件操作。最近阅读按正式阅读活动排序，首页最多 10 本（网格横排；列表显示 3 本）；首页查所有书架，目录内查所属书架及其子目录。导入按目标目录中的文件名提示替换。云端接入与实际验证分别记录，具体边界见[数据专题](data/README.md)。

Swift 源码按 `App`、`Library`、`Reader/{Session,UI,Rendering}`、`Books`、`Statistics`、`Settings`、`Data`、`Shared` 和既有 `AI` 组织，Xcode groups 对应真实目录。现有 owner 和共享 actor 关系保持；具体文件职责见[Swift 源码目录](engineering/architecture.md#swift-源码目录)。

## 目录职责

```text
docs/dev/
├── README.md  入口与状态摘要
├── roadmap.md  所有未完成、候选与暂缓索引
├── data/  存储、身份与同步
│   ├── README.md
│   ├── icloud-implementation.md
│   └── sync.md
├── reader/  正文、准备流程与阅读工具
│   ├── import.md
│   ├── reading.md
│   └── tools.md
├── design/  产品与交互规则
│   ├── ai.md
│   ├── app-icon.md
│   ├── appearance.md
│   ├── book-details.md
│   ├── ios-integration.md
│   ├── library.md
│   ├── localization.md
│   ├── motion-and-moon.md
│   ├── palette-study.svg
│   ├── reader-panels.md
│   ├── settings.md
│   ├── statistics.md
│   ├── themes.md
│   └── ui-inventory.md
├── ai/  Agent、工具、原生服务、封面获取与消息呈现
│   ├── agent.md
│   ├── cover-fetch.md
│   ├── errors-and-confirmation.md
│   ├── native-tools.md
│   ├── rendering.md
│   ├── tool-presentation.md
│   └── tools.md
├── plans/  仅未完成的 AI、统计与书架拖动阶段
│   ├── ai.md
│   └── statistics.md
├── engineering/  架构、性能、工程方法与唯一验证记录
│   ├── ai-architecture.md
│   ├── ai-feasibility.md
│   ├── ai-implementation-audit.md
│   ├── ai-model-catalog.md
│   ├── ai-pi-alignment.md
│   ├── ai-providers.md
│   ├── architecture.md
│   ├── development.md
│   ├── ios-support.md
│   ├── performance.md
│   ├── repository.md
│   └── verification.md
└── research/  固定版本参考与调研
    ├── readers.md
    └── theme-references.md
```

设计文档：[主题与产品化](design/appearance.md)、[应用图标资源](design/app-icon.md)、[本地化](design/localization.md)。平台依据：[iOS 支持策略](engineering/ios-support.md)。参考研究：[开源阅读器对照](research/readers.md)、[主题与 iOS 实践](research/theme-references.md)。

## 维护方式

- 现有行为写在对应专题；未实现、候选和暂缓范围由 `roadmap.md` 索引，详细讨论留在专题；已实现但未验收的环境与场景集中在 `engineering/verification.md`。完成后将实际规则并入专题，删除已结束的阶段计划，不长期维护两套结论。
- `plans/` 只维护在讨论/实施中的分阶段任务、依赖和完成条件；页面与行为规则留在对应设计文档，不复制两套产品定义。
- 已采用的技术、内容身份和坐标契约放在 `engineering/architecture.md`；存储清单与多来源/导入规则集中在 `data/README.md`，同步细节在 `data/sync.md`，首页布局在 `design/library.md`。其他文档链接引用，不复制多份决定清单。
- 讨论阶段明确区分“已核对的现状”“已明确的需求”“设计建议”“未确定问题”。先记录问题背景、可选方向、取舍和需要的证据，候选不穷尽方案；未回答的问题不能用推荐选项代替答案。
- 验证结果更新 `engineering/verification.md` 对应条目，说明设备、用例与限制；不在每份功能文档追加逐轮日志。
- 调研注明日期或固定提交；参考结论不等于项目承诺。主题草案不写成已确认产品规则。
- 功能变化同步清理旧结论、更新入口与链接；被替代的结构直接删除，Git 保留历史，不额外保留空壳旧路径。
