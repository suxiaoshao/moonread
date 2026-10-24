# 主题模型、结构规则与配色

状态：2026-09-27 首轮已实现。结构统一、颜色按配色定义，App 和阅读分别保存浅深槽位。现状见[样式盘点](ui-inventory.md)，调研依据见[主题参考](../research/theme-references.md)。

## 三个维度分开

| 维度 | 解决的问题 | 策略 |
| --- | --- | --- |
| 结构 | 元素之间多远、圆角多大、边框多粗、怎样运动 | 全 App 共用结构和动效规则，不因切换配色改变 |
| 明暗 | 当前采用浅色还是深色槽位 | App 可跟随系统/浅色/深色；阅读可跟随 App/跟随系统/浅色/深色 |
| 配色来源 | 选定明暗槽位使用谁的颜色 | App：系统/预设/自定义；阅读：跟随 App/系统/预设/自定义 |

“系统配色”指 Apple 动态语义颜色与默认控件着色，不承诺从壁纸、桌面图标着色或一个全局自选强调色读取主题。它与“跟随系统明暗”是不同选项。例如 App 可固定深色，同时使用系统深色语义色。

App 保存一份浅色配色选择和一份深色选择；阅读同样保存两个槽位，切换模式不覆盖另一个槽。可以给 App 选杏桃浅色、雾紫深色，阅读则选系统浅色、薄荷深色。

## 数据契约

下列表示共享契约的逻辑结构。实际 [Rust/UniFFI 类型](../../../crates/moonread-core/src/themes.rs) 使用显式 appLight/appDark/readerLight/readerDark 字段保存槽位，PaletteId 指向指定明暗的完整调色板，ResolvedTheme 另携带高对比状态。

```text
Appearance = Light | Dark
AppAppearanceMode = System | Light | Dark
ReaderAppearanceMode = App | System | Light | Dark

AppPaletteSource = System | Palette(PaletteId)
ReaderPaletteSource = App | System | Palette(PaletteId)

AppearancePair<T> { light: T, dark: T }
AppThemePreferences {
    mode: AppAppearanceMode,
    palettes: AppearancePair<AppPaletteSource>
}
ReaderThemePreferences {
    mode: ReaderAppearanceMode,
    palettes: AppearancePair<ReaderPaletteSource>
}
ThemePreferences { app, reader }

PaletteDefinition {
    id, name, appearance,
    origin: Preset | Custom,
    colors: SemanticPalette,
    increasedContrastColors: SemanticPalette
}
ResolvedThemePlan { appearance, palette, contrast }
```

Rust 保存偏好、调色板与纯数据解析规则；平台输入系统明暗/对比度，核心返回解析计划。Swift 把系统角色和颜色数据映射到 `UIColor/Color`、材质与原生组件；不把字体对象、SF Symbols 名称或 UIKit traits 存入共享模型。没有引入 GPUI 依赖的必要。

自定义颜色以不透明 sRGB RGB 保存，颜色选择器禁用透明度，广色域输入转换到 sRGB。用户从完整配色复制后编辑，未编辑角色保留；对比不足在预览处显示提示，但允许保存。系统来源保留语义角色，不永久保存某一帧的 RGB。自定义主题导入/导出不在首轮范围。

## 解析顺序与继承

1. 从未被 App 覆盖的系统环境取得 `systemAppearance` 和辅助功能状态。
2. 根据 App mode 得到 `appAppearance`，读取该槽的 App 配色来源。
3. 根据阅读 mode 得到 `readerAppearance`；`App` 取上一步明暗，`System` 取真实系统明暗，固定项直接取指定值。
4. 读取对应阅读槽。若为 `App`，使用 **App 在 readerAppearance 对应槽中的配色**；不机械复制当前另一明暗的 RGB。
5. 根据对比度解析完整角色，再交给所在界面作用域。继承是单向 `系统 → App → 阅读`，阅读不反向修改书架。

| 系统 | App 设置 | 阅读设置 | 结果 |
| --- | --- | --- | --- |
| 深色 | 跟随系统；深色=雾紫 | 明暗和配色都跟随 App | App 与阅读均为雾紫深色，使用各自 canvas/paper 角色 |
| 浅色 | 固定深色；深色=雾紫 | 明暗=系统；浅色=系统 | 书架为雾紫深色，阅读为系统浅色 |
| 深色 | 固定浅色；浅色=杏桃、深色=薄荷 | 明暗=深色；深色配色=App | 阅读取 App 的薄荷深色槽；书架仍是杏桃浅色 |
| 浅色 | 系统浅色 | 阅读固定深色；深色=自定义 | 系统/App 改色不覆盖这份自定义深色阅读配色 |

