# AI 消息呈现与滚动

当前使用 UITableView 块列表、文本块原生 MarkdownView、会话级展示缓存与流式显示缓冲。UI 投影不改变 runtime 权威内容、请求或持久化节奏。源码职责见[AI 架构](../engineering/ai-architecture.md)，候选优化见[性能设计](../engineering/performance.md#待优化)，实测和用户反馈只在[验证记录](../engineering/verification.md)。

## 稳定身份与增量投影

同一 text/reasoning 块从 live、工具开始、step 提交、完成到重开，ID 和父级归属保持一致。ID 采用 turn/s{step}/p{part}，part 只计 text/reasoning；工具沿用 toolCallId。assistant entry 持久保存 turn 内 step 序号，head 保存当前 step，不能从当前 50 条窗口推算序号。runtime 按真实出现顺序保留 pendingParts 与工具位置，provider span ID 只用于匹配增量，不作展示身份。中断按有序 parts 重建，持久化格式演进须保留旧历史可读并验证迁移。

单个 turn 输出按流式顺序的块列表，最终回答是最后一个 text；不在 answer/process/committed 容器之间迁移文本。已提交投影仅在 entries 改变时重算，流式 tick 只更新活动 turn；结构变化走完整投影。UI 的行值 Equatable，observer 仅在 head/running/confirmations 真正变化时发布；稳定 group 以首个 item ID 归属。

用户选择完成时保持过程展开；重新打开会话时，已完成 turn 折为“查看过程”。折叠仅插入/移除过程行，不改变最终文本块身份。复制、已停止/中断等操作栏仅在 turn 结束后出现。

## 表格与 Markdown

行模型包含任务头、较早/较新入口、用户消息/队列、文本、过程/工具组、等待、确认/结果卡、图片、错误和结束操作栏。结构变化 diffable apply，内容变化只 reconfigure 对应 ID；快照不加默认动画。其余 SwiftUI 行使用 UIHostingConfiguration，主题/AIService 环境一致，水平边距使用 LayoutTokens.content。

AI 回复及过程文本用 UIKit MarkdownView；流式时使用库的未闭合标记处理，turn 结束按完整原文重解析。按块 ID、内容 hash、流式状态和主题缓存解析结果；按块保留显示 view，cell 挂载已有 view，不能只设初始文本后重建空 controller。sizing view 池上限 24；显式测量高度并缓存，文本行不依赖 SwiftUI 自适应。非文本行仍使用自适应 hosting，高度变化遵循 selfSizingInvalidation。

高度键含块 ID、内容版本、宽度、Dynamic Type；宽度/字号改变失效，未命中按类型/文本长度估算。缓存随会话释放、不持久化；parsed/retained view 的长期容量限制尚待测量，不把 sizing pool 上限当全缓存上限。

字体、颜色、行距随主题及 Dynamic Type；一至三级标题采用既定字号比例，有序列表为普通数字加句点，去掉强调下划线。代码/表格/段落间距使用库样式，代码行号为接受的差异，不 fork、不访问私有类型。文本选择、复制和链接保持可用；原生容器的辅助功能 label 来自解析节点，链接提供 custom actions，实际 VoiceOver 顺序/自动滚动的验证状态见 verification。

## 跟随、锚点与输入区

用户开始拖动立即停止 following；拖动/减速结束接近底部（约 24pt）恢复，发送或点回到底部恢复；程序滚动不改变 following。搜索居中并高亮目标后停止 following。非跟随更新前记录第一个完全可见行 ID 与屏内偏移，更新布局后恢复，同样覆盖头部分页。

输入区占底部 contentInset，排队胶囊额外占其实测高度与间距；胶囊和回到底部按钮为 overlay，不改变表格视口。inset、键盘、输入框高度变化在同次布局中处理，非跟随恢复锚点。交互式收键盘及点空白收键盘保留。排队气泡复用用户消息、0.6 不透明度，菜单和无障碍动作可取消；多条胶囊可逐项取消。无数据变化不让全历史重建。

## 流式显示缓冲

UI 按活动文本块 ID 记录已显示长度，与权威文本分离。CADisplayLink 仅积压时运行，以约 200ms 目标时间追赶、批次 250ms 追赶保护，至少一个完整字素；不切 emoji/组合字符。中文按字素、英文按空白跨词提交，同帧最多一次 reconfigure，预算不足可在测量后调到隔帧。

后面出现新块/工具/reasoning/确认、turn 结束/停止/中断、离页或后台时立即放完，保持顺序；历史和重开直接完整显示。仅 UI 显示缓冲，不改 runtime 100ms 发布与保存节奏。

跟随时 cell 高度正常更新，display link 以临界阻尼将 offset 追向底部；新目标承接当前位置和速度，小积压限速、大积压连续加速，不重启动画、不按内容类型分支。用户拖动即停，非跟随不动画；没有另做容器高度/裁剪过渡或逐词淡入。

系统或应用减弱动态开启时，停用显示缓冲和追随动画，直接显示并贴底；VoiceOver label 使用已显示内容，不提前朗读。逐词淡入仅是[暂缓候选](../engineering/performance.md#ai-列表第二步与显示候选)。

## 检查口径

跟随收敛后 gap≈0；非跟随及加载更早时锚点误差≤2pt，无空白帧。胶囊显隐扣除新增/移除 inset 高度 H 后误差≤2pt，inset 与 overlay 同帧变化，不先跳再回。新末行从上一行下方、输入区上沿随 offset 进入，不先出现在可读区再被推走。

小积压≤约3行时单帧位移≤1/3行高；大积压不设固定400pt/s上限，单帧≤有效视口1/8、积压≤约半视口，无反向/瞬移。结束约350ms收敛，自动断言≤400ms容差，原值照记，不为容差改曲线。显示落后权威文本目标约300ms以内。回放分别用每100ms 5–15汉字普通流和20–80字密集结构流，覆盖工具插入、列表/代码/表格、队列换轮、上翻结束、键盘和搜索定位；性能比较 Release 首屏、分页追加、RSS与长帧，不以单次平均值代替真实手感。
