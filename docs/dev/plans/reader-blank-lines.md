# 正文空行：显示投影与原文坐标评估草案

状态：已实施，本地定向验证通过，未做真机验收。2026-10-15。用户已确认显示投影、分段映射与 Rust 窗口契约一并实施；下述评估部分保留为设计依据，复制契约以已定条款为准。

## 建议

建议改为**删除显示文本中的语义空白段，保留规范正文，以一份随显示文本持有的分段映射连接两者**。保留 TextKit 1、原生选字和现有分页器，不换渲染引擎。这比继续向零高度片段补充特殊处理更适合当前需求，但它是一次有边界的渲染数据重构，不能只改 `TextCoordinates` 的两个函数。

具体边界是：Rust 负责原文、段落语义和可读窗口定位；Swift 构造一个不可变的显示投影，包含显示文本、对应原文范围、唯一坐标映射。`UITextView`、`TextPage` 和预览持有该投影或其切片，不再从显示字符串反推原文坐标。持久化、SHA、搜索、批注、书签和 AI 工具仍使用规范正文 UTF-8。

建议 **fix forward，不立即整包 revert PR #13**。当前已有正常文本的原生画面和回归证据，未见本文范围内的数据损坏证据；已知空屏问题必须作为后续 PR 的交付门槛，不能把当前 main 当作空行功能已经完整验收。若替换无法及时完成而必须交付存在长空白区的阅读场景，应先交付独立的窗口推进修正；连这一修正也无法验证时，再退回此前空行仍占高的显示行为。此次评估不执行修复或回退。

## 评估基线与证据边界

