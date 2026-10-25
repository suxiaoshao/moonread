# 开发文档

月读以舒服、连续的本地小说阅读为目标。产品介绍见[项目 README](../../README.md)，工作规则见[AGENTS.md](../../AGENTS.md)。当前开发版本为 1.3；已实现行为以专题与源码为准，已确认但未实现的范围见[后续安排](roadmap.md)。发布不等于所有设备、云端和长时场景已验收，具体证据见[验证记录](engineering/verification.md)。

## 开发与发布

- [架构与规则归属](engineering/architecture.md)：Rust/Swift 单一 owner、正文身份、坐标与持久化演进。
- [开发环境与分支协作](engineering/development.md)、[仓库与持续集成](engineering/repository.md)、[iOS 支持策略](engineering/ios-support.md)。
- [性能设计与待优化](engineering/performance.md)、[测试原则与验证记录](engineering/verification.md)。
- [CloudKit 发布核对](data/cloudkit-release-checklist.md)、[发布与 TestFlight](engineering/release.md)。

## 数据与同步

- [存储、文件书架与正文身份](data/README.md)。
- [同步、冲突与删除](data/sync.md)、[备份与缓存清理](data/backup-and-cleanup.md)、[最近阅读恢复](data/recent-reading-restoration.md)。

## 阅读与界面

- [正文准备与编码](reader/import.md)、[排版与阅读交互](reader/reading.md)、[目录/搜索/批注与导航](reader/tools.md)。
- [首页与书架](design/library.md)、[小说详情](design/book-details.md)、[阅读统计](design/statistics.md)、[阅读弹层](design/reader-panels.md)。
- [当前设置页](design/settings.md)、[设置信息架构与新增入口规则](design/settings-information-architecture.md)、[系统集成设计](design/ios-integration.md)。
- [主题模型与纹理](design/themes.md)、[界面样式归属](design/ui-inventory.md)、[动效与月亮](design/motion-and-moon.md)。
- [应用图标](design/app-icon.md)、[配色研究图](design/palette-study.svg)、[本地化](design/localization.md)。
- [首次引导](design/onboarding.md)、[支持月读](design/tip-jar.md)。

## AI

- [产品入口、许可与业务确认](design/ai.md)、[内部分层与存储](engineering/ai-architecture.md)。
- [Agent 执行](ai/agent.md)、[工具契约](ai/tools.md)、[原生搜索与生图](ai/native-tools.md)、[封面提取](ai/cover-fetch.md)。
- [消息呈现](ai/rendering.md)、[工具展示映射](ai/tool-presentation.md)、[错误与单次确认](ai/errors-and-confirmation.md)。
- [供应商与身份](engineering/ai-providers.md)、[模型目录](engineering/ai-model-catalog.md)。
- 历史依据：[接入选型](engineering/ai-feasibility.md)、[实现审计](engineering/ai-implementation-audit.md)、[Pi 对照](engineering/ai-pi-alignment.md)。历史依赖和检查结果不能当作当前实现状态。

## 计划与研究

- [后续安排](roadmap.md)：已定稿待实施、候选和暂缓范围的索引。
- 活跃专题计划：[AI 未完成工作](plans/ai.md)、[统计回看与历史位置](plans/statistics.md)。
- 固定版本研究：[开源阅读器](research/readers.md)、[主题参考](research/theme-references.md)。

## 维护方式

- 现有行为写在对应专题；未实现、候选和暂缓范围由 `roadmap.md` 索引，详细讨论留在专题；已实现但未验收的环境与场景集中在 `engineering/verification.md`。完成后将实际规则并入专题，删除已结束的阶段计划，不长期维护两套结论。
- `plans/` 只维护在讨论/实施中的分阶段任务、依赖和完成条件；页面与行为规则留在对应设计文档，不复制两套产品定义。
- 已采用的技术、内容身份和坐标契约放在 `engineering/architecture.md`；存储清单与多来源/导入规则集中在 `data/README.md`，同步细节在 `data/sync.md`，首页布局在 `design/library.md`。其他文档链接引用，不复制多份决定清单。
- 讨论阶段明确区分“已核对的现状”“已明确的需求”“设计建议”“未确定问题”。先记录问题背景、可选方向、取舍和需要的证据，候选不穷尽方案；未回答的问题不能用推荐选项代替答案。
- 验证结果更新 `engineering/verification.md` 对应条目，说明设备、用例与限制；不在每份功能文档追加逐轮日志。
- 调研注明日期或固定提交；参考结论不等于项目承诺。主题草案不写成已确认产品规则。
- 功能变化同步清理旧结论、更新入口与链接；被替代的结构直接删除，Git 保留历史，不额外保留空壳旧路径。
