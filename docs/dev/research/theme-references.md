# 主题与产品化参考

研究日期：2026-09-27。本轮查阅本地 gpui-component 源码、Apple 官方材料和 iOS 开发者原文；未运行参考项目，也未据此更换 Moonread 技术栈。产品提案入口见[外观与产品化](../design/themes.md)。

## gpui-component：借鉴类型分工

参考仓库 [suxiaoshao/gpui-kit](https://github.com/suxiaoshao/gpui-kit)，revision `dca2c369`。以下位置相对于该仓库：

| 类型/机制 | 本地位置 | 借鉴与取舍 |
| --- | --- | --- |
| `Theme` | `crates/component/src/theme/mod.rs:107` | 持有 colors、独立 light_theme/dark_theme 和 mode，同时含字体、圆角等；月读借鉴明暗槽位，结构规则则按用户要求从配色中固定分离 |
| `ThemeConfig / ThemeSet` | `crates/component/src/theme/schema.rs:24` | 一份主题配置有模式、名字、颜色，集合提供目录；月读应区分主题定义、用户选择和解析结果 |
| `SemanticThemeTokens` | `crates/base/src/theme_tokens.rs:11` | colors/radius/spacing/typography/shadow 分组，以语义用途命名；适合统一月读分散常量 |
| `ThemeColor` 与语义投影 | `crates/component/src/theme/theme_color.rs:62`、`theme/mod.rs:463` | 原有颜色中包含大量组件字段，另投影为语义角色；月读从小型语义角色起步，不复制兼容层、桌面 hover/dock/chart 等无关字段 |
| `Theme::update` | `crates/component/src/theme/mod.rs:247` | 单一更新路径协调派生状态；月读避免各页面直接改独立调色板，SwiftUI 与 UIKit 接收一致结果 |
| `MotionTokens` | `crates/component/src/theme/motion.rs:9` | 时长、曲线、弹性与距离统一命名；学习结构，不照搬桌面具体速度 |

本地源码可随后续开发变化，调研结论以此次提交基线为准。[仓库](https://github.com/suxiaoshao/gpui-kit)、[语义 token](https://github.com/suxiaoshao/gpui-kit/blob/dca2c369/crates/base/src/theme_tokens.rs)、[主题类型](https://github.com/suxiaoshao/gpui-kit/blob/dca2c369/crates/component/src/theme/schema.rs)。这里没有验证该本地提交的远程可访问性，准确代码以本地快照为准。

## Apple 官方材料

| 来源 | 本轮采用的要点 |
| --- | --- |
| [Color](https://developer.apple.com/design/human-interface-guidelines/color) | 系统语义色按外观和提高对比度适配；自定义色需同时考虑浅/深及更高对比。用途一致不等于所有元素同色 |
| [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | 材质按作用和层次选，不把某次渲染出的表观颜色视为固定色值 |
| [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars) | Tab 表达顶层导航，保留清楚标签和状态。当时曾提议月读只设书架/设置（非当前结构），阅读工具仍属书内 |
| [Launching](https://developer.apple.com/design/human-interface-guidelines/launching) | 启动画面接近第一屏，不把系统启动阶段做成强制品牌片头；App 内等待才有真实加载动画 |
| [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators) | 已知进度尽量真实显示，未知工作显示活动状态；位置稳定，可行时可暂停/取消，不制造假的百分比 |
| [preferredColorScheme](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:)) | 覆盖最近 presentation，不能假设任意子视图调用都只影响局部；App/Reader 的原生容器边界需要验证 |
| [colorScheme](https://developer.apple.com/documentation/swiftui/environmentvalues/colorscheme) | 当前环境值反映所在作用域，不能直接当作从未被覆盖的系统偏好；同时处理 contrast |
| [Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion) | 用系统辅助功能状态为动画提供替代；项目减少动效选项只能进一步收敛，不能强制覆盖系统开启的偏好 |
| [Xcode 12 SVG 图片资产](https://developer.apple.com/documentation/xcode-release-notes/xcode-12-release-notes/) | SVG 可作为图片资源编译；不等于可直接执行 SVG 动画或任意远程 SVG。月亮使用原生动画驱动编译资源 |

部分 Apple 页面直接打开只返回 JavaScript 提示；上表要点结合公开索引返回的官方正文读取。未把抓取失败当作某个 API 不存在，也未把外部文章建议当成 Apple 要求。

## iOS 社区原文

- Antoine van der Lee，2024-04-23：[Using @Environment in SwiftUI to link Swift Package dependencies](https://www.avanderlee.com/swiftui/environment-property-wrapper/)。以可观察 ThemeProvider 展示环境注入。月读可用相同思路把主题交给各页面，但核心偏好/继承规则仍留在 Rust，正文更新范围需单独控制。
- Keith Harrison，2021-03-01：[SwiftUI Custom Environment Values](https://useyourloaf.com/blog/swiftui-custom-environment-values/)。展示环境的局部覆盖。学习作用域原则；文章较早，当前工程的新自定义环境值可使用 `@Entry`，不直接复制旧 API 写法。

这两篇是作者的一手技术说明，支持环境与作用域设计，不能据此推断整个 iOS 社区有统一的主题框架。月读无需为了主题引入新的 UI 框架或状态库。

## 配色与可读性方法

- [W3C CSS Color 4：Oklab / OKLCH](https://www.w3.org/TR/css-color-4/#ok-lab)：仅借感知明度、色度、色相作为调色语言；并不将 CSS 用作原生界面方案。
- [WCAG 对比度说明](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)：作为 sRGB 文字/背景对比的量化参考；不把一次静态数字当作所有原生状态、材质或夜间舒适度验收。

杏桃、薄荷、雾紫以及其色值、间距和动效参数是月读的设计建议，不是上述来源规定的配方。可发布版本需完整语义色、实际画面和辅助功能检查。