新增预设为纯黑夜间（`black-dark`，paper 为 `#000000`）、素白（`white-light`）和豆沙绿（`bean-light`）。旧六份预设和 ID 不变；派生色及高对比版本沿用生产函数。snapshot 上限为内置配色数量加 64 份自定义配色；纹理另存于本机阅读偏好，不进入配色定义。

初始 App 跟随系统明暗，浅深配色均为杏桃；阅读完全继承 App。任何修改都不覆盖其他槽位，也不改变字号、行距、阅读模式和进度。

## 语义颜色

“统一”是角色与使用规则统一，不要求书架列表底色与阅读纸面逐像素相同。同一主题应有协调的 `canvas/surface/paper`，默认不再出现没有归属的第三套颜色。

| 角色组 | 必要角色 | 用途 |
| --- | --- | --- |
| 表面 | `canvas`、`surface`、`surfaceRaised`、`inputSurface`、`paper` | App 页面、分组/浮层、输入区、正文纸面 |
| 文字 | `textPrimary`、`textSecondary`、`textDisabled`、`readerInk`、`readerMetadata` | 界面与长文区分；正文不能靠高透明度获得柔和感 |
| 操作 | `accent`、`accentSurface`、`onAccent`、`focus`、`pressedSurface`、`selectedSurface` | 按钮、焦点、按压/选择反馈；不再根级 `.tint(.primary)`。导航栏与工具栏中的导航、工具与新建图标（齿轮、返回、×、…、定位、＋、新对话）由 `toolbarGlyph()` 显式使用当前主题 `ink`，作为工具栏层面的细化，根级仍为 accent；选中／当前状态、焦点与主要提交按钮保持 accent，破坏性操作保持红色 |
| 边界 | `separator`、`border` | 分隔线与需要可见边界的输入框；颜色随主题，宽度不变 |
| 阅读记录 | `annotationFill`、`searchFill`、`searchCurrentFill`、`selectionTint` | 标注与搜索保持可辨；正文 glyph 仍使用 readerInk，不把整行染色 |
| 状态 | `destructive`、`onDestructive`、`warning`、`success` | 保留含义，并结合文字/图标，不用主题主色替代所有状态 |
| 品牌 | `moonBody`、`moonMaria` | UI 月亮的对比适配；桌面 `.icon` 不随阅读主题重着色 |

实心强调按钮使用原生 `.borderedProminent`，由 `ThemedProminentButtonStyle` 将 `accent` 与 `onAccent` 成对应用到背景、文字和图标。不能继承页面的普通 `ink`：浅色主题的深底需要浅字，深色主题的浅底需要深字；自定义配色同样使用自身的 `onAccent`。

