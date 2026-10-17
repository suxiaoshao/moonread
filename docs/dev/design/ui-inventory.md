# 界面样式与归属

更新：2026-09-30。主题改造已接入 App，下面记录当前角色和尺寸来源；完整配色与继承规则见[主题模型](themes.md)，验证范围见[验证记录](../engineering/verification.md)。

## 颜色从哪里来

颜色由 Rust 的 [themes.rs](../../../crates/moonread-core/src/themes.rs) 定义和解析，经 Swift 的 [Theme.swift](../../../ios/Moonread/Shared/Theme/Theme.swift) 映射为原生颜色。已删除旧 ReaderPalette 和根级 tint(.primary)。系统来源保留原生语义颜色；预设和自定义使用完整 sRGB 角色。

| 界面 | 使用角色 | 平台处理 |
| --- | --- | --- |
| 书架、设置 | canvas、surface、ink、secondary、accent | 原生 List/Form/Tab，内容背景和列表行接入主题；系统拥有控件内部间距 |
| 书架管理 | canvas、surface、ink、secondary、accent、separator、destructive、moon/maria | 标准居中导航标题，右上角原生 `＋`；内嵌分组 List 使用独立紧凑 Label 行，默认 24pt 图标，上下 8pt 行内边距，名称与来源双行对齐；动态字号自然撑高，不使用首页的大图标行或悬浮标题 |
| 书架小说与找书 | accentSurface/accent、ink、secondary、input、search、separator、moon/maria | 小说文字封面与文件夹内最多四本小封面共用列表／自适应网格；书籍行上下 12、目录行上下 8、页面左右 20；普通目录固定最近阅读排序，“全部小说”递归书目提供名称索引，使用 accent 并预留宽度；结果路径用 caption2，命中使用 search；恢复原生紧凑导航标题和默认背景，原生操作按钮保持位置，无胶囊标题或自定义滚动显隐；搜索按需展开并保持输入框可见；空白等待页用居中大号系统转圈，内容就绪后淡出，已有内容用导航栏 20pt 系统转圈；文件获取在对应封面内显示可取消原生进度条＋真实百分比，未知进度用系统转圈，更多按钮和条目布局保持不变 |
| 正文与信息栏 | paper、ink、secondary | UIKit 与 SwiftUI 接收同一阅读作用域；动态 UIColor 只更新绘制，正文存储不重写 |
| 正文底部渐变 | paper → 透明 | 更新 CGColor，不改变渐变位置和高度 |
| 目录、书签、笔记 | surface、ink、accent、secondary、separator、destructive | 当前章标题与字数都用 accent，其他章字数用 secondary；章节输入区同样采用 input 与 border/focus；删除保留文字与图标 |
| 搜索 | surface、input、ink、secondary、border/focus、separator、accent/accentSurface、selected | 摘要使用原生 SwiftUI AttributedString 显式设置 ink；普通命中用 search，选中命中与正文都用 searchCurrent；当前行底色用 selected，标注用独立 annotation |
| 批注 | surface、raised、input、ink、secondary、border/focus、selection | 原生控制器显式设置主题与键盘明暗；输入和摘录圆角统一为 16 |
| AI 对话与列表 | canvas/surface、raised、input、accentSurface、ink、secondary、accent/onAccent、border/focus、selected、destructive、success、moon/maria | 对话列表为 plain List：标题＋右侧时间或运行状态，下一行为最新可见消息摘要，关联书名用小字；对话页用户气泡 accentSurface 靠右，回复无底框；输入框 1pt border/focus，发送与停止为 accent 实心圆；阅读弹窗沿用阅读作用域的 surface；阅读月亮为主题 MoonView 加纸色间隙，状态角标颜色按语义。细则见 [AI 阅读助手](ai.md) 与[对话错误与单次操作确认](../ai/errors-and-confirmation.md) |
| 准备、空态、关于 | moon、maria、secondary、paper | 月亮角色以矢量路径按主题着色（静止姿态；扉页为读书姿态），月体保持完整圆形 |
| 阅读封面／扉页 | paper、ink、secondary、accent；品牌固定色 | 书名与品牌图标（无封面时）居中、细分隔线和小字号落款；与书架文字封面共用字体设计和主题角色，封面使用阅读主题。正文准备阶段复用这一画面，较慢任务在底部显示原生加载进度 |
| 启动页 | LaunchBackground 浅深颜色资产、LaunchSeal（桌面图标渲染） | 系统静态图与 App 首帧均为 120pt 桌面图标、全屏居中；主题与本地首页快照就绪或错误后（根等待上限1s、封面子预算150ms），底色和图标一起250ms原地淡出，减弱动态缩短至 120ms；首页同步可用，回前台不重播 |

