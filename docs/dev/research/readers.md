# 开源阅读器源码对照与阅读体验基线

阅读机制及月读状态核对：2026-10-01；书架参考源码核对：2026-09-30。本文保存固定版本的源码证据与可借鉴机制；月读当前功能以[专题文档](../README.md)为准，差距及建议顺序集中于[后续计划](../roadmap.md)。参考项目的功能不自动成为月读的实现要求。

## 结论

月读已经补齐基础小说排版、阅读控制、章节识别与人工纠错、快速定位/跳转历史、完整目录快照、多目录书架和本地阅读统计，不再把这些整项列为差距。小说详情、作者/标签与封面编辑、章节估算覆盖也已落地。选字与点击批注共用菜单，交叉选区可编辑合并、移除和撤销。以本地 TXT 的“打开—阅读—查找/标注—退出—续读”为范围，基础功能闭环已具备；这不等于长期体验与平台验收全部完成。

对照固定源码，尚值得补充的是导入字体、阅读状态筛选、笔记导出、主动离线与本机空间释放，以及统计中的正文分布和跨设备合并。朗读等扩展能力继续作为候选；单书设置仍按用户决定暂缓。具体缺口和建议顺序只在[后续计划](../roadmap.md)维护，避免本页再保留一套过时清单。

借鉴应围绕连续阅读、查找和返回原处的实际体验。保留 Swift 原生 UI/排版与 Rust 核心分工；参考项目采用 Web 或 Lua，不构成更换技术栈的理由。KOReader 的墨水屏节奏不直接作为 iOS 交互标准。

## 实际取得的参考源码

参考仓库放在被 Git 忽略的 `build/references/`，未作为应用依赖或代码引入。仅查看源码，未运行这些项目、安装其依赖或实测其性能；本文的运行行为结论来自代码路径，推测另行标明。