系统材质使用语义策略而非“固定背景色”。选择原生 sheet、菜单、导航的材质时尊重系统，不为追求 RGB 一致覆盖整个玻璃表面。阅读面板继承阅读作用域的明暗、文字、输入和选择状态；若材质导致颜色失控或降低对比，可使用阅读 `surface` 的不透明内容区。降低透明度和提高对比度均需有可读结果。[Apple Color](https://developer.apple.com/design/human-interface-guidelines/color)、[Materials](https://developer.apple.com/design/human-interface-guidelines/materials)

## 统一的结构规则

以下是设计基线建议，主题文件仅改变颜色，不能覆盖这些尺寸。系统组件继续拥有其内部尺寸；不要把所有原生 List/Form 间距重新画一遍。

| 类型 | 建议统一值/规则 |
| --- | --- |
| 间距尺度 | 4、8、12、16、20、24、32pt；2pt 仅作图形细部调整，不用于随机填补页面 |
| 页面/表单 | 自定义页面标准内容边距 20；紧凑工具/输入内部 12–16；相关项目间 8–12；章节间 24–32。实际按语义选择 |
| 圆角 | 小状态块 8、输入与普通表面 16、独立浮层 20、pill 全圆；系统 sheet 的外轮廓由系统优先决定 |
| 边框 | 自定义输入描边 1pt；纯分隔线用原生 Divider 或按显示比例取 1px；聚焦只改绘制不挤压内容 |
| 操作触区 | 常规图标按钮至少 44×44pt；图形本身可更小；大字时允许内容撑高 |
| 字体层次 | App 用系统 text style 和 Dynamic Type；阅读排版独立保存，不作为主题的一部分 |
| 阴影 | 普通书架行和正文不用阴影；浮层优先系统材质，自绘阴影仅建立层级时使用 |
| 特殊阅读参数 | 正文 16pt 边距、22pt 信息栏、底部渐变、104pt 编辑器最小高度等按真实用途管理，不强行四舍五入到通用间距尺度 |

输入焦点与键盘同步：章节搜索、全文搜索和配色名称使用同一套页面内点击规则，点击输入区域外释放 `FocusState`，收起键盘并恢复普通边框；点击外部按钮仍执行其原操作。输入区域包括清除等自身附件，框内光标和选字不收键盘。列表/表单保留原生拖动收键盘；切换章节/书签/笔记页签也结束编辑。规则只作用于当前页面，不向全 App 广播 `endEditing`。批注继续由原生编辑表单处理输入边界和键盘，不重复叠加手势。

通过窄类型 `LayoutTokens / BorderTokens / RadiusTokens / TypographyRoles / MotionTokens` 使用。不同页面需要不同的合理尺寸，但同一语义用途共享值；不要求所有圆角都变成同一个数字。

## 配色方向：明快、温软、可爱

这不是单一色相名称。明快与明度、清晰层次有关；温软通常来自克制的色度、温和的色相搭配及大面积低色度背景；可爱还来自圆润图形、适当留白和轻巧反馈。深色主题也可以温软，不需把夜间底面做亮。

设计时可用 OKLCH 的感知明度 L、色度 C、色相 h 控制差异；C 与 HSL 的“饱和度”不是同一个数值。最终转换为明确色域的 sRGB 并检查实际对比，不直接用一套色相旋转或浅色反相生成所有主题。[W3C 色彩定义](https://www.w3.org/TR/css-color-4/#ok-lab)

提供 **杏桃**（温暖、轻甜）、**薄荷**（清爽、安静）、**雾紫**（柔和、带夜色感）。每种浅深版本独立设计，避免大面积高饱和底色；新增纯黑夜间、素白、豆沙绿三个完整预设。下表是当前核心颜色；完整角色、高对比增强与校验位于 Rust。自定义配色增强对比若导致其他表面不可读，会保留已经校验的原色，避免破坏颜色关系。

| 预设 | canvas | surface | paper | readerInk | 次要文字 | accent |
| --- | --- | --- | --- | --- | --- | --- |
| 杏桃·浅 | `#F7EFE5` | `#FFF9F2` | `#F5ECDA` | `#403833` | `#6F6057` | `#A94F3D` |
| 杏桃·深 | `#201B19` | `#2B2421` | `#241F1C` | `#D6C8BA` | `#B8A69A` | `#E6A68E` |
| 薄荷·浅 | `#EDF4EF` | `#F7FCF8` | `#F4FAF5` | `#2E4138` | `#5F7368` | `#2F725E` |
| 薄荷·深 | `#17231F` | `#20312A` | `#1C2924` | `#C5D5CA` | `#9EB8A9` | `#98CDB6` |
| 雾紫·浅 | `#F1EFF8` | `#FAF8FE` | `#F8F5FC` | `#3B3649` | `#71687F` | `#71549D` |
| 雾紫·深 | `#211F2B` | `#2C2839` | `#262230` | `#D0C8DF` | `#B2A5C4` | `#C3A6E5` |
| 纯黑夜间·深 | `#000000` | `#101010` | `#000000` | `#B8B8B8` | `#939393` | `#9FBDE5` |
| 素白·浅 | `#F4F4F4` | `#FFFFFF` | `#FFFFFF` | `#303030` | `#606060` | `#315E8A` |
| 豆沙绿·浅 | `#DCE6D7` | `#EAF0E5` | `#DCE8D1` | `#303B2D` | `#55614E` | `#386441` |

静态配色示意见[配色草图](palette-study.svg)。它只比较颜色方向，不代表最终组件布局或月亮资产改版。

杏桃·浅的纸面比其他浅色更暖、更暗（OKLCH L≈0.945、C≈0.026），作为默认的暖纸。原有三套深色正文把对比控制在 10:1 左右，尝试较柔和的深色正文，舒适度待用户试读。继续降低正文亮度时需同时检查批注与搜索底色上的文字对比，不能只检查 paper。浅色的普通命中、当前命中与批注底色彼此保持可见差别（OKLCH ΔE 约 0.06–0.11），选区由系统按 accent 绘制。

按 sRGB 相对亮度计算，原有六组 `readerInk/paper` 对比依次为 9.77、9.96、10.28、9.87、10.75、9.61；次要文字/paper 最低 4.79。此结果不涵盖透明叠加、玻璃材质、选中/禁用/破坏性按钮或高对比版本，不等于真机视觉验收。使用 WCAG 的普通文字 4.5:1 作为可量化参考，正文优先争取 7:1 以上，同时由夜间实读决定舒适度，不宣称护眼效果。[对比度参考](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)

## iOS 应用方式与稳定性

- SwiftUI 用一次注入的主题环境传递解析结果；App 与 Reader 各有作用域，UIKit 正文和编辑器显式接收相同结果，避免读取另一套全局单例。
- `.preferredColorScheme` 作用于最近 presentation（如 window/sheet），不能随意放在阅读子视图后假设只改变正文。阅读容器须有明确的原生 appearance 边界，并将同一结果传给其 sheet、菜单、键盘和原生文字视图；退出后不污染设置页。原型时验证 push、弹层和交互取消。[Apple API](https://developer.apple.com/documentation/swiftui/view/preferredcolorscheme(_:))
- 真实系统明暗从覆盖范围之外获取，避免“App 固定深色后，阅读跟随系统却始终变深色”的反馈环。仅颜色角色不同且明暗一致时无需重设系统 appearance。
- 颜色切换只触发绘制和界面状态变化，不改变正文尺寸、重建页面控制器或写入阅读位置。`CGColor` 等解析快照在主题/trait 改变时更新；动态颜色、渐变、输入边框、选区 tint 一起更新。
- 自定义预览用独立 draft，“完成”原子保存，“取消”不改正式数据。预设选择即时保存。保存前校验角色、引用、明暗槽和 RGB 格式；可读性只作提示；删除弹窗明确说明受影响的 App 槽恢复杏桃、阅读槽恢复跟随 App，其余槽保留，核心原子执行。
- 用户偏好与颜色业务由 Rust 管理；平台可持有可丢弃的启动显示快照以尽早画背景，不能变成第二套权威设置。初始化路径见[月亮与动效](motion-and-moon.md)。

## 实施验收

覆盖系统浅/深、App 固定/系统、阅读继承/独立及来源组合；两个未激活槽重启后保持。检查所有阅读 sheet、原生菜单、键盘、搜索与批注，而不只检查纸色。测量改色前后正文行、选区、页边界与进度不变；检查提高对比度、降低透明度、减弱动态和大字号。结构 token 替换不得顺手改变阅读几何，排版调整另按阅读计划处理。

## 数据保存

设备的 ThemePreferences 独立保存明暗与配色选择；每份自定义 ThemePalette 独立作为用户数据保存并同步。两者不包装成完整主题快照，保存单份配色不携带设备偏好或其他配色。

ThemeSnapshot 仅用于组合当前解析输入，以及可丢弃、可重建的首帧缓存。远端删除选中的自定义配色后，设备选择回到既定默认来源；缓存不是用户数据权威来源。

## 阅读纸张纹理（本机选项）

ThemePreferences 的 reader_light_texture / reader_dark_texture 是可选本机槽位，默认无，与配色独立；选择无会清空该槽，再启用默认淡。旧 JSON 缺字段按无读取；未知纹理 ID 或强度也归无，未知值不保留，读取不回写。ThemePalette、同步协议和备份格式不变。更换配色保留纹理，系统来源暂不绘制，控件置灰并说明「请选择具体配色后使用纹理」；恢复具体配色时恢复所选槽位。高对比照常绘制，不检测或降低纹理对比度。

浅槽为宣纸 paper-v1、牛皮纸 kraft-v1、细麻布 linen-v1；深槽为夜间细噪点 night-v1。Rust 提供 ID/强度枚举及档位 alpha：浅纹理淡/中/浓为 6/10/14 除以 255，夜间为 3/6/9 除以 255。四张 768×768 归一化 RGBA source PNG（每张对应 256pt）随 Asset Catalog 分发，平台按 256pt 周期及 displayScale 合成不透明 tile，仅保留当前输入和结果。

滚动时 pattern 放在不滚动的 readingSurface，正文和内层标题页透明；分页把 pattern 放在原 PageController 的正文 view 和封面 hosting view，随页移动。根外围和底部 fade 继续用纯 paper。纹理只换背景，不改字体、textStorage、排版、选区或导航位置；不新建背景层、缓存服务、随机运行时生成器或同步记录。

阅读设置的纹理与强度作为配色列表首个分组，位于明暗槽切换下方，随列表滚动。展开预览的标题和正文共享同一平铺背景；正文保持透明，不改变预览视口或位置恢复的几何。