应用自绘内容的文字层级显式读取 ink/secondary，包括书架文件名与路径、目录与笔记摘要、搜索标题/结果数量/摘要、空态和准备状态。不能用通用 `.primary/.secondary` 代替配色中的独立角色。自绘分隔线使用 separator；自定义返回、撤销、准备与加载浮层在预设/自定义配色下使用 raised，选择系统配色时保留系统材质。

搜索 List 的行背景、分隔线和间距修饰放在几何观察器外层，使列表能读取到行样式；列表自身也显式设置 surface。深浅截图验证普通结果行与面板同底色，选中行使用 selected，防止只改文字后仍残留系统黑/白色列表。

原生导航、菜单、键盘、控件内部和玻璃仍由系统绘制。搜索 Tab 的入口、输入框、token 和取消按钮由系统 `searchable` 绘制，不使用阅读搜索面板的自定义输入样式；结果文字和命中继续使用主题角色。`ThemeSurface` 内的系统语义色是“系统配色”的映射；透明绘制层/遮罩不是独立色板；主题编辑器中的色块展示被编辑配色的值；LaunchBackground 与桌面图标是静态平台资产。这些是明确的颜色来源，不是页面自行硬编码的 RGB。不能把系统材质某一帧的 RGB 当作固定色。

## 结构规则

[LayoutTokens](../../../ios/Moonread/Shared/Theme/Theme.swift) 管理 8/12/16/20/24 间距角色、44pt 操作触区、16pt 输入圆角、20pt 浮层圆角和 1pt 边框。主题不能覆盖结构。

| 部位 | 当前值/约束 |
| --- | --- |
| 书目行 | 标题/状态 8，行上下 8；来源两行间 4 |
| 正文 | 上 16、左右 16、下 4；紧凑信息栏 22；字号/行距由阅读设置管理 |
| 工具覆盖层 | 操作触区 44；顶部恢复普通返回图标、居中书名及原有纸色渐变，删除圆形／胶囊玻璃；底部沿用原生工具 sheet；显示工具不改变正文区域 |
| 搜索 | 输入圆角 16、描边 1、选项圆角 8；sheet 圆角 32；紧凑档按药丸与工具实际内容测量，详情用原生大档，展开期间保留起始高度 |
| 批注 | 外边距和块间距 20，摘录内边距 16，输入最小高度 104；聚焦只改边框色 |
| 标注底纹 | 按字身绘制，圆角 min(2, 字身高度 × 0.1)，不包含额外行距 |

原生控件内部规格不重新绘制。正文、普通列表不增加装饰阴影。渐变距离、文字装饰和编辑器最小高度属于各自场景，不机械替换成通用间距。

## 动效归属

MotionTokens 统一工具 180ms、减少动态 100ms、快捷面板高度 200ms、搜索面板 240ms、配色 180ms；原生导航、sheet、分页和键盘保留系统时序。辅助加载提示延迟 300ms 防闪烁。无内容的整页未知等待用居中大号系统转圈，局部未知进度用小号系统转圈，已知进度用原生线性进度条；月亮不做加载动画。进度来自真实任务，不循环。

位置稳定、明暗反向组合、保存重启与实际截图必须一起检查。已覆盖和仍未验证的环境分别记录在验证文档，不因有主题类型就视为产品体验验收完成。
