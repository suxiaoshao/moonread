# 月读 · Moonread

一个以 iOS 为首个平台的本地 TXT 小说阅读器，为喜欢夜间阅读的人打造。

## 产品方向

- 所有书架统一为真实文件夹树，支持应用内改名、移动、新建子目录与删除。“我的书架”是不可移除的内置根入口；支持单个/多个 TXT 导入，以及系统分享或文件打开接收。
- 单本小说内搜索，支持 ripgrep 语法。
- 单本小说 AI 提供 `rg` 和 `read` 工具；全工作区 AI 增加 `ls` 工具。
- 用户自带 AI API key，订阅套餐按供应商支持情况接入；应用不提供 AI 账号。
- 导入按文件名处理，同名由用户选择替换或取消；规范文本指纹用于共享阅读记录，正文变更创建新记录并保留旧记录。
- 小说原文使用真实目录；未启用 iCloud 时本地保存，启用后由应用接入自身固定 iCloud 目录，不提供用户自选位置或整库迁移设置。正文 SHA 下的用户数据与配色方案由 SwiftData + CloudKit 管理，显示选择、排版及设备偏好留在本机。同步代码已接入，云能力签名与真机安装已完成，真实跨设备联调仍待验收，见[接入实施](docs/dev/data/icloud-implementation.md)。

## 当前阶段

基础 TXT 阅读主流程已实现。AI 已接入本机文本对话、阅读月亮与弹窗、连接和模型管理，以及四种文本协议；Agent 的10个读取工具、队列、压缩、历史分页及过程/确认/来源预览已接入页面；联网、图片和内容整理尚未完成，详见 [AI 当前进度与剩余工作](docs/dev/plans/ai.md)。正式签名应用的真实账户完整流程、长时间阅读、最低系统、辅助功能和真实云端联调仍按验证记录跟进。

基础阅读与阅读工具：本地 TXT 支持边准备正文边阅读、滚动和分页，并已接入章节目录、书签、单书搜索、标注与私人批注。Rust 承担正文解码、章节、搜索、位置换算和阅读计算；SwiftData 保存用户数据，Swift 负责 UI、原生排版和文件访问。以连续、舒适的实际阅读为交付标准，技术检查用于支持这一目标。工程部署下限为 iOS 18.0，使用 Xcode 27 构建。

排版、阅读控制、卷章纠错、进度导航、主题与实时预览已接入。书架支持最近阅读 3 本、多目录与嵌套浏览、列表/网格、原生页面内文件名搜索，以及真实文件管理、全选、TXT 批量复制导入和导出。内置“我的书架”根据容器可用性使用固定本地或 iCloud Documents；外部根可来自系统文件提供方。CloudKit 接入已完成本地合并回归，尚未完成云端验收。当前正文搜索支持单书字面量与单行 Rust 正则，不等于完整 ripgrep 功能；独立分享扩展尚未实现；AI 已接入对话闭环，正文工具及过程、确认和来源预览已接入页面，资料整理尚未实现。具体行为见[数据与来源](docs/dev/data/README.md)及[首页与书架](docs/dev/design/library.md)。

章节目录一次取得完整轻量元数据，按需绘制行，显示预计算字数与累计估算覆盖。本地统计展示今日/本周时长、期间书目/占比、实际阅读时段及单书月历；单书统计并入[小说详情](docs/dev/design/book-details.md)，支持完整正文 SHA 下的作者、简介、标签、封面编辑及作者/标签搜索筛选。覆盖以正文范围连续可见 3 秒为门槛，保留 2 分钟闲置规则；回看分析尚未实现，统计同步已接入但真实跨设备交付待验收，见[统计设计](docs/dev/design/statistics.md)。

构建与试用见[开发环境](docs/dev/engineering/development.md)，已执行检查及限制见[验证记录](docs/dev/engineering/verification.md)。开发依据从[开发文档](docs/dev/README.md)进入；未完成能力、候选与暂缓项集中在[后续计划](docs/dev/roadmap.md)。

## 开发准备

- 安装 Nix 和 Xcode，运行 `nix develop` 进入锁定版本的开发环境；无需单独安装 Rust 或执行安装脚本。iOS 工程会自动通过该环境编译 Rust 并生成绑定。
- 项目约定：[AGENTS.md](AGENTS.md)。
- 仓库设置、自动检查及模板：[仓库与持续集成](docs/dev/engineering/repository.md)。
- Git 忽略规则覆盖 macOS、Xcode、SwiftPM、Rust 构建产物和本地凭据。
- 项目级 skill：[SwiftUI Expert](.agents/skills/swiftui-expert-skill/SKILL.md)，用于后续 SwiftUI 开发与审阅。

Skill 来源：[AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill)，固定版本 `4.2.0`，提交 `9692ec5c3e78a0acc7757de2dbe8e64e519a72fb`。保留上游 skill 内容及其 [MIT 许可](.agents/skills/swiftui-expert-skill/LICENSE)。更新时显式选择新版本。

## 许可

自有代码与原创样本采用 [MIT License](LICENSE)，Copyright (c) 2026 suxiaoshao。依赖、字体、品牌图标与开发资料保留各自许可，详见[第三方声明](THIRD_PARTY_NOTICES.md)及 App 随附的完整许可文本。
