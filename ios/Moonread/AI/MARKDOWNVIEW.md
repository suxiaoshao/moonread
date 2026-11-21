# MarkdownView 验证依赖

当前 UIKit 文本块使用 [Lakr233/MarkdownView 4.8.5](https://github.com/Lakr233/MarkdownView/tree/4.8.5)，SPM 固定精确版本，源码提交 `3941f1857005d648f452fd1bfbdbe01d37961fd2`。MIT 原文见 [MARKDOWNVIEW-LICENSE.txt](../../Packages/MoonreadAI/Sources/MoonreadAI/Resources/MARKDOWNVIEW-LICENSE.txt)。Litext 以 3.6.7 为基线重放隐私清单，经 workspace mirror 锁定 `cabc9c669e04f9e84629c867554a1660cd69b5da`。swift-collections 以传递依赖锁定 1.7.6。

仅使用 MIT 库 API。FlowDown 为 AGPL，仅阅读缓存、测量和保留视图的设计思路，没有复制其源码。ListViewKit 属于尚待用户决定的第二步，当前未接入。

应用层通过公开的 `applyDocument`、解析节点、Litext 附件及绘制接口恢复三级标题字号、普通列表编号并去除强调下划线；不访问库内私有视图或修改依赖。代码块行号按本轮设计保留为已知差异，当前公开 API 没有关闭选项。