| 项目 | 固定版本 | 本次用途 |
| --- | --- | --- |
| [Readest](https://github.com/readest/readest/tree/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2) | `8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2` | 手机阅读的手势、工具面板、导航与位置保护 |
| [Readest 使用的 Foliate JS](https://github.com/readest/foliate-js/tree/341dc63cda7ad26b31ada4ee905e40b5020da88a) | `341dc63cda7ad26b31ada4ee905e40b5020da88a` | 按 section 加载、预排版、保持可见位置、跳转历史；只初始化了这一个相关子模块 |
| [KOReader](https://github.com/koreader/koreader/tree/1f780ac65ff20f67a997a502828d62a66e1fb488) | `1f780ac65ff20f67a997a502828d62a66e1fb488` | 文档缓存、重排锚点、跳转回退、手势区域；检出根文件与 `frontend`、`spec` |

也实际克隆了 Legado，但其默认分支在 `9bb0569269ed557753fc3866250970de6d454fcf` 只包含公告，没有实现源码，因此不将它作为本次实现证据。

## 值得学习的具体机制

### 1. 点击表达阅读意图，选字、面板和翻页有优先级

Readest 的中间区域切换工具，两侧用于继续阅读；工具已经展开时，边缘点击先收工具并结束本次处理。已有选区可以先消费点击，避免一次操作同时取消选区、关闭面板又翻页。KOReader 也将前进、后退和菜单触区分别注册。

证据：[Readest 点击分派](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/hooks/usePagination.ts#L238)、[选区消费点击](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/hooks/useTextSelector.ts#L1179)、[KOReader 阅读触区](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/modules/readerrolling.lua#L360)。

月读已加入分页左右各 28% 轻点翻页、中央菜单区；工具打开时先关闭，选区操作优先。滚动仍使用原生上下滑动。比例保留给单手试读调整，不建设复杂手势编辑器。

### 2. 工具围绕当前阅读组织，而不是互不关联的按钮

Readest 手机底部用同一个活动面板状态管理导航、字体和配色；再次点击当前项目会收起，进入目录或深层设置时会协调关闭已有面板。字号、行距、边距在阅读中可以直接调整。

证据：[底部动作与面板切换](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/footerbar/FooterBar.tsx#L102)、[手机底部面板](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/footerbar/MobileFooterBar.tsx#L24)、[排版快捷控制](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/footerbar/FontLayoutPanel.tsx#L54)。

月读当前目录/书签/笔记同级，搜索保持独立会话并在药丸与详情之间切换；阅读任务复用一个原生 sheet，完整设置使用页面导航。排版、配色、阅读控制已在统一设置中实现，工具栏翻页箭头已移除。现有交互见[阅读工具](../reader/tools.md)与[弹层布局](../design/reader-panels.md)，扩展候选见后续计划。

同一固定版本的动画时长核对（2026-09-30）：Readest `FooterBar.tsx:222` 用 `duration-300` 同时改变透明度与位移，声明时长 300ms；内部导航、字体、配色面板使用 `transition-all`，组件没有单独声明毫秒数，不能据此编造实测时长。KOReader `readermenu.lua:396` 经 `UIManager:show/close` 直接入栈、移除并请求重绘，这条路径没有按毫秒插值的显隐转场；墨水屏刷新耗时不等于“0ms 动画”。以上仅源码证据，未运行或测量两款参考应用。

### 3. 预加载服务于下一屏，后台工作不能移动正在读的文字

Readest 所用 Foliate JS 会根据视口前方剩余页面加载相邻 section，而不仅检查固定的文件块编号。该版本的一条预加载路径以约五页前方内容、最多八个 section 为预算；这是该引擎的参数，不是月读应直接照搬的数值。

更重要的是：相邻 section 的预加载复用当前布局配置，只给新增内容设置样式；远处的排版工作避开拖动/动画，已临近视口的必需内容优先处理；向前插入内容时补偿位置，后台填充不主动滚回旧锚点。远处视图按距离清理。

证据：[按视口预加载](https://github.com/readest/foliate-js/blob/341dc63cda7ad26b31ada4ee905e40b5020da88a/paginator.js#L3500)、[相邻内容加载与交互避让](https://github.com/readest/foliate-js/blob/341dc63cda7ad26b31ada4ee905e40b5020da88a/paginator.js#L3675)、[视口填充与回收](https://github.com/readest/foliate-js/blob/341dc63cda7ad26b31ada4ee905e40b5020da88a/paginator.js#L3766)。

月读现在会在接近窗口边界时提前请求。滚动交接复用文字视图，并恢复原文锚点与可见行基线；分页保留重叠页面和当前控制器。拖动/惯性/选区期间延后替换，必要的尾部追加临时最多四块，结束后回收至常态三块。已通过视图与行位置回归、跨块翻页/回翻 UI 测试；仍需在真机长时间单手阅读中观察手感。

建议区分四件事：提前读取、准备局部布局、保留当前可见内容、在合适时机应用新窗口。预取预算按可读屏数和内存共同约束；不能仅把“三块”改成“更多块”就当作解决。

### 4. 日常续读、重排定位和主动跳转需要区别对待

KOReader 用内容结构锚点 XPointer 保存位置，并避免把改字号、旋转后算出的临时页位置反写成用户的新阅读位置。Readest/Foliate 的自然翻页或滚动替换当前历史项，显式 `goTo`、进度跳转等加入历史，因此能返回跳转前的位置。

Readest 还对从深链打开某个段落使用预览状态，直到用户主动阅读才允许覆盖续读进度。这里的证据是深链入口，不能推断它所有搜索或引用入口都采用相同策略。

证据：[KOReader 锚点与重排原则](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/modules/readerrolling.lua#L35)、[章节跳转前记录位置](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/modules/readerrolling.lua#L704)、[Foliate 自然阅读更新](https://github.com/readest/foliate-js/blob/341dc63cda7ad26b31ada4ee905e40b5020da88a/view.js#L340)、[主动跳转历史](https://github.com/readest/foliate-js/blob/341dc63cda7ad26b31ada4ee905e40b5020da88a/view.js#L517)、[Readest 深链预览](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/FoliateViewer.tsx#L839)。

月读通过明确导航请求处理目录、搜索、书签和批注，进入临时浏览后只在“从这里继续读”时更新正式续读位置；自然阅读反馈与跳转请求分开。2026-09-28 已在保护原点的基础上加入最多 32 项会话返回/前进历史和百分比跳转。TXT 继续使用规范 UTF-8 锚点，不照搬 EPUB CFI 或 DOM XPointer。

### 5. 小说排版需要页面规则，而不只有字号和行距

Readest 将字号、行距、边距、正文最大行宽等分别传给渲染器。月读已在 2026-09-28 加入卷章与正文样式、段间距、智能缩进、原生字体、边距与最大行宽；保持 Rust 语义和平台度量的分工。当前细节见[正文版面](../reader/reading.md#当前版面)。

证据：[Readest 最大行宽设置](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/FoliateViewer.tsx#L793)。本地对应 `ReadingView.swift` 的 `ReadingTextMetrics`、`attributes()` 和 `ReaderSettingsSheet`。

建议先用长中文小说确定章节标题、段间距、缩进与行宽的默认规则，再提供必要调整入口。规则作用于显示，保留原文与位置映射；不能直接删除空行或改写源文。App/阅读的继承和独立浅深配色现已进入[主题设计](../design/themes.md)，不照抄 Readest 的继承方向。

## 首次打开：源码说明了什么

本次两个参考都不能证明“所有小说都能先显示首屏再完成全文解析”：

- Readest 的 TXT 会先转换为 EPUB。小于等于 8 MiB 的路径会读取整个输入，大文件路径分段解码，但仍需要完成章节内容与 EPUB 生成后返回。普通入口会尝试 Worker，另有回退路径；不能把“有 Worker”当作“已经渐进可读”。[转换入口与小文件](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/utils/txt.ts#L135)、[大文件转换](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/utils/txt.ts#L205)、[Worker 与回退](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/utils/txt-worker.ts#L95)。
- KOReader 的重排文档初始化先 `loadDocument()` 再 `render()`；长加载提供阶段进度，并用磁盘文档缓存加速重开。此处应学习缓存与反馈，不能把它描述为首次边解析边阅读。[打开顺序](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/readerui.lua#L331)、[引擎阶段进度](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/modules/readerrolling.lua#L1300)、[磁盘缓存配置](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/document/credocument.lua#L80)。

月读分别处理首次导入、缓存开书和下一屏读取。当前已落地稳定任务身份、首批短事务提交、独立读连接、可取消队列和暂停恢复；SHA 完成后去重不会覆盖尚未选择的原书续读位置。UI 回归验证了大合成 TXT 在全文完成前可读，具体边界和实测记录见下文链接。

首次边导入边读的当前实现见[渐进导入](../reader/import.md)。

## 日常阅读能力的源码依据

### 目录数据与正文滚动

Readest 的 [TOCView](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/sidebar/TOCView.tsx#L185)接收完整目录，先按卷的展开状态生成可显示条目，再交给 Virtuoso 绘制可见行。KOReader 的 [ReaderToc](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/modules/readertoc.lua#L171)从引擎取得完整 TOC，在这份数据上搜索、折叠与分页呈现。两者都没有把“只绘制可见行”与“滑到边缘才取得下一批目录数据”混为一谈。

月读已改为在准备正文时生成累计字符计数，目录使用已解析章节的完整轻量快照，界面按需创建行；正文尚未解析完时继续明确表达部分目录。已删除每批 40 条及查询时扫描章正文的路径；规则见[阅读工具](../reader/tools.md#章节列表知道读到哪里也能回到原处)。

Readest 所用 Foliate JS 的 [`#preloadNext` / `#loadAdjacentSection`](https://github.com/readest/foliate-js/blob/341dc63cda7ad26b31ada4ee905e40b5020da88a/paginator.js#L3500)保留当前 section 的视图，提前加载邻近 section，前插内容时补偿新增高度；后台预加载避免重新滚到旧锚点。KOReader 的 [`ReaderRolling`](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/modules/readerrolling.lua#L35)通过文档位置与 XPointer 保持重排后的阅读位置。它们支持“有界呈现并保持眼前文字”的原则，但引擎与月读的 TextKit 不同，不能据此断言月读的某次跳动由分片导致；仍需对照真实拖动、减速、换片和重排的时间顺序。

| 能力 | 固定源码中的证据 | 月读当前实现与剩余边界 |
| --- | --- | --- |
| TXT 章节识别 | [Readest 章节规则](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/utils/txt.ts#L732)含楔子、序章、番外、后记及更多编号形式 | 已有常见标题、卷章两级及人工纠错；自定义规则入口尚无，先积累真实漏识别样本 |
| 目录纠错 | [KOReader 自定义目录](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/reader/modules/readerhandmade.lua#L167)可选文字建立目录项并编辑/删除，当前手工目录本身只有单层 | 已有选文新增、改名/层级、排除/恢复、重建并保留人工修正，不再列为整项未实现 |
| 阅读控制 | Readest 的[常亮生命周期](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/hooks/useScreenWakeLock.ts#L10)、[阅读亮度](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/hooks/useScreenBrightness.ts#L22)和[方向设置](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/components/settings/LayoutPanel.tsx#L518) | 已实现常亮、亮度和方向；真实控制中心、锁屏及方向拒绝仍需验证 |
| 快速定位 | [Readest 导航面板](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/footerbar/NavigationPanel.tsx#L87)有进度拖动、位置输入、前后章节与历史 | 已有百分比、前后章、会话历史和临时浏览返回，不恢复已移除的工具栏翻页按钮 |
| 全局与单书设置 | [Readest 设置保存](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/helpers/settings.ts#L63)区分全局和当前书 | 全局排版、配色与即时预览已实现；单书覆盖已明确暂缓 |
| 自定义字体 | [Readest 字体导入](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/components/settings/CustomFonts.tsx#L59)取得字体后注册到可选列表 | 月读目前只有内置原生字体，字体文件导入尚无 |
| 朗读控制 | [Readest 朗读设置](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/components/settings/TTSPanel.tsx#L19)包含播放器与高亮配置 | 月读没有朗读；若选择实施，先做系统语音与播放生命周期，不预先增加朗读统计 |
| 书目组织 | [Readest 书库排序](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/library/utils/libraryUtils.ts#L375)支持标题、更新时间、进度等 | 月读已有正式阅读时间倒序、全书架/单书架文件名搜索和按名称的全部小说入口；更多排序不属于待补齐项 |

## 书架能力对照

继续使用上表固定提交，仅核对本地源码，未运行参考应用。

| 能力 | 源码证据 |
| --- | --- |
| 阅读状态及筛选 | [Readest 状态操作](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/library/components/SetStatusAlert.tsx)包含未读、读完、暂搁与清除状态；[KOReader 状态定义](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/ui/widget/booklist.lua#L371)区分新书、阅读中、暂搁与读完 |
| 书籍详情和自选封面 | [Readest 详情与元数据编辑](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/components/metadata/BookDetailModal.tsx)、[KOReader 书籍信息与自选封面](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/filemanager/filemanagerbookinfo.lua#L510) |
| 批量整理与下载 | [Readest 多选动作](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/library/components/SelectModeActions.tsx)包含状态、下载与分享；[KOReader 收藏多选](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/filemanager/filemanagercollection.lua#L412)包含全选、取消全选和已选数量 |
| 缓存与备份 | Readest 的 `CacheManagerWindow.tsx`、`BackupWindow.tsx` 分别提供缓存清理与备份/恢复；这些能力不意味着月读需要新增同样的管理中心 |
| 书库笔记整理 | [KOReader 书库动作](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/frontend/apps/filemanager/filemanagercollection.lua#L1739)可从所选文件浏览书签、调用批注导出 |

月读的实际目录结构、正文 SHA 与文件分层继续按自己的数据约定设计，不能把参考应用的虚拟收藏模型直接套入真实文件树。差距及建议顺序见[书架扩展候选](../roadmap.md#书架扩展候选)。

### 书籍与容器的视觉区分

同一固定版本中，Readest 的 `BookshelfItem.tsx` 分别调用 `BookItem` 和 `GroupItem`：单本显示一张封面；分组网格显示最多四本的小封面，分组列表则是多本封面的横向预览与组名，点击进入组内。组可能来自书架或元数据规则，不等同于月读的真实目录。其单本选中遮色和勾号均位于封面内，书名与进度区域不加整块选中色。

KOReader 的 `FileChooser:getListItem` 区分文件与目录，目录名附 `/`；`onMenuSelect` 对文件调用打开动作，对目录进入子路径。此处依据的是已检出的文件浏览源码，没有运行封面浏览插件。月读可以借鉴“单本／容器使用不同表现和打开动作”，继续保持真实目录语义；不据此增加虚拟分组。

后续实施顺序只维护于[后续计划](../roadmap.md)，月读实际测试及设备限制只维护于[验证记录](../engineering/verification.md)。不以参考源码存在某个功能推断其性能或所有平台均已验证。

## 阅读统计对照

核对日期：2026-09-30。仍使用本文记录的 Readest `8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2` 与 KOReader `1f780ac65ff20f67a997a502828d62a66e1fb488`，不把默认分支的新功能当作固定版本事实。Readest 使用本地源码；KOReader 稀疏检出未包含统计插件，本次另行取得同一提交的 `plugins/statistics.koplugin/main.lua` 作只读核对。另参考当日官方用户指南，注明出处。未运行两款应用或测量其统计误差。

Readest 本轮核实的是计时、数据、同步和阅读速度估计路径，不能据此断言它有与月读提案相同的完整统计首页。KOReader 则在统计插件中有明确的报表入口及字段。

| 参考能力 | 已核对证据 | 对月读的启发与取舍 |
| --- | --- | --- |
| 周/月/年与单书报表 | KOReader [时间范围入口](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L1304)包括按周/月的书目、按日/周的时长；[单书统计](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L1615)含本次/今日/全书时长、阅读日期、平均值 | 采用同一个范围筛选联动图表和书目，不照搬很多菜单入口；日期和单书详情承载细指标 |
| 日历与一天内的阅读分布 | KOReader [日历配置与小时直方图](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L1148)、[当天时间线入口](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L1287) | 补充日期详情中的小时分布和当天书目，单书日历是月读的派生查询建议；不把它写成已实测的参考页面 |
| 正文阅读地图 | KOReader [官方指南 Book Map](https://koreader.rocks/user_guide/#bookmap)描述已访问部分、页停留及书签/笔记定位 | 补充月读章节/正文分布图；TXT 用稳定正文范围，不照搬页码。指南未证明它能精准识别“读了几遍”，月读仍需自己的回看口径 |
| 有界停留和前后台处理 | Readest [参数](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/types/statistics.ts#L23)为闲置/单事件 120 秒、短事件 3 秒，[核心](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/services/statistics/trackerCore.ts#L22)结算片段；KOReader [翻页结算](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L2560)及休眠处理 | 借鉴防挂机与明确暂停；月读不能按短页事件直接丢弃连续慢滚的真实时间，也不把周期落盘当成新交互 |
| 样本不足不估计速度 | Readest [中位停留时间](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/services/statistics/statisticsDb.ts#L144)读取最近最多 50 条、少于 5 条返回空值 | 采用“无可靠样本就不显示”的原则；速度保持候选，不以参考阈值冒充月读准确性，也不扩展为预计读完时间 |
| 书签与笔记数量 | KOReader [单书统计尾部](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L1668)展示标注、笔记数量 | 单书详情可链接已有工具；当前存量与期间新增不同，不放首页当成阅读成效 |
| 同步阅读事件 | Readest [事件写入](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/services/statistics/statisticsDb.ts#L118)和[同步](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/services/statistics/statsSync.ts) | 采用稳定片段身份与幂等合并；月读继续用正文 SHA 和 CloudKit，不新增参考项目的账号或外部统计服务 |
| 夜间跨日归属 | KOReader [一天起始配置](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L1185)及[官方指南](https://koreader.rocks/user_guide/)说明可调整时间线，日历可选沿用，其他报表不全受影响 | 不采用自定义起点。月读已确定阅读发生地自然日、午夜分界和系统周起始；全部相关查询共用日期口径 |
| 已完成书籍冻结统计 | KOReader [可选冻结设置](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L1107)；单书页面也区分累计时间与去重页上的封顶时间 | 不采用冻结：用户希望看重复阅读，读完的书仍应增加回读时长；不把参考中的两种“时间”混成一个总计 |

补充内容已进入[统计设计](../design/statistics.md)与[实施计划](../plans/statistics.md)：日期小时分布、单书阅读日期/平均值和正文地图有明确位置；速度估算保持候选。已确定自然日，不采用凌晨跨日设置或预计读完时间；当前没有朗读功能，不把参考项目的朗读统计加入月读规划。

### 停留、快滑、慢滚与回看

核对日期：2026-10-01。沿用上表固定提交，检查统计事件的产生、结算和汇总源码；未运行参考应用，不把源码规则当作实测误差或真实注意力判断。

| 场景 | Readest | KOReader |
| --- | --- | --- |
| 很快离开一页 | 默认丢弃不足 3 秒的页事件，包含该事件的时长 | 默认不足 5 秒不保留页时长，门槛可设置 |
| 静止停留 | 默认闲置定时器为 120 秒；单事件另有 120 秒封顶 | 默认结算一页时最多记 120 秒；这里核实的是结算上限，不是同一套闲置定时器 |
| 连续滚动 | 接收阅读器报告的页信息；同页更新保持当前事件，换页结算再开始 | 位置更新只在页号变化时调用换页统计；同页不拆开计时 |
| 回到读过的页 | 新事件继续增加时长，累计已读页数按页号去重 | 每页可有多条访问记录，总时长相加，已读页数按页号去重 |
| 隐藏/关闭或休眠 | 页面隐藏/关闭结算；隐藏时清除闲置定时器 | 休眠时落盘并标记暂停，恢复时扣除暂停时长；关闭时结算 |

证据：Readest [默认参数](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/types/statistics.ts#L33)、[页事件与短时过滤](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/services/statistics/trackerCore.ts#L29)、[闲置及页面生命周期](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/app/reader/components/ReadingStatsTracker.tsx#L123)、[累计时长与去重页数](https://github.com/readest/readest/blob/8d76d3fc1f0e26f8c5dbe1fc343f9d69256eefc2/apps/readest-app/src/services/statistics/statisticsDb.ts#L131)；KOReader [默认参数与聚合 SQL](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L28)、[滚动及翻页结算](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L2554)、[暂停/恢复](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L2693)。

这些统计路径以页为单位，未看到按滚动速度分类或稳定正文范围的停留聚合。Readest 的闲置定时器由页信息更新路径重置，不能概括成已验证所有正文交互。KOReader 还按总页数比例映射重排前后的页统计（[页统计视图](https://github.com/koreader/koreader/blob/1f780ac65ff20f67a997a502828d62a66e1fb488/plugins/statistics.koplugin/main.lua#L435)）；这不等于精确的正文字符覆盖，也不证明一个范围被完整读了几遍。

月读已确认并接入：保留 120 秒闲置规则，以原文范围连续可见 3 秒作为估算覆盖门槛，慢滚重叠范围延续停留，回看时长增加而覆盖取并集。不照搬短页事件丢弃规则去减少总阅读时长。覆盖不因检查点或重复回调重复累计，独立回看次数仍需处理边界微调；当前规则见[小说详情](../design/statistics.md#章节覆盖计算)。不新增速度估算、摄像头检测、阈值设置页或独立阅读轨迹。

## 锁屏媒体与实时活动的区别（2026-10-24–25 调研）

本节由当时只读公开资料压缩整理，2026-10-30 未重新核对网页，也未安装参考 App。不能将未查到描述写成产品没有该能力；这不是月读新增实时活动的承诺。

- Audible 的官方资料分别描述锁屏播放控制与睡眠定时 Live Activity：前者继续播放，后者展示倒计时并可进入定时。两者不是同一系统组件。[播放](https://help.audible.com/s/article/listen-in-the-app?language=en_US)、[定时](https://help.audible.com/s/article/use-timer?language=en_US)。
- Book Tracker 官方教程描述阅读计时 Live Activity，可显示已用时间并暂停/继续。这是计时，不证明小说正文阅读需要持续上岛。[官方教程](https://booktrack.app/tutorial/how-to-use-live-activity-with-the-reading-timer/)。
- Android 的前台通知、厂商“灵动岛”、主屏小组件与 iOS Live Activity 分开记录；媒体键支持也不证明锁屏卡片提供所有操作。系统朗读的候选范围见 [#17](https://github.com/suxiaoshao/moonread/issues/17)，不由竞品列表直接决定实现。