- 当前工作区为 `claude/reader-blank-lines`，HEAD `67923bf`；本地 `origin/main` 是用户给出的 `03dcdb7`。`git diff 03dcdb7 HEAD` 为空，文件树一致，因此下面的源码结论适用于该合并版本。未切分支、未更新引用。
- [现有排版规则](../reader/reading.md)、[阅读工具契约](../reader/tools.md)是当前产品边界。本方案不更改“空行只呈现段间距”和“原文不改写”。
- 本文“原文坐标”指 Rust 的**规范正文 UTF-8**，不是原 TXT 文件的编码字节位置。`crates/moonread-core/src/text.rs::decode_chunks` 已有去初始 BOM、CRLF/CR 转 LF 的规范化；本方案不再改变它。
- 现有运行事实仍只以 [verification.md 的空行条目](../engineering/verification.md#2026-10-15-正文空行显示投影与长空白窗口)为准。本文不把代码推断写成新的测试通过记录。
- 用户提供的评论编号 `4281238727` 未在本轮重新拉取正文；下面独立检查了相关代码链路。此次没有重跑其复现。

## 现状的问题在哪里

零高度本身不是错误：有限窗口中的原文字符可以保留，原生选区天然包含空行，原文坐标转换也简单。代价是 TextKit 仍然管理这些片段，所有读取“可见文字”的入口必须额外理解隐形字符。当前实现已形成以下耦合：

- `ReadingTypography.swift::text/visibleCharacter` 标记 `.blank`、设置极小字体和行高，并在定位时跳过这些字符。
- `ReadingView.swift::ReadingLayoutManager` 把片段几何归零；`closestPosition`、书签标记、滚动报告、恢复及预览各自修正可见位置。
- `TextPage` 分开可见行数与原生渲染行上限，合并纯空白页，另外维护首个可见偏移。
- `ReadingController.rebuild` 用普通阅读回调推动全空白窗口。

最后一项存在可从代码确认的控制流缺口：

1. `ReadingView.swift:1148` 在无封面、非 EOF、非 prepared tail 的全空白窗口发出 `report(window.end - 1)`，只在 rebuild 尾部执行。
2. `ReaderSession.swift:212` 的 `moved` 把它当实际阅读位置：更新 anchor、章节、安排保存，再按当前位置所在块读取附近窗口。
3. Rust `progressive.rs:1210` 仍只取目标块前后一块。新窗口可能仍然全空白，或其起点已越过旧空屏的起点。
4. `ReadingView.swift:1022` 的 `replaceContents` 要保留旧屏幕位置。滚动时没有可见字符就回退到字符 0，得到旧 `window.start`；分页时保留旧 `page.start`。它们不在新窗口内时，恢复旧 window 并报告旧位置。即使一次替换成功，replace 路径也没有下一次全空白推进。
5. `ReaderBlankLineTests.testAllBlankLoadedWindowRequestsNextOriginalOffsetWithoutClaimingEOF` 只收集 `changed` 回调，未把它接入真实 session、Rust frame 和下一次 configure，所以证明不了脱离空屏。

开头全空白还需单独覆盖：`hasCover` 定义是 coverTitle 非空且 window.start 为 0，并不等于“正在看封面”。因此真实开书的起始窗口可能始终被 `!hasCover` 排除，而当前推进测试没有传入 coverTitle；翻离封面也不能仅依赖这段 rebuild 回调。

这不是只换成 `report(window.end)` 就能解决的问题。预取、跳过没有显示内容的区间和保存已读位置应分开；`end - 1` 也不是一般成立的 Unicode 字符边界。另一个必须覆盖的情形是“窗口内仍有前面的正文，后面若干块都是空白”：仅保证窗口不全空白，仍可能没有可翻到的下一页。

## 坐标入口盘点

结论：实际的 UTF-16/UTF-8 数值转换集中在一个类型、四个生产调用文件中，但映射实例和文本生命周期并未集中。`TextCoordinates(textView.text)` 在当前恒等文本下正确，换成压缩显示文本后就会静默失去被省略区间。应把这些调用视为需要封闭的旁路，不能只搜索手写字节运算。

下表位置均相对仓库根，行号对应评估基线；范围用函数名定位。

| 场景 | 当前源码入口 | 替换时的要求 |
| --- | --- | --- |
| 基础映射 | `ios/Moonread/Reader/Rendering/TextCoordinates.swift:4` | 目前每个 UTF-16 边界保存规范 UTF-8 偏移，仅支持封面零字节前缀；增加删除区间、边界方向及 range API，不能再用一份普通单值数组处理所有端点 |
| 字体/段落属性 | `ReadingTypography.swift:76` 的 `text` | 目前属性 range 按原文 UTF-16 直接作用于同长字符串；应先生成投影，再把保留段的属性施加到对应显示范围 |
| 原生选字、跨页批注起终点 | `ReadingView.swift:684` 的 `editMenuForTextIn`、`selectionMenu` | 通过 `textCoordinates` 转换，但后者会重建恒等映射；必须读当前文本视图持有的映射，并裁到本页/正文可选范围 |
| 点批注、恢复整段选区 | `ReadingView.swift:435` 的 `annotationIDs`、`:469` 的 `showAnnotationMenu` | 点命中用显示字符对应的原文区间；原文批注范围反投影为空时不能强行高亮邻字；跨段范围可连续映射 |
| 高亮与搜索命中 | `ReadingView.swift:766` 的 `decorate`、`:898` 的 `targetRect` | 目前 `end = base + mapping.byteCount` 默认字符串字节数等于原文覆盖；改读 sourceRange，区分定位一个点与投影一个范围。只命中被省略空白时允许定位，但不捏造可见高亮 |
| 搜索结果摘要 | `ios/Moonread/Reader/UI/ReaderTools.swift:921` 的 `searchExcerpt` | 摘要是 Rust 返回的独立原文片段，当前 TextCoordinates 恒等映射应保留；不要全局默认删除其空行或混用书内绝对坐标 |
| 无障碍“查看标注”命中 | `ReadingView.swift:580` 附近的可见 glyph range 转换 | 同样走视图映射，不能重新从 page string 构造；范围排除封面和 lookahead |
| 书签图标 | `ReadingView.swift:805` 的 bookmarkPositions 与 `ReadingTextView.layoutSubviews` | 原文点投影到可见行；移除 visibleCharacter 修补。记录身份不能因绘制到相邻字而改写 |
| 书签按钮状态/增删 | `ReaderSession.swift::toggleBookmark/refreshBookmark`；`ios/Moonread/Data/ReaderService.swift:288` | 目前 ID 和 hasBookmark 都按原文 offset 精确相等。应保持新书签以可见原文字节为锚；旧/外部产生的空白内书签仍按自身 ID 操作，不能把“画在同一行”误当同一记录，也不能自动迁移或合并 |
| 位置报告与存储 | `ReadingView.swift:667` 的 `reportPage`、`:1208` 的 `reportScroll`；`ReaderSession.swift::moved` | 报告可见原文锚点，存储层继续原文坐标；窗口查找游标不能进入这条保存/统计通道 |
| 截取视口与恢复 | `ReadingView.swift:856` 的 `captureViewport`、`:875` 的 `matchingRestoration`、`:927` 的 `applyNavigation`、`:918` 的 `visibleWindow` | 保留原文锚点与 lineY；页内是否可见要用显示切片/可见锚点，不能仅以原文所有权范围判断。旧原文点仍能定位，旧排版页缓存须失效 |
| 滚动追加与替换 | `ReadingView.swift:1003` 的 `appendScrollContents`、`:1022` 的 `replaceContents`、`:881` 的 `replaceNavigationContents`、`:1068` 的 `rebuild` | 新旧文本、映射及 paragraph 属性要一起更新。当前按 previous.end 切原文 UTF-16 后追加 styled substring 的做法必须改为切投影；交互期间保留原文锚点及可见基线 |
| 分页源切片与前后排版 | `ReadingView.swift:1335` 起 `TextPage.paginate/paginateBackward` | 当前从 source.string 重建映射，并多次用 `base + source.string.utf8.count` 推导 end；全部改为传递投影切片。页面 sourceRange 长度不再等于显示字节长度 |
| 页首、续段、预读 | `TextPage.firstVisibleOffset/layoutText/contextualized` | 页的显示切片、原文所有权、首个可见原文位置须明确；`.readingParagraphStart` 仍是原文坐标。约 512 UTF-16 的 lookahead 从显示投影切片取得，携带映射但不纳入本页选择、统计、复制和无障碍 |
| 封面前缀 | `ReadingView.swift:831` 的 `styledScrollText`、`:627` 的 `updateScrollCover`、`:677` 的 `textCoordinates` | 附件+换行的 2 UTF-16 单元为无正文范围的 synthetic segment。当前 `dropFirst(bodyStart)` 按 Swift Character 删除，仅对固定两个单元偶然足够；不要推广为分段算法 |
| 应用内“拷贝/全文搜索” | `ios/Moonread/Reader/UI/ReaderScreen.swift:574` 的 `selectText` | 拷贝与选中文字搜索均按完整选区原文范围异步调用唯一 Rust 显示文本接口，不经 ReaderService.textRange 取未经投影的原文；搜索算法及现有多行查询拒绝保持不变 |
| 原生 copy、全选、系统菜单 | `ReadingView.swift:1655` 的 ScrollReadingTextView.copy/selectAll、`:1672` 的 PageReadingTextView，以及原生 suggestedActions | 滚动 copy 直接 substring，分页未覆写 copy。按已定契约 copy 本就取显示文本，只需保证封面与预读不被带入；selectAll 仍选显示正文；系统查询/翻译/朗读/分享默认消费显示文本，不应伪造 UITextInput 字符范围来塞回空行 |
| AI 选区文本 | `ReadingView.swift:147` 的 `aiSelectedText`；`ReaderScreen.swift:354` 的 `aiContext` | 当前 offset 经过转换，excerpt 却直接 substring。范围由选区映射得到原文包络，excerpt 经同一 Rust 范围显示接口异步读取，排除封面和 lookahead；AI 的其他原文读取工具无需显示坐标 |
| 可见范围/统计/AI 当前页 | `ReadingView.swift:136` 的 `statisticsRange`；`ReaderScreen.swift::aiContext` | 分页现在临时 TextCoordinates(text.text)；必须复用切片映射并裁掉预读。可见字之间的原文空白可落入范围包络，但跳空白的查找过程不能生成阅读时长/访问记录 |
| 正文及预览无障碍文本 | `TextPage.makeTextView/PageController.update`、`ReadingController.configureAccessibility`；`ios/Moonread/Settings/ReadingPreview.swift:125` | 读显示正文；不读省略空行、封面占位字符和预读。configureAccessibility 在正文状态会将 accessibilityLabel 设为 nil，不能只凭 makeTextView 曾赋本页 label 就认为后文已隔离。辅助功能位置值如仍表示原文 offset，要继续来自映射 |
| 设置预览 | `ReadingPreview.swift:137` 的 `visibleAnchor`、`:151` 的 `layoutSubviews`、`:177` 的 `updateDecorations` | 当前单独构造 TextCoordinates(window.text)，需复用同一投影构造器；预览位置、标记与主阅读一致 |

没有发现其他生产文件独立执行书内 UTF-16↔UTF-8 转换。Rust 文本范围、章节偏移、搜索索引、AI 工具参数、SwiftData 记录和进度百分比使用原文坐标，并不需要变成显示坐标。`ReadingPreview` 生成示例标记时用原字符串前缀的 utf8.count，也属于合法的原文计算，不能机械替换。

最关键的禁止项：投影建立后，禁止用 `TextCoordinates(displayText)`、`sourceStart + displayText.utf8.count`、显示 substring 代替原文读取。保留明确的恒等映射构造器，供搜索摘要等确实没有投影的文本使用。

## 建议的数据边界与映射语义

### 一个投影对象，一份映射

可以扩展 `TextCoordinates`，另用薄的 `ReadingText` 值对象把它与文本绑定；不建议让一个坐标工具同时负责数据库、加载和排版。

- 投影输入：一个版本确定的 ReadingWindow/原文快照及 Rust 段落语义。
- 投影输出：显示字符串/富文本、覆盖的规范原文范围、`TextCoordinates` 分段映射、可选择的正文 display range。切片操作必须同时切文本与映射；不能在各调用点自行重建。
- 保留段描述原文 UTF-8 range 与显示 UTF-16 range；省略段记录原文 range 在显示侧收缩到的边界。Unicode 转换仍在保留段内处理，不能用固定字符/字节差值替代 UTF-8/UTF-16 解码。
- 封面段只有显示长度；正文预读段有真实映射，但由正文可选范围排除。禁止让 synthetic segment 参与持久化选区。
- 只删 Rust 明确判定为 `.blank` 的整段，包括该空白段的分隔符；保留可见段自己的 LF、原有缩进、空格、制表符、标题和续段。不要仿照其他阅读器对每个正文段做 trim。
- 分段查找可用二分，段内保留现有字符边界索引。空间仍受有限窗口约束；不建立全书显示字符串或全书逐字符映射。减少 TextKit 空片段成本是合理预期，但性能收益未测量。

显示边界到原文并非数学上的一一可逆映射。删除区间的两端会落在同一个显示边界，API 必须显式表达用途，不能靠所有调用方传不同的 +/-1。

### 原文点、范围与显示边界

| 操作 | 建议语义 |
| --- | --- |
| 原文点位于保留字符 | 映射到对应显示字符；落在 UTF-8 scalar 中部先按现有规则归到 scalar 起点。原生选区的扩展字素边界另由 TextKit/范围校验保证 |
| 导航点位于被省略空白 | 默认向后找下一可见原文字符；完整书尾没有下一字时回到前一个可见字符。向前翻阅请求使用反方向查找。全部无正文时返回无可见目标，不能伪造字符 0 |
| 原文范围转显示范围 | 与保留段相交后投影；纯空白范围得到空范围，不把搜索或批注移贴到邻字。导航落点和高亮范围必须是两个操作 |
| 显示选区转原文范围 | 非空选区起点用 downstream（跨删除缝隙取下一保留段起点），终点用 upstream（取上一保留段终点），得到最小连续原文包络。零长度选区不能把两种 bias 组合成倒置范围 |
| 显示锚点/保存位置 | 使用其对应可见原文字符的起点；末端插入位置是合法边界，不应一律减 1。EOF 与最后一个可见字符不同 |
| 超出当前投影范围 | 通知调用者需要另一窗口或明确裁剪；不要用静默 clamp 把“窗口不包含目标”伪装成“定位成功” |

例：原文 `甲\n\n \t\n乙`，显示 `甲\n乙`。乙前的同一显示边界同时对应“甲段结束”和“乙段开始”。只选甲段不应把之后的空白算进原文范围；只选乙不带前导空白；选区从甲跨到乙时，原文包络（用于批注、书签、AI 附件范围）包含中间所有空行，但复制文本为显示的 `甲\n乙`。

**已定复制契约（2026-10-15 用户确认，评审后统一范围读取）：复制按屏幕显示。** 应用内拷贝、原生 copy、选中文字搜索和 AI excerpt 以完整原文选区包络（含跨页扩展）异步调用唯一 `display_text_range`；该接口与显示投影使用同一组已确认空白区段，省略空行、保留可见段分隔 LF，不拼接当前窗口或只取末页片段。单屏也走同一路径。选择任务由会话持有，替换或离页取消，迟到结果不写剪贴板、不打开搜索／AI。显示返回值上限沿用 1MiB，但省略空白不占额度；超过上限明确失败，不截断。系统查询／翻译／朗读／分享继续消费原生显示选区，不重写 text(in:) 或增加第二套 UITextInput 坐标。搜索算法及多行查询拒绝保持不变。批注、书签及 AI 附件范围仍保留原文包络。


### 分页的覆盖与所有权

分页仍对显示 UTF-16 做原生布局。每页持有显示切片、源范围和映射切片；正常行数即原生渲染行上限，可移除为零高度片段增加的双计数和 `coalescingBlankPages`。真实 lookahead 仍然必要，不能随空行机制一起删掉。

建议内部页间删除缝隙归前一页，书首省略段归第一页、书尾省略段归最后一页：以“下一页第一个保留字符的原文起点”作为相邻页共同源边界。这样源所有权可以连续且不重叠，但它**不等于该页可见字符范围，也不等于复制范围**。这套归属应由投影切片统一产生，不能在正向、反向分页各自猜测。

需要替换的旧不变量是 `page.end - page.start == page.text.string.utf8.count` 以及 `pages.text.joined == window.text`。新不变量为：显示切片完整、不重不漏地覆盖投影；源所有权按约定分区；每个保留字符可映射回同一原文；原文省略区间明确可解释。`firstVisibleOffset` 可以由投影首个保留字符直接取得，不再扫描 attributed blank。

页缓存携带投影/排版版本及原文版本，变化后重排；现有版本字段可继续利用。`ReadingLayoutManager` 保留批注绘制职责。末端没有源字符的 extra line fragment 是否仍需压低，应单独按 EOF 画面验证，它不属于本次被删除的“原文空白段”，不能以重构为由盲目连带修改。

## Rust 窗口契约不能只写“至少一个可见段”

当前窗口由连续三块原文构成，手势期间最多四块；`ReadingWindow.text` 直接 joined。仅在 Rust 中无限扩展窗口直到遇到正文，会让任意长空白进入 Swift 内存，也会延长 read lock/共享 actor 占用，破坏已有开书性能边界。仅跳到远处非空块，又会触发当前 session 和 controller 的锚点包含性检查。

建议分清三个量：**用户原文锚点、窗口查找游标、实际解析到的可见锚点**。接口名字可按实现简化，但不能把三个量都塞进 `anchor` 或 `report`。

1. Rust 对请求位置和方向解析可见目标，再围绕目标提供有限窗口，并返回解析结果。结果区分“可见内容就绪”“已准备前缀内暂时没有后续可见内容”“完整正文已结束/完全无可见正文”。已有 paused/failed 状态继续独立处理，不能把未导入内容当 EOF。
2. 初次打开、目录/书签跳转及恢复可以解析空白中的原文点。Session 接受结果时原子发布窗口和显示目标；此动作本身不写已读位置、不创建临时浏览历史、不调用 moved。确认显示/用户阅读后的保存仍走既有语义。
3. 连续阅读在可见窗口边缘请求对应方向的内容。只看到前面的正文不代表向前可继续；不能只检查 `paragraphs.any(nonblank)`。禁止让“需要下一窗口”的事件伪装成“读到了 window.end-1”。
4. 远距离跳过空白时，普通保持旧视口的 replace 与解析后定位使用不同的明确入口；后者不能被旧可见位置包含性 guard 拒绝。返回/取消浏览保留原来的原文锚点与视口，不因查找结果污染 origin。
5. 短空白仍在普通连续窗口内。极长空白不要求窗口携带查找起点到终点的全部字节。连续阅读要能把空白两侧的可见片段接入同一投影，保持前一段基线并让分页填满；不能简单重定位到后一块，制造内部短页或滚动跳动。建议加载结果返回有限源片段及明确的 omitted blank ranges，三/四块约束改为已载荷的有界预算，缺口不占文本载荷。只有 Rust 已确定为空白的区间可以省略，未知/未准备区间不能当空白跳过。
6. 查找不得在一次同步 frame 调用中持锁扫描任意多块。可以在导入时为块/段记录可见性摘要并索引下一/上一候选，或采用有界、可取消的增量查找；前者更适合反复经过长空白区。若增加 schema，按开发约定直接调整，不为旧开发缓存做迁移兼容。具体结构应在实现前以现有分块/段落扫描器为基础确认，不能另造全文副本。
7. “空白”必须是完整语义段的判断。一个跨块长段的某个片段恰好全是空格，并不自动等于整段空行。现有 `reading_layout::paragraphs` 只看已拼接窗口并标记 continuation，替代方案须覆盖这个边界，避免删掉正文段的原始空格。导入尚未确定段尾时保守处理，或由 Rust 扫描器提供已确定的段语义。

这里确实比“改两处坐标函数”多一个数据结构变化：`ReaderService.swift::ReadingWindow.text` 当前把 chunks.joined 当作连续原文；若返回跨空白缺口的片段，必须显式区分 loaded spans 与 source coverage，不能无声改变该属性的含义。Swift 投影从这些有绝对 UTF-8 范围的片段建立唯一显示映射，Rust 不需要另建 UTF-16 映射。普通无缺口窗口是同一结构的简单情形，不保留第二条恒等正文渲染路径。这是为了同时满足有限内存和连续排版，不建议省略后再靠翻页补丁修补。

完全空白的已完成书没有可见页，不应构造一张需要再自动前进的空白 TextPage；可使用已有封面/完成状态承载结果。对未完成的全空白前缀，继续已有就绪等待、暂停及错误流程。`ReaderSession.updateOpening` 目前只看 window/settings 非 nil，publishFrame 又拒绝空 chunks，这两个入口也必须随新结果类型一起调整，避免“数据存在但没有可显示正文”被当作 bodyReady。

## 参考阅读器源码

只比较读取到的源码，不运行这些项目，也不把它们的坐标契约直接当作月读的契约。

### legado

本地 `build/references/legado` 的 `9bb0569` 只有 README 公告，没有所需源码，无法从该目录核对。补查的是公开的 **LegadoTeam/legado master**，不是声称本地原仓库仍有实现；在线分支并未固定为本地 checkout，检索日为 2026-10-15。

- [`app/src/main/java/io/legado/app/help/book/ContentProcessor.kt`](https://raw.githubusercontent.com/LegadoTeam/legado/master/app/src/main/java/io/legado/app/help/book/ContentProcessor.kt)：正文可先经规则替换/重分段等处理，随后按行 trim，仅加入非空段，并为正文添加配置缩进。空行在进入排版列表前已经不存在。
- [`app/src/main/java/io/legado/app/help/book/BookContent.kt`](https://raw.githubusercontent.com/LegadoTeam/legado/master/app/src/main/java/io/legado/app/help/book/BookContent.kt)：textList 以单个换行拼接，表示处理后的章节内容。
- [`app/src/main/java/io/legado/app/ui/book/read/page/provider/TextChapterLayout.kt`](https://raw.githubusercontent.com/LegadoTeam/legado/master/app/src/main/java/io/legado/app/ui/book/read/page/provider/TextChapterLayout.kt)：接收 BookContent.textList；chapterPosition 由已排文字长度及段落分隔累计。
- [`app/src/main/java/io/legado/app/ui/book/read/page/entities/TextChapter.kt`](https://raw.githubusercontent.com/LegadoTeam/legado/master/app/src/main/java/io/legado/app/ui/book/read/page/entities/TextChapter.kt) 的 getReadLength/getPageIndexByCharIndex 与 [`app/src/main/java/io/legado/app/model/ReadBook.kt`](https://raw.githubusercontent.com/LegadoTeam/legado/master/app/src/main/java/io/legado/app/model/ReadBook.kt) 的 durChapterPos/setPageIndex：按章内排版字符位置恢复页；后者还存在标题长度与正文锚文本的恢复处理。

可借鉴“先生成显示段落再排版”。不能据此省掉月读的源映射：这条路径的进度基准是处理后的章内字符，不是月读按 SHA 关联的规范原文 UTF-8。它处理标题/内容变化时另作恢复，也说明显示文本坐标不能直接替代持久化原文坐标。

### KOReader / crengine

本地 KOReader 为 `1f780ac`，base 子模块未展开。`build/references/koreader/frontend/document/credocument.lua::setTxtPreFormatted` 设置 crengine.file.txt.preformatted；`frontend/apps/reader/modules/readertypeset.lua` 提供 TXT 自动检测布局开关，切换建议重载。`frontend/apps/reader/modules/readerrolling.lua` 保存 last_xpointer。

补查的 [`crengine/src/lvxml.cpp`](https://raw.githubusercontent.com/koreader/crengine/master/crengine/src/lvxml.cpp) 中，LVTextParser 把 TXT 构造成 FB2 式文档树；自动格式路径识别空行分段，DoEmptyLineParaImport 跳过段首空行；预格式路径则逐行生成 pre 或 empty-line。AddPara 合并行并整理空格。**并非所有模式统一删除空行**。这支持“源文本与排版文档分离”，但位置依赖生成文档的 XPointer，不能直接提供月读所需的原文 byte 双向映射。

### Readest / foliate-js

本地 Readest 为 `8d76d3f`，内含 foliate-js `341dc63`。

- `build/references/readest/apps/readest-app/src/utils/txt.ts::TxtToEpubConverter/formatSegment`：TXT 生成 EPUB/XHTML；段落按连续换行拆分，trim 后丢弃空段并拼为 p。章节识别及后备分章也作用于转换文本。
- `build/references/readest/packages/foliate-js/view.js::getCFI/resolveCFI` 与 `epubcfi.js`：阅读位置和选区由章节文档 DOM Range 与 CFI 连接。

本地 foliate-js 没有独立 TXT 转换器；此组合由 Readest 负责 TXT→EPUB，再交 foliate 排版。它同样没有在上述路径中保留 TXT 原始字节映射。可以借鉴独立显示文档，不应照搬整本转换、trim 正文或改为 CFI 持久化。

三个参考的共同启示是**原文件、显示文档、保存位置可以有不同表示**；没有一个已读路径证明“删空行后仍按原 TXT UTF-8 保存位置”能免去映射设计。

## 改动范围与取舍

| 方案 | 范围与收益 | 风险/结论 |
| --- | --- | --- |
| 保留零高度，修窗口推进 | Rust frame/Session/Controller 窗口契约必须修；其他零高度路径基本保留 | 短期成本最低；长期仍要维护隐形片段、命中修补和双行数。适合作为紧急修复，不是首选长期边界 |
| 显示投影+分段映射 | 上述窗口修正，加 TextCoordinates、ReadingTypography、ReadingView/TextPage、ReadingPreview、ReaderService 的窗口载荷及少量选区/AI/复制入口；必要的 Rust 可见性摘要及 UniFFI 结果变化 | 一次性范围中等偏大，但复杂性集中、TextKit 只处理可显示段落。首选；风险集中在端点 affinity、分页切片及原文访问，均可做确定性测试 |
| 自定义 glyph null/control、特殊 typesetter 或更小字号隐藏 | 换一种方式留住隐形字符 | 仍有命中、边界和生命周期问题，不能解决窗口推进；无明显更简单优势，不建议 |
| 在规范化/存储时删除空行，或整体转 HTML/换引擎 | 能省去局部源映射，或使用 DOM 位置 | 前者改变 SHA/正文和所有已存范围，后者扩大渲染、选字及位置契约；均超出当前问题，不建议 |

推荐方案也可视为第三种更明确的分层：保留 TextCoordinates 作为映射算法，用 ReadingText 把“显示文本与映射不可分离”落实到所有权，而非让每个调用方记得额外传一份 offset 表。不引入通用任意文本改写引擎，只支持本次需要的保留段、省略段及现有封面前缀。

数据库阅读数据和源文件无需变更；如为长空白查找增添计算索引，它属于可重建缓存。缓存版本升级即可，不保存显示 UTF-16，不做新旧显示路径长期并存。预期能删除 visibleCharacter 的分散调用、blank delegate、空白页合并和双行数，但不能承诺总行数必然更少，也不承诺开书/翻页提速数值。

## 实施顺序与必要验证

1. 先固定上面的点/范围、复制和窗口结果契约，补会失败的集成用例：从真实多块空白区穿过 Session→Rust→Controller，直到下一段出现在屏幕，而不是只检查回调。
2. 完成 Rust 有限窗口解析与显式交接，覆盖初次打开、向前、向后、prepared tail、paused/failed 和 EOF。若需紧急 fix，可单独交付这一闭环，禁止长期追加 report 假进度。
3. 建立投影与映射单元测试，迁移所有表列消费者，包括原生 copy、AI excerpt 和 preview。分页切片保留映射，封面与预读明确排除。
4. 一次删除被替代的零高度空白处理和隐形字符补丁，升级排版缓存版本。保留与空行无关的字形、高亮、分页续段逻辑。
5. 只跑受影响的 Rust/native/模拟器回归并检查画面。用户真机试用为最后自愿步骤，不用真机代替确定性测试，也不把无真机结果写成全平台通过。

必要测试矩阵：

| 层级 | 核心断言 |
| --- | --- |
| 映射纯测试 | 首/尾/连续/含 TAB、全角空格、NBSP 的空行；中文、emoji、代理项、组合字符、ZWJ；双向转换在保留字符上往返一致，删除点按 affinity 单调；空范围、EOF、越界、封面前缀、投影切片与拼接一致 |
| 复制与选区 | 只选缝隙一侧不多带空白，跨缝隙原文包络含空行而复制文本等于显示文本；应用拷贝、原生 copy/全选、AI excerpt 文本一致；单行选中文字搜索词等于捕获的显示文本，多行拒绝不变；封面和预读不泄漏；系统查询仍收到正确显示选区 |
| 分页 | 正向/反向、窗口前补/后补、长段、标题留白、页首/页尾删除段；显示覆盖无缺漏重复；源所有权连续；可见页行数大于零；预读不渲染/不复制；页缓存失效及相同范围投影变化能更新 |
| 原文功能 | 既有单行搜索及原文命中坐标、纯空白范围导航与高亮、批注范围、交叉批注菜单、书签空白内锚点、AI 当前页与统计范围；保存和重开仍是原文 UTF-8，SHA/规范正文不变 |
| 窗口集成 | 超过 4 个实际 12 KiB 分块的空白区，起始全空白及正文后长空白，前进/后退均到达目标；回到刚才、外部跳转、快速方向反转、重开；断言最终可见文字和保存位置，没有回退循环、忙循环或无界加载 |
| 渐进准备 | 全空白已准备前缀后追加正文、追加仍为空白、暂停/恢复、失败、最后全空白及全书空白；不假报 EOF/bodyReady，不虚记阅读进度；跨块段首空格不能误删 |
| 画面与生命周期 | 主阅读滚动/分页/预览三者间距一致，卷章仍在；字体/字号/方向变化后恢复同一句及 lineY；保留原生选区和滚动惯性；VoiceOver 文本排除预读与封面占位 |
| 性能边界 | 普通书与长空白合成书的投影时间、frame 工作量/锁时长、最大驻留字节、实际页切换；确认没有整书扫描占住共享 actor。比较既有窗口周转基准，不启动新一轮长时间真机自动化 |

现有测试应保留“原文/SHA/位置不变”的目标，替换“显示字符串逐字等于原文”及“必须有一张零行空白页”等实现断言。已有 `TextLayoutTests` 的封面、原生高亮、导航恢复、分页跨块、重复页容器和预览回归继续复用。新的验收关键是从真实 frame 更新完成一次连续阅读，而不是增加更多只验证局部零高度几何的测试。

## 实现中的窗口契约

- 原文仍按原有分块存储；`reading_blanks` 只记录已由 LF 或 EOF 确认、相邻合并的空白段，`projection_end` 是每代导入已确认语义的排他末端。当前段已出现非空白字符时推进到 scanner.end，否则只到 scanner.start；EOF 确认到末端。空白区段、块、frontier 与投影 revision 同事务发布；frontier 单调且不超过已提交 byte_count，重放前缀不回退。移除非空白字符索引，不能用它代替保留内容的可用性。暂停恢复重建 pending-line 状态，EOF 只确认空白而没有新块时也更新 revision。
- frame 携带稀疏保留片段、明确的 omitted ranges、coverage 边界、requested cursor、projectionAnchor 与前后 frontier。coverage 只由保留段与已证实空白无缝组成，不把未知段或请求游标到目标间的非空白伪造为空白。
- 正文载荷预算为 64KiB，单次处理至多 256 个源块；省略区间不占载荷。保护当前完整可见范围与活动选区，预算不足返回 `Deferred`，不驱逐锚点、不自动重定位。显式 locate 可在书尾回找正文；严格 extension 不反向回退。
- `Awaiting`、`Beginning`、`End` 与 `Deferred` 不替换当前可读正文，也不触发 moved/save。请求只有同步准入成功才消耗去重键；完成后按当前实际视口重新评估，未变化的 Deferred tuple 不重复请求。
- 空白查询使用起点之前的一个索引 predecessor 加窗口内 starts，避免有限窗口却扫描全书前缀。相邻保留源段一起分类，仅已证实空白间隙分隔段落，避免物理分块把标题续片误判为正文。

## 滚动取行与恢复契约

`captureViewport`、窗口替换和 `reportScroll` 共用一个取行几何方法：将视口转换到 text container 坐标，枚举行片段，排除封面／不可选预读，优先取 used rect 完整可见的第一条正文行；没有完整行时才取相交行。原文 scalar 锚点和该行 fragment 顶边的屏幕 Y 一起返回。lineY 是片段顶边，不是字形基线；恢复始终按保存的同一原文字符定位，不重新取点找目标。删除旧的 x=0、contentOffset 最近字形路径，避免缩进或段间距改变取样行。

回归同时独立比较同一原文字形的片段顶边与实际基线，不能只用共享取样器前后相等证明恢复正确。覆盖顶边落在段间距、小数物理像素、窗口前补及裁剪，并读取持久化位置确认没有翻到上一段。这是取行契约的修正；原先一次重取锚点不同的失败没有独立几何证据，未证明当时画面发生跳动。

## 保留空白的定位与连续读取

`projectionAnchor` 是加载且保留的原文 scalar，允许是段内空格。`hasNonWhitespacePayload` 只报告本次载荷是否有墨迹见证，不决定 Ready 或 EOF。定位和严格扩展使用同一保留数据解析器，只避开已确认的 reading_blanks，保留空白按源边界正常推进；未确认尾部返回 Awaiting，反向仍能取得左侧已确认内容。载荷、coverage 与段落边界截在 projection_end，待确认尾部不泄漏为 Ready 或 omitted。前后 cursor 落在有效 UTF-8 scalar 边界，显式定位在保留区原地恢复；EOF 回找最后一个保留 scalar。

验收包括：两个以上 64KiB 预算的段内空格、TAB／全角空格，定位／恢复精确、无墨迹载荷 Ready、双向真实 Session→Controller 滚动／分页到后续文字与返回；暂停前后的全白尾部、首个非空白字符确认前缀、LF 与 EOF 确认；跨页并跨巨量空行的剪贴板内容等于逐页显示文本连接，单屏结果不变，离页不发布异步结果。
