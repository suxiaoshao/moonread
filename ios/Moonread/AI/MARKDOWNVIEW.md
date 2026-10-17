# MarkdownView 验证依赖

第一步 UIKit 文本块验证使用 [Lakr233/MarkdownView 4.8.3](https://github.com/Lakr233/MarkdownView/tree/4.8.3)，SPM 固定精确版本，源码提交 `00bcbc12a58601b407f379deb06791fe02fa1e31`。MIT 原文见 [MARKDOWNVIEW-LICENSE.txt](MARKDOWNVIEW-LICENSE.txt)。传递依赖以 Package.resolved 为准。

仅使用 MIT 库 API。FlowDown 为 AGPL，仅阅读缓存、测量和保留视图的设计思路，没有复制其源码。ListViewKit 属于尚待用户决定的第二步，当前未接入。

应用层通过公开的 `applyDocument`、解析节点、Litext 附件及绘制接口恢复三级标题字号、普通列表编号并去除强调下划线；不访问库内私有视图或修改依赖。代码块行号按本轮设计保留为已知差异，当前公开 API 没有关闭选项。
