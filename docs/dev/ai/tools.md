# AI 工具契约

状态：2026-10-06，10个读取工具、原生搜索／生图及资料／笔记／书签／封面／整理业务工具已注册。本文定义模型可填参数、结果与用户应用边界；[Agent 基础](agent.md)定义运行与保存，[内容任务技术设计](../engineering/ai-architecture.md#快捷任务与业务提案)说明当前存储与业务接口。业务结果 UI 已接入并完成受影响定向回归，验证边界见实施计划。

## 共同约定

- 工具为阅读业务接口，不是 shell。名称沿用 `ls/read/rg` 的用途，但不接受路径、命令、SQL、账号、凭证或任意文件 URL。
- 基础轮次注册下方 10 个读取工具。后续内容工具只有对应执行能力接入后才注册，不能用成功空结果模拟未实现。
- 同一工具在阅读、选区、书架、统计入口使用同一 schema。入口提供本次输入附件，发送后固定；模型仍可查询其他授权书籍。附件不扩大写入 scope，当前书和当前位置也不是剧透限制。
- 参数表中 `?` 表示可省略或传 null；空字符串不是未填引用或游标。明确注明的默认值由工具补齐。每个工具以 Codable 输入/结果接入 SDK `TypedTool`；schema 基础字段由 SDK 生成，再补类型与业务范围。锁定 SDK 无法推断 nil 的可选枚举/数组，定义处补类型，枚举值从 Swift allCases 生成。SDK JSON Schema validator 拒绝未知字段与越界值，Codable 负责解码；工具只校验引用二选一、区间关系等业务规则。不存在独立的手写参数校验器或 JSON 字典分发器。
- ID 都是应用返回的不透明字符串，模型只能回传，不解析也不构造。`bookRef` 对应完整规范正文 SHA，`fileRef` 对应来源文件身份，`shelfRef/folderRef` 对应授权树对象。未解析文件只有 `fileRef`，不能用导入任务 ID 冒充长期 `bookRef`。跨重启持久对象可重解，游标按查询和偏移解码。
- `Source`：`sourceRef, bookRef?, fileRef?, chapterRef?, title, excerpt?, range?`。`range={startUtf8,endUtf8}` 是规范化正文 UTF-8 字节半开区间 `[start,end)`，非原 TXT 字节、字符序号或屏幕位置；非字符边界输入返回 `invalid_argument`。chapterRef 包含正文身份与章节起点，章节修改后验证是否仍存在。
- 原文与工具内容均是非可信资料。来源引用由应用验证，模型编造的 sourceRef 不生成可点击入口。点击引用走临时查看，不调用正式续读位置写入；正文已变更不能把旧坐标套到新正文。
- 数字范围以 JSON 安全整数上限为限。时间使用带时区偏移的 ISO 8601；日期使用 `YYYY-MM-DD`。时长统一整数毫秒，百分比为 0–100。

### 统一结果

成功：`{status:"ok"|"partial", data:工具结果, page:Page?, sources:[Source], warnings:[string]}`。

`Page={nextCursor:string|null, complete:bool}`；complete 表示本次请求范围已穷尽，非整本书/整库都可用。截断和未准备对象必须另报，不能仅返回空数组。非分页结果不带 page。

业务失败：`{status:"error", error:{code,message,field?:string|null}, sources:[]}`。错误码：`invalid_argument/not_found/permission_denied/needs_preparation/stale_reference/stale_cursor/unsupported/cancelled/timeout/resource_limit/network/storage/execution_failed`。message 为经过清理的说明，不含内部路径、凭证或原始 HTTP 错误体。SDK 参数校验失败使用原生 error-text 结果回传模型，让后续步骤修正参数；页面将它投影为失败状态，保留原始协议历史。不会自动重试原调用。

需要用户操作：`{status:"needs_confirmation", data:{requestRef,kind,items,reason}}`。requestRef 由应用生成并关联会话、原调用和具体对象；不是模型提交的授权。用户拒绝返回 `{status:"denied",data:{requestRef,reason},sources:[]}` 结果，不伪造网络失败。

分页 cursor 为查询签名和偏移编码，不绑定会话内字典、不设置闲置过期或数据修订门槛；重开服务可继续同一查询。后续页保持查询字段一致，可改变 limit/maxHits/maxBytes。列表默认100条，每页按50 KiB条目预算返回完整 JSON；单个完整条目超过预算仍返回，不用通用响应硬上限丢弃内容。正文每次最多2000行或50 KiB，命中摘录最多500字符，采用 Pi 的工具输出预算。截取时返回 nextCursor，完整内容可继续获取。

## 基础工具：一次交付全部接通

### 1. `ls` — 浏览授权书架树

输入：

| 字段 | 类型与规则 |
| --- | --- |
| parentRef? | shelfRef/folderRef；省略返回所有已授权书架根，不返回系统目录 |
| kind? | `all/folders/books`，默认 all |
| sort? | `name/recent`，默认 name；recent 对书按最近阅读降序，目录仍按名称，稳定 ID 打破同值 |
| limit?, cursor? | 通用分页 |

结果 `data={parentRef:null|string,items:[{ref,kind:"shelf"|"folder"|"file",name,bookRef?,availability,sizeBytes?,childBookCount?}]}`。availability 为 `ready/needs_download/needs_parse/preparing/unavailable`。显示名称/面包屑可返回，系统绝对路径与 security-scoped bookmark 不返回。只列一层，不默认递归扫描或下载。

实现依据：`AppDataService.shelves/libraryEntries`；工具层实现稳定目录引用解析和分页投影。不要把 relativePath 直接当模型操作参数。

### 2. `search_books` — 按资料查小说

| 字段 | 类型与规则 |
| --- | --- |
| query? | 字符串，默认空；书名/已知作者/简介内不区分大小写包含匹配，不暗示语义向量搜索 |
| scopeRef? | 授权 shelfRef/folderRef；省略所有授权书架 |
| author? | 字符串；作者包含匹配 |
| tags? | 字符串数组，全部匹配 |
| readingStatus? | `unread/reading/finished/paused`；未关联正文的状态未知，不伪造 unread |
| sort? | `name/recent`，默认 recent |
| limit?, cursor? | 通用分页 |

过滤条件相与。结果 `data={items:[{bookRef?,title,author?,synopsisSnippet?,tags,readingStatus?,availability,files:[{fileRef,name,parentRef,availability}]}]}`。逐个返回匹配的真实文件，不按 SHA 去重隐藏来源。简介摘录最多500字符，每项指向对应的真实文件；完整来源由 get_book 获取。摘录字段明确标记截取。查询只使用现有索引，不为筛选下载正文。结果明确 `warnings` 中哪些文件无完整资料。

依据：`libraryEntries/allLibraryBooks`、`effectiveQuery` 资料投影。工具服务基于最终业务数组完成组合筛选、去重和结果分页；当前不是数据库级书库分页，不声称大书库扫描恒定内存。

### 3. `get_book` — 资料、来源与可用状态

输入：`bookRef?:string, fileRef?:string`，必须恰好一个；`prepare?:bool=false`。未知 SHA 的文件可用 fileRef 加 prepare=true，在应用确认后准备并取得正文身份；默认只读已有资料。

结果 `data={bookRef?,title,author?,synopsis?,tags,readingStatus?,wordCount?,chapterCount?,progress?:{offsetUtf8,percent,chapterTitle?,lastReadAt?},cover?:{assetRef,width,height},availability,availableUtf8?,totalUtf8?,files:[{fileRef,name,parentRef,availability}],filesTruncated}`。返回完整简介及所有来源。cover 仅元信息，不自动读取图片/上传。正式位置与估算覆盖分别命名。

依据：`AppDataService.details(bookID:sha:)`、`snapshot`、库来源投影。正文不可用时仍返回可取得的 SHA 用户资料；文件改动须重新验证映射，不能复用旧 SHA 的资料当成新正文。

### 4. `get_chapters` — 当前有效目录

输入：`bookRef:string, query?:string, limit?:integer, cursor?:string`。query 为最多256字符的标题字面筛选，例如“番外”或“第316章”；游标绑定该筛选。

结果 `data={bookRef,outlineComplete:bool,items:[{chapterRef,title,level:0|1,parentChapterRef?,range:{startUtf8,endUtf8},wordCount,countComplete,estimatedCoveredCharacters?}]}`。

依据：`AppDataService.chapters` → `ReaderQuery.chapterOutline`。章节结束用下一有效条目起点/正文终点计算；卷条目与章条目可能层级重叠，不能声称每项互不相交。返回用户更正后的目录，删除的标题不出现；分页前统一解析有效目录。未完整准备先进入下方确认流程。

### 5. `read` — 有界正文读取

| 字段 | 类型与规则 |
| --- | --- |
| bookRef | 必填 |
| chapterRef? | 可选章节；存在时将读取限制在该章节范围 |
| contextOffsetUtf8? | 工具返回的命中 startUtf8 等有效位置；读取所在段及前后文，不能与显式 startUtf8/endUtf8 混用 |
| beforeParagraphs?, afterParagraphs? | 仅与 contextOffsetUtf8 一起使用；各默认3，非负整数；空白行不计段数，保留原文空白；指定 chapterRef 时结果裁在该章内 |
| startUtf8? | 非负安全整数；默认章节起点，否则0 |
| endUtf8? | 大于 start，默认章节末/正文末；指定 chapterRef 时不得越界 |
| maxBytes? | 默认51200，正整数；实际最多51200，正文 UTF-8 字节上限 |
| cursor? | 后续页必须保持以上查询一致 |

结果 `data={bookRef,text,range,sourceRef}` 加 page。按字符边界截断，可优先保留完整段落；返回真实 range，nextCursor 指向下一字节。page.complete 表示请求范围读完，不表示全书。无正文或不完整时不自动只读前缀；先确认准备。不得通过自动展开整章绕过大小限制。

依据：`AppDataService.textRange/textContext`；Rust 解析前后段边界，模型直接回传命中位置，无需自行加减 UTF-8 偏移。底层上下文最多1 MiB，AI 仍按 maxBytes 分页，后续页保持上下文参数不变。工具读取不调用 `writePosition`、不启动阅读计时。

### 6. `rg` — 正文检索

| 字段 | 类型与规则 |
| --- | --- |
| bookRefs | 必填，至少一个 bookRef；不省略为“搜整个库” |
| chapterRef? | 限定有效章节；仅 bookRefs 恰好一本时可用 |
| startUtf8?, endUtf8? | 限定正文半开范围，可只给一端；默认章/书边界。仅单书可用，指定 chapterRef 时必须在章内；使用工具返回的边界 |
| query | 必填，非空字符串 |
| mode? | `literal/regex`，默认 regex；regex 为 Rust regex，单行，不支持回溯引用/lookaround |
| caseSensitive? | bool，默认 true |
| maxHits? | 默认100，正整数 |
| cursor? | 后续页 |

结果 `data={hits:[{bookRef,range,excerpt,chapterRef?,chapterTitle?,sourceRef}],coverage:[{bookRef,requestedRange?,status,scannedUtf8,availableUtf8,complete}],truncated:bool}`。excerpt 为同一行短摘录，最多500字符，范围是实际匹配范围；用 `read(contextOffsetUtf8: hit.range.startUtf8)` 取前后段。按 bookRefs 输入顺序、原文位置稳定排序；不是相关性排名。未准备项统一列出准备提示；拒绝本次调用返回 denied，不擅自准备其中其他书。

范围在 Rust 扫描之前生效，不先全书搜索再过滤；正则锚点以选定范围中的行片段为边界。complete 表示 requestedRange 扫描完整，scannedUtf8 是已扫描到的绝对正文偏移，availableUtf8 为本次扫描终点。范围是按用户问题选择的查询条件，不是强制剧透策略。

依据：`AppDataService.search` → 最终有效章节投影 → `SearchJob.nextBatch/cancel`。按相同查询及偏移重扫，不跨调用保留活跃句柄；退出或取消释放任务。不设置单书2000或多书5000总命中上限。收集到当前页及下一条命中后停止本次扫描，coverage 明确未扫描完的范围；用 nextCursor 继续。

### 7. `get_marks` — 书签和批注

输入：`bookRef:string, kind?:"all"|"bookmark"|"annotation"=all, query?:string, startUtf8?:integer, endUtf8?:integer, limit?,cursor?`。范围两个字段一起出现且 start<end；批注按交叉判定，书签按点落入判定。query 在摘录与评论包含匹配，大小写不敏感。

结果 `data={bookRef,items:[{markRef,kind,range,excerpt,note,createdAt,sourceRef,hasConflict}]}`。评论/摘录各最多500字符，超长字段带 `noteTruncated/excerptTruncated`；未解决冲突标识保留，不自行挑选一个版本当确定内容。

依据：`userMarks/annotations/mark` 与批注候选业务投影；现有 `aiMarks(sha:)` 已提供按 SHA 的候选查询，工具输出冲突状态而不暴露候选存储键。后续编辑必须读取最新编辑基线。

### 8. `get_mark` — 完整评论与冲突候选

输入：`bookRef:string,markRef:string,variantRef?:string,maxBytes?:正整数=51200,cursor?:string`。

普通批注返回 `data={markRef,bookRef,kind,range,excerpt,noteText,sourceRef}` 与分页。只对评论分页，UTF-8 边界连续；摘录完整返回。存在冲突且未选variantRef时返回 `data={markRef,hasConflict:true,variants:[{variantRef,deleted,range?,noteSnippet?}]}`；variantRef只用于读取这次候选，过期重新查询，不是模型可写的冲突解决指令。选择候选后按普通结果分页，不把某个候选当作最终已确认批注。

依据：现有候选归并和批注编辑基线；工具已提供只读冲突投影。get_marks 摘录不能代替完整评论读取。

### 9. `get_reading_statistics` — 阅读记录与汇总

| 字段 | 类型与规则 |
| --- | --- |
| fromDate,toDate | 必填日期，含首尾，合法日期且起点不晚于终点 |
| bookRef? | 单书；省略所有阅读历史（包含原文已不可用的书） |
| view? | `summary/days/books/sessions/chapters`，默认 summary；chapters 必须指定 bookRef |
| limit?,cursor? | days/books/sessions/chapters 分页；summary 不接 cursor |

`summary` 返回 `{durationMs,bookCount,readingDays,recordingEnabledOnDevice,dateBasis:"recorded_local_day"}`；days 返回 `{date,durationMs,bookCount}` 列表；books 返回 `{bookRef,title,durationMs,firstReadAt,lastReadAt,readingDays}`；sessions 返回 `{sessionRef,startedAt,endedAt,recordedDate,utcOffsetSeconds,preview,durationMs,bookRef?,title,sourceRef?}`；chapters 返回 `data.chapters={bookRef,items,outlineComplete}`，含有效章节身份、字数、估算已覆盖字数与 `estimatedCoveragePercent`。

与现有统计页一致：日期按阅读发生地保存的 local_day，不接受一个 timezone 来悄悄重排历史。环境工具的当前时区只用于解释“今天”等相对日期。多设备同时阅读如实累计，不做时间重叠去重；阅读时长不能断言喜好，覆盖率是估算。summary、分页总计由业务层算，不从当前一页让模型相加。

依据：`AppDataService.statistics/activities/chapters`、`statistics.rs`；现有 AIReadingTools 已对结果分页。章节覆盖和原文缺失保留区分。

### 10. `get_environment` — 当前环境

输入：`fields?:["time"|"locale"]`，默认两者。

结果按字段返回 `now`（ISO 8601）、`timeZone`（IANA）、`utcOffsetSeconds`、`appLanguage`（BCP47）、`region?`。不返回 GPS、设备名、账号等隐私标识。基于系统 Date/TimeZone/Locale 与应用语言；初始上下文可附创建时快照，当前时间由本工具获取。

## 正文准备不是任意下载工具

`get_book(prepare=true)` 及 `read/get_chapters/rg` 遇到 needs_download/needs_parse 时，解析具体 fileRef、已知大小和查询目的，发出应用确认卡。多书 `rg` 一次列出全部尚未准备的书籍，按引用去重；用户同意的是这次完整列表，不能只提示第一本后准备其余书籍。模型不能提交 `approved:true`、下载 URL 或替换源路径。用户确认后应用使用 `prepareSourceFile` 和导入服务，显示进度，再重试原调用；下载本身不改变阅读位置、不制造阅读统计。

相同来源准备请求合并；取消 AI 等待只释放本任务的等待与租约，不取消读者或其他会话仍需要的共享导入。内容校验后若 SHA 改变，返回 stale_reference 和新的可查询身份，不能悄悄把旧书引用重绑新正文。来源失效提示重新授权，由用户走系统文件入口。

当前工具已使用 `AppDataService.aiPrepare` 共享准备入口，内部通过 `openSourceFile(trackReadingSource: false)` 取得租约，不建立正式阅读来源或启动计时；不要改用默认正式开书路径。

## 业务提案与原生内容工具

下表工具已注册到同一运行器；web_search/generate_image/find_cover 按对应用途配置提供。它们复用本契约的引用、消息、确认和取消机制。所有 `propose_*` 只产生预览，真正应用由用户点击驱动，无模型可调用的通用 `apply/delete/move`。

| 工具 | 输入（未标 ? 均必填） | 返回及约束 |
| --- | --- | --- |
| `web_search` | query:string（非空）, language?:BCP47 | answer、sources:{sourceRef,title,url,excerpt?}；默认搜索连接的原生工具执行；没有配置时不注册；截断按现有预算标记 |
| `generate_image` | prompt:string（非空）, referenceAttachmentRefs?:string[] | attachments:{attachmentRef,mimeType,width,height}、实际执行来源；默认生图配置执行，参考图要求实际编辑能力 |
| `find_cover` | bookRef, query?:string | bookRef、candidates（proposalRef、attachment:{attachmentRef,mimeType,width,height}、source、generated）、answer 与 sources；只获取本次搜索返回的来源及其页面显式声明的一层图片；无图片可返回空候选，不猜 URL、不冒充官方封面 |
| `propose_book_metadata` | bookRef, author?:string, synopsis?:string, tags?:string[], tagsMode?:`merge/replace`, readingStatus?:`unread/reading/finished/paused`, sourceRefs?:string[], rename?:{fileRef,name} | 至少一个建议字段；省略/null不改，明确空字符串表示建议清空；tags 默认 merge，replace（含空数组清空）须有用户明确要求且默认不选。readingStatus 仅接受用户明确要求的状态修改，绝不推断；默认“完善资料”快捷任务不提出阅读状态。每条结果一本书；审阅页显示最终效果，变化文本默认采用建议、可切换原内容并编辑；新增标签默认选中，replace 移除标签默认保留、由用户逐项选择。按钮按实际写入项计数（标签整体一项）；proposalRef 不变，无 baseRevision。书名不属于 BookMetadata；rename 对指定来源文件真实改名，name 为主干并保留扩展名。fileRef 必须属于 bookRef，仅明显文件名噪声或用户明确要求时建议，不改写/翻译书名或按正文猜测。用户在审阅页确认，应用校验原文件快照并以 replace:false 改名；冲突不覆盖、不自动换名。重命名与 metadata 独立执行并分别报告，不影响按正文 SHA 保存的阅读数据 |
| `propose_note` | bookRef, startUtf8, endUtf8, note:string, markRef? | 新增/编辑批注预览；范围与当前文本核对，交叉标注按既定合并规则，出现冲突进入既有编辑页，不自动覆盖候选 |
| `propose_bookmark` | bookRef, offsetUtf8:integer | 预览已存在/新增，确认是“确保存在”，不调用 toggle 导致已有书签被删 |
| `propose_cover` | bookRef, attachmentRef | 确认替换预览；必须是此任务可访问的有效图片附件，应用后转为用户封面资源 |
| `propose_library_organization` | scopeRef, folders:[{temporaryRef,parentRef,name}], placements:[{fileRef,parentRef,name?}] | 虚拟目录树、变更、冲突、previewRef；应用捕获源原始 SHA 与父目录状态快照，不接受模型提供的 baseRevision。parentRef 只能是本方案 scopeRef 范围内目录或本方案 temporaryRef；名称校验，禁止循环/重复归属/删除/覆盖；未提到对象保持原样 |

整理 temporaryRef 必须唯一，并与 scopeRef、所有 placement fileRef 及真实引用保留命名空间（prefix: 形式）分离，校验发生在目录准备和预览变更前。普通 f/source 等名称仍有效；有效临时目录引用继续支持嵌套父子与文件 placement。

网页 sourceRef 统一为 `web:SHA256(UTF8 精确返回 URL)`，不使用 SDK citation ID；URL 包括原始签名查询，工厂检查 http(s)／host。同引用保留首次位置与首个非空标题，host 只在末尾补缺。提案与 UI 只解析同一 session 已成功提交的类型化搜索／find_cover 结果；可计算哈希不代表可引用，编造来源或其他 session 来源返回 stale_reference。

find_cover 在执行期间暂存本次候选／图片，不提前发布结果；工具结果 entry 成功提交到本 session 历史后，才显示答案、来源和候选。取消或失败时清理该调用未提交的新图片，先前资产不受影响；已提交成功结果在后续 turn 中断后仍保留。

封面 proposal 的 origin 为 web(AIWebSource)、generated、currentCover 或 unknown；来源来自同 owner 的已提交 find_cover／generate_image／当前封面附件快照，不由无网页来源或显示标题猜测。候选按 owner／book／attachmentRef 唯一，所有 proposalRef 和历史保留，不持久保存候选已应用状态；不同引用不按图片内容合并。

搜索与生图接口、配置、认证边界及交付条件见[原生工具契约](native-tools.md)。不实现独立 read_web；供应商内部浏览不伪装成应用独立工具。不将摘要冒充网页原文，连接与模型不由工具参数指定。generate_image 为通用图片能力，不自动替换书籍封面；find_cover/propose_cover 的候选经封面审阅流程应用。

业务提案沿用 `AIReadingInput`/Codable/TypedTool，结果作为工具历史快照保存；领域页面展示消息携带的原始建议，用户编辑与选择仅由本次复核持有，关闭丢弃。用户应用必须重新解析实时业务值，不把模型结果或历史“已应用”当写入权限。

- 资料：应用前 fresh `details` 与所选字段的显示现值比较；任一所选字段变化，该书不写并更新现值让用户再次确认。通过后 fresh 为 base，叠加选择值后一次 `saveMetadata`。多书逐书报告；检查与保存跨 await，不保证跨设备 CAS。
- 笔记：重读 AnnotationEdit 基线；交叉范围转入既有编辑器确认合并/冲突，不自动覆盖；原提案仅在编辑器业务提交成功后标为 applied，取消或失败保留待处理。书签使用业务层事务内 ensureBookmark 操作，不能 `hasBookmark` 后调用 toggle。
- 封面：候选获取适配器授权本次精确 sourceRef＋URL 配对，以及这些页面按下文规则声明的一层图片；沿用普通系统 URLSession/ATS 的信任、DNS 和路由，不提供 no-LAN 保证。完整下载后 ImageIO 解码；封面筛选要求短边至少100px且宽高比不大于1.2，每次最多8个候选。不设置图片 URL 后缀／MIME／字节数门槛。当前封面作参考图仍复制已验证业务资源为 session 附件，应用经 makeCover/saveMetadata 产生独立用户封面。候选不标记当前或已应用，实际当前封面仅用于业务检查和对比缩略图，各候选始终可再次设为封面。
- 整理：previewRef 对应应用内部快照，不是存储 revision。用户确认后逐项在业务文件协调内重验，变化项及依赖项不执行。复用现有创建/移动/改名服务且 replace=false；跨提供方／跨卷使用复制、目标 hash 与源快照校验后移除源的业务路径。文件操作与索引更新非原子；结果须区分实际移动与关联/刷新失败，不自动重做。执行清单只在本次启动内保留。

## 内部上下文与确认

入口设计包括书籍/阅读位置/选区、目录 scopeRef、多选 selectedFileRefs、统计明确 fromDate/toDate 与可选 bookRef。`AIEntryContext` 为 association＋attachments；`AIReadingAttachment.Kind` 包含 book/position/selection/bookmark/annotation/folder/files/statistics/image。目录携带 scopeRef、多选携带 fileRefs、统计携带明确日期，图片使用 session-owned attachmentRef，表示图片工具参考；对话只收到 opaque ref/标题及尚未看过像素的说明，不自动上传像素。generate_image 才按 owner 解析图片，缺失引用返回 not_found（referenceAttachmentRefs）。对话工具能力与图片服务编辑能力决定当前编辑请求可用性，不以对话视觉能力筛选，也不阻止历史参考图后的无关文本请求。显式添加按次生成出现项 UUID，重复对象保留且只移除选定出现项。附件发送前可移除、发送后固定，不注入系统提示或充当权限。具体交互见[阅读附件设计](../design/ai.md)。选区请求投影按既有预算标注截断，不修改历史原始选文。

书籍、目录、多选、选区和统计附件均为用户上下文，不因入口不同设置额外权限白名单。整理工具以提案自身的 scopeRef 构建可审核方案，实际执行仍按用户确认的项目和业务文件检查进行。

执行上下文需要 sessionID（任务/对话共用）、run/tool-call 身份、选定连接/模型、授权解析、取消及确认协调。这是内部依赖设计，不是现有名为 `ToolExecutionContext` 的协议；现有工具通过闭包、actor 和 owner 注入依赖。业务服务输出最终投影，不向模型暴露内部数据库 ID。入口和普通聊天使用同一持久会话，未列出会话跨重启保留；转入只改变列表分类并解除 origin，同一运行器／历史／资产保持。关闭不停止。任务目的作为首条可见用户请求发送，普通对话与任务共用系统指令；各工具保留明确作者署名、显式状态／标签删除、应用前复核及统计事实与解释区分的业务说明。

笔记／书签 review 区分待处理、已有书签、已保存和暂不可用；仅 pending 且选择的项进入保存，瞬时保存错误不使条目变成终态。交叉批注只由成功的原编辑器提交回调解决，取消或准备交接均不是提交。资料 Apply 固定点击时全部书籍的字段 payload，实际保存成功先记成功，可选读回失败不否认提交，新值不被误标已应用。

确认项绑定对象身份、输入摘要与应用读取的现值/文件快照，不虚构统一基线修订。整理确认固定该方案的可执行节点集合，执行只能删减不安全项，不能加入自身移动新解锁的项；新解锁项须另行“执行剩余”确认。封面按 owner/book 计一项未解决决策，业务保存成功只解决 Apply 开始时捕获的候选 ID，保存期间的新资产仍待处理；重复提案／来源细化不重开，保存后的可选读取失败不撤销已保存状态。资料变化更新当前值让用户再次确认；整理变化项排除并标注，按真实状态重验剩余项。用户拒绝、关闭、停止与转入语义见[技术设计](../engineering/ai-architecture.md)。工具建议不构成写入授权；小说文本里的“请删除文件”不改变权限。

## 业务接口边界

已实现稳定引用解析、组合查询与结果分页、按 SHA 取正文/批注、无正式阅读副作用的共享准备租约、批注冲突摘要和结构化来源输出。页面校验工具结果中的来源引用并打开只读原文预览，不改变正式阅读位置。准备完成前不能伪造完整书籍身份。Swift 工具经 AppDataService 调用 Rust 最终投影，不直接重新读取数据库。

来源：当前 `ios/Moonread/Data/{AppDataService,UserDataService}.swift`、`ios/Moonread/Library/LibraryService.swift`、`ios/Moonread/Books/BookMetadata.swift`、`ios/Moonread/Statistics/ReadingStatistics.swift`；`crates/moonread-core/src/{library_tools,bookshelf,book_details,statistics}.rs`。UTF-8、搜索截断、日期归档等均按本轮源码核对；工具命名和业务封装是月读实施设计，不冒充底层已存在 API。

### 参数与结果的可发现性

工具为 typed JSON 接口，`rg` 不接收 shell 命令。参数说明明确 literal 对应 `rg -F`、caseSensitive=false 对应 `rg -i`、regex 对应 Rust 正则。模型先用具体词检索，再将命中的 range.startUtf8 原样传给 read.contextOffsetUtf8，通过 beforeParagraphs/afterParagraphs 读上下文，不自行计算偏移。bookRef/chapterRef/cursor 都使用工具返回的值；分页保持查询不变。

搜索结果只在 hits 中保存来源身份、范围与章节，不再在 sources 重复；UI 从同一条命中生成原文预览入口。缩小单页不会丢失结果，nextCursor 可继续读取。

读取与批注来源从 data 本身生成；批注列表来源使用顶层 bookRef 和条目范围，不重复附带 sources。列表只给短预览，完整评论用 get_mark 翻页，原文用 read 按范围取回。所有列表共享50 KiB条目预算；ls/search_books/统计维持分页，环境信息保持按需字段。

## 持久结果与全新复核

所有 propose_* 和 find_cover 只有成功 committed history 结果生成可操作卡片；pending output 只用于恢复。提案正文以 history 为唯一来源，每次复核从 result/entry/call ID 对应的原始结果和当前业务数据新建页面内编辑与选择，关闭丢弃。资料和封面应用只有 transient saving/success/error，业务成功后刷新当前值，不持久保存应用成功／回执来限制再次操作。会话资产使用同 container 的外部存储 row，在第一次 queue/pending/history 引用的同一保存中插入。

find_cover 串行获取本次搜索精确 canonical ref+URL 配对授权的来源。完整下载后先做 ImageIO 解码；非图片响应仅把前2 MiB原始字节交给 Rust 提取器，这只是解析输入上限，不限制网络或磁盘用量，截断可能漏图。字符编码按 HTTP charset、BOM、meta 声明、UTF-8 lossy 选择。

页面图片按 og:image、twitter:image、image_src/itemprop=image、JSON-LD image（含数组、ImageObject、@graph）、带非空书名 alt 或 cover/bookimg/book-img/mainpic 标记的 img 顺序提取；lazy 地址优先于 src，兜底最多2个，每页合计最多4个去重地址。相对地址依据最终响应 URL 和第一个有效 base href 解析，只接受有 host 的 http(s)。不猜路径、不改 query、不跟随普通链接、不执行脚本、不将网页文本加入模型上下文；派生资源只解码，不递归提取。按请求前已解析 URL 精确去重，保留首次来源，不承诺合并重定向别名。候选上限不是请求数上限，尺寸筛选也不保证排除方形 logo。

图片请求每一跳重新计算 Referer：同源为去掉 userinfo/fragment 的最终页面 URL，跨源只发 origin，HTTPS 页面到 HTTP 目标移除该头。候选 origin/sourceRef 保留原始搜索来源，后续提案来源仍须成功提交到同 owner 历史。取消或调用失败清理本次全部未提交暂存资产；成功只保留返回候选，其他调用和已提交资产不动。这些规则仅作用于 find_cover，不改变通用生图和图片存储契约。

## 封面获取实现

授权搜索来源图片和一层页面声明图片的精确获取、解析上限、Referer、去重、尺寸与取消契约统一见[封面来源页面图片提取](cover-fetch.md)；原生搜索/生图输入、路由与用途配置见[原生工具](native-tools.md)。不增加通用 read_web 或模型可调用文件系统。
