# 验证记录与覆盖边界

更新：2026-10-17。本文按能力保存必要证据与未覆盖范围，不作逐轮修改日志。表中结果来自各次受影响回归，不能解释为当前版本在所有设备上完成了全量验收。

## 2026-10-17 台湾繁体、英文补齐与回复反馈

`Localizable.xcstrings` 全部 1143 个条目具备英文与台湾繁体翻译。原有 1031 个条目以 OpenCC `s2twp` 转换，再抽查設定／檔案／資料夾／字型／匯入／複製／回饋等用语；巡检和编译器提取补齐 112 个键（含反馈、书架标题／数量、阅读工具、AI 连接及动态队列文案），保留英语数量单复数。移除“联网搜索”“图片生成”两处重复源键并保留原来实际生效的值，整理前后 JSON 语义一致。编译器提取只剩空串及 `full/half/compact` 测试诊断值未进入翻译目录，随包繁体资源与源目录逐项相同；核对摘要为 `build/Localization/catalog-audit.json`。

InfoPlist 三语随包资源分别使用 Moonread／月讀／月读，覆盖 App 与 iCloud 容器显示名；清除重复的 `zh_Hans` 工程地区，新增 `zh-Hant`。`ITSAppUsesNonExemptEncryption` 为 false。本地 StoreKit 配置也补齐 `zh_TW` 商品名称与说明，未操作 App Store Connect 元数据。

已结束回复的文本／操作栏提供长按菜单“反馈这条回复”。使用该块的持久化请求标识生成邮件，包含当前 App 版本、服务商、模型与所选回复，排除其他回复、会话标题和凭据；原生邮件撰写器可用时交给系统编辑／发送；否则先用编码后的 `mailto:` 打开默认邮件 App，打开失败才提供收件人／主题／正文三项可独立复制以及“复制全部”的备用页。没有自动发送，也不向 AI 服务发送反馈。隐私政策、帮助页中英文补充所选回复披露并更新日期为 2026-10-17。CloudKit 检查清单只补充 DEBUG 初始化结果的日志／Console 确认方法，无初始化代码改动。

Nix + Xcode 模拟器 Debug 构建、8 项 AppStorePrivacyTests 与 4 个受影响 UI 用例通过：英文／繁体主要页面，三语长按反馈与复制替代内容、英繁三条 TipKit 提示、既有过程整行展开。测试语言与地区参数为 en/en_US、zh-Hant/zh_TW，另覆盖简体反馈；书籍、会话正文和用户连接名称按内容保留，不转换。主回归 `build/Localization/verified.log/.xcresult`，提示与调整后的反馈页复跑 `tips-feedback.log/.xcresult`，网站 Zola 构建 `site.log`。截图已目视核对：`screens/overview-en.png`、`overview-hant.png`、`overview-onboarding.png`、`overview-feedback.png`，其余完整页面均在 `build/Localization/screens/`。`git diff --check` 与 plist 语法检查通过。未操作真机或账号凭据；模拟器无邮件账户，系统邮件实际编辑／投递与真实 iCloud Files 容器显示名未实测，不将随包资源核对当作这两项的真机验收。

打赏商品行按 Dynamic Type 分布局：标准字号保留左侧名称／说明、右侧垂直居中的价格；辅助功能字号改为上方全宽名称／说明、下方左对齐价格，不缩小字体。英文设置及相关导航／行标题统一 Title Case，说明句保持原文；智能首行缩进值缩短为 `Smart, 2 chars`。英文标题／缩进值与购买重启的前轮证据为 `build/Localization/review-layout.log/.xcresult`，最终英文资源构建与 8 项 AppStorePrivacyTests 为 `review-catalog.log/.xcresult`。标准字号总览与英文设置见 `build/Localization/review-screens/overview-review-english.png`。 三语标准字号与 AX XL 共 24 组商品位置断言通过：标准字号右侧居中，AX 价格在文字下方左对齐、文字字形包络占卡片多数宽度（无障碍字形包络与全宽布局框区分）。最终布局用例为 `build/Localization/review-ax-stacked-final.log/.xcresult`；本轮购买与重启回归通过，见 `review-ax-stacked.log/.xcresult`。AX 深色三语截图位于 `build/Localization/ax-stacked-screens/`，`overview-ax-dark.png` 已目视核对，夜宵名称与说明没有被价格挤成窄列。

逐条核对繁体 `專案` 的使用处：AI 文件整理冲突标签“同名項目”、书架菜单“選擇項目”、永久删除警告“本批中有項目所在位置不支援最近刪除，刪除後無法恢復。”、批次按钮“永久刪除這些項目”。这四处均指文件／资料夹条目，已改为 `項目`，没有 project 语境需要保留；随包繁体资源测试增加四项精确用词断言；最终 Debug 构建与 8 项 AppStorePrivacyTests 通过，证据为 `build/Localization/review-taiwan-terms.log/.xcresult`。

繁体系统清查覆盖应用动词与 App 名词、帐号字形及指定大陆词形，并按语境修正 86 个既有条目：9 处“套用”动词、帳戶／帳號，以及權限／設定／目前／自訂／文字／串流等。名词“應用程式”和 metadata 的“資訊”保留，聊天消息仍用“訊息”；逐条改动、未命中词形及保留理由见 `build/Localization/hant-terms.md`。 11 项 AppStorePrivacyTests 与三语反馈菜单／备用页 UI 用例通过，三条邮件路由采用可控的原生撰写器能力与 URL 打开结果注入覆盖，另验证 Unicode、换行及 `+ & ? #` 的 URL 编码往返；UI 用例覆盖三字段独立复制与复制全部，证据为 `build/Localization/feedback-mail-terms.log/.xcresult`。新增完整动词与名词对照断言后再跑资源单测，最终证据为 `feedback-mail-terms-final.log/.xcresult`。三语备用页及逐项已复制状态总览为 `build/Localization/feedback-mail-screens/overview-three-languages.png`，已目视核对。模拟器无真实邮件账户，路由注入测试不等同真实默认邮件 App 或系统邮件的投递验收。反馈中已删除连接显示本地化“已删除的连接”，不展示内部 UUID，不改持久化格式；连接存在时使用连接及模型可读名称。

## 2026-10-17 主页面统一设置入口

书架、统计与 AI 开启时的对话首页，右上角共用 `AppSettingsLink`：同一 `gearshape` 图标、无障碍标签“设置”和 `LibraryRoute.settings` 目的地。书架原左上设置入口已移除；原有“＋”“统计选项”“新对话”保留在齿轮左侧。对话页左上“AI 助手”改为 `slider.horizontal.3`，只管理 AI；对话栈使用 `NavigationPath` 同时承载会话 ID 与现有设置／书架路由，不复制设置页。标签栏不新增项。

使用指南补充右上齿轮说明，导入 TipKit 文案改为明确指向右上“＋”，中英文同步，提示关闭历史保持原状。设计与指南草稿同步更新。

模拟器 iPhone 18 Pro / iOS 27.0 的 Debug 构建通过；定向 UI 测试通过三首页浅深色一步进设置、每页仅一个入口、设置→书架管理→返回、AI 设置独立入口与关闭 AI 后剩余入口；使用指南浅深色与 TipKit 关闭持久化两项 UI 回归通过，对话列表主题渲染单测通过。日志／结果包：`build/SettingsEntry/verified.log` / `verified.xcresult`。现有阅读月亮关闭／重开及对话 Tab 导航 UI 回归通过（`build/SettingsEntry/conversation-regression.log` / `conversation-regression.xcresult`），合计 5 项受影响测试通过。截图 `build/SettingsEntry/screens/settings-entry-{library,statistics,conversations}-{light,dark}.png`，六图总览 `overview.png` 已目视核对。未操作真机。

## 2026-10-17 本机 AI 功能总开关

- 设置新增默认开启的“AI 功能”，独立本机键 `Moonread.ai.enabled.v1`，不进入 CloudKit。关闭时立即拒绝新请求、取消进行中的工作；连接、会话、Keychain 凭据、默认用途和已保存的数据共享许可保留，重新开启不自动复活已取消任务。
- 入口清单：AI 设置/连接/ChatGPT 登录；对话 Tab 和统一搜索中的对话结果；阅读月亮（含选区提问）；详情资料/封面按钮及任务菜单；书架单项/多选资料、目录/多选整理；统计分析；联网搜索/图片生成用途。指南隐藏 AI 章节并替换选字说明，TipKit 保留一次性历史、关闭时改用不含 AI 的提示。当前原生选字菜单没有独立“问 AI”项，选区提问通过阅读月亮进入。
- 执行层共用 `AIAvailability`：普通提交、快捷任务、agent、共享确认、登录、公共/账户目录、原生搜索/生图和封面下载均经同一可用性判断。执行租约与代次防止快速关闭/开启后旧任务续跑；共享令牌刷新也纳入取消，迟到的认证失败不会误清凭据。
- Nix + Xcode 整 App 模拟器构建及 18 项定向单测通过（新增 9 项，含关闭拒绝、agent/原生请求/快捷任务/共享确认/共享令牌刷新取消、目录批次停止、迟到失败丢弃、数据保留和重新开启）。日志/结果包：`build/AIMasterSwitch/execution-final.log`、`execution-final.xcresult`。
- iPhone 18 Pro / iOS 27.0 模拟器两个完整 UI 用例通过：浅深色入口隐藏、重启后保持关闭、重新开启连接恢复；指南与 TipKit 无 AI 描述。`build/AIMasterSwitch/verified.log`、`verified.xcresult`。分别明确设置应用与阅读配色后重新运行浅深色主流程通过，最终截图来自 `appearance-final.log` / `appearance-final.xcresult`。
- 截图在 `build/AIMasterSwitch/screens/`：`overview.png` 为六图总览；`ai-master-switch-{light,dark}.png`、`ai-disabled-detail-{light,dark}.png`、`ai-disabled-reader-{light,dark}.png`，另有 `ai-disabled-guide.png` 与 `ai-disabled-selection-tip.png`。均为原创合成 TXT。
- 截图复核：详情页日期范围卡片下方露出的书本轮廓来自统计区 `ContentUnavailableView` 的 `book.closed` 图标（“暂无阅读记录”），不是 AI 入口；AI 开启／关闭时都存在。初始截图仅露出列表下一行上缘，向上滚动后图标、标题及说明均完整可见，因此未修改详情布局。设置页 AI 说明下方增加 16pt 间隔，避免紧贴“应用”分区标题。两项受影响 UI 用例浅深色回归通过，日志与结果包为 `build/AIMasterSwitch/review-layout.log` / `review-layout.xcresult`；补充对照图 `screens/ai-enabled-detail{,-statistics}-{light,dark}.png`、`screens/ai-disabled-detail-statistics-{light,dark}.png`，更新设置图 `screens/ai-master-switch-{light,dark}.png` 已目视核对。
- 停止交接：runtime 在旧任务尚未退出时持久化的新输入会请求一次后继运行，旧任务退出后由新任务重新检查准入并消费队列；再次停止／关闭总开关撤销该请求，单纯重新开启不发送。可控挂起测试在修复前复现“新输入留在队列、零请求”（`build/AIMasterSwitch/handoff-before.log/.xcresult`）；最终 runtime 48 项与服务层停止／共享取消／总开关 3 项定向回归全部通过（共 51 项，`handoff-final.log/.xcresult`），含停止后立即入队、关开后立即入队、交接前再次关闭及入队发布时再次停止，检查持久化输入仅消费一次；停止代次同时阻止迟到的持久化返回重新请求运行。未请求真实服务，未操作手机。
- 快捷任务恢复：显式打开已有会话时复用 runtime 的队列交接入口，只有队列非空且 AI 可用才恢复；不追加新的初始输入，重复打开／运行完成后再打开不重发。新增两项服务层测试分别在创建持久化完成点关闭开关，以及用新服务实例重载“已持久化但未运行”的会话，均验证关闭时零请求、重新打开仅消费一次。模拟器构建与 53 项定向回归通过（runtime 48 项、快捷任务恢复及相关服务层 5 项），证据 `build/AIMasterSwitch/quick-reopen.log/.xcresult`。已确认的本地提案应用不中断，关闭只阻止新的请求和新的应用，该边界写入 AI 设计文档。
- 中英文帮助页 Zola 构建通过，日志 `build/AIMasterSwitch/site.log`；`git diff --check` 通过。
- 附加的 `testAIReadingMoonCloseReopenAndConversationTab` 单项通过（`ui.log`）；同轮资料任务 UI 回归卡在 XCUITest 长按菜单 idle 等待，已中止，未计为通过。本次入口隐藏通过同一菜单现有的“…”按钮验证。未操作真机，未调用真实 AI 服务。

## 2026-10-17 主动暂停意图与首次导入测试

本机按任务 ID 在独立 UserDefaults v1 键中保存主动暂停意图；用户继续、编码重启、完成和回收时清理，不修改 SQLite schema 或同步记录。重开文件时主动暂停不自动恢复，系统中断造成的暂停自动恢复；失败任务（含编码错误、原件变化、存储失败）仍由用户显式重试或处理。首次导入 UI 测试确认封面再进入正文，开书前通过真实设置固定滚动模式，保留未完成可读、暂停／继续、分页前进和两次精确位置恢复断言；额外明确暂停状态的重开／重启保持与完成后位置不变。

新增主动暂停跨服务重建保留、系统中断暂停自动继续、编码重启及完成／废弃任务标记清理三项单测。标准 Nix＋Xcode 模拟器定向回归（3 项单测＋首次导入 UI 测试）通过，UI 测试约 112 秒，覆盖封面→正文、未完成可读、暂停／继续、分页、重开与进程重启后的主动暂停保持和精确位置。未操作手机。证据：`build/FirstImportTest/{coord-run.log,coord-run.xcresult}`；此前确认产品行为冲突的证据保留在 `blocked-summary.md` 与 `interrupted-task.log/.xcresult`。

编辑详情的准备流程同样尊重主动暂停：从书架或阅读器详情进入编辑，若任务已由用户暂停，保留本机标记与暂停状态，以系统 alert 显示标题“正文准备已暂停”、说明“编辑详情需要先完成正文准备。”和“继续准备／取消”。系统提供完整背景与遮罩；点击继续后由原有编辑准备任务恢复，清除标记，完成后才打开编辑表单；取消或离页不恢复任务。系统中断的暂停仍自动继续，失败任务不新增自动重试。中英文文案已编入资源。

模拟器 Debug 构建与 3 项模型单测通过，覆盖书架／阅读器两种进入方式的暂停保留及显式继续、系统暂停自动恢复、取消时保留标记；证据为 `build/MetadataPause/regression-actor.log/.xcresult`。正常详情编辑／返回阅读 UI 回归通过。暂停编辑 UI 用例更新为浅色、深色两种场景，均验证系统 alert 的标题、说明和可点击的两个按钮，取消后重新进入仍暂停，手动继续后完成并打开编辑表单；本次模拟器回归通过，四张截图已目视核对，系统提示背景完整，无文字穿插。证据：`build/MetadataPauseAlert/{appearance.log,appearance.xcresult,screens/}`。未操作手机。

## 2026-10-17 完成导入后的本书编码入口

从正文进入阅读设置，“排版”顶部的“本书 → 文字编码”独立于全局设置，右侧用主题强调色显示当前编码（自动策略显示“自动 · UTF-8”等），配同页菜单的上下箭头；无障碍标签包含当前编码及“可更换”。“更多 → 更换编码”及暂停／失败入口复用同一分组菜单和确认框，可手选或切回自动识别。确认前不修改文件策略、不创建任务；确认后先保存旧位置，再重新读取，关闭设置页时一并释放原弹层的关闭状态，工具栏仍可正常打开。策略继续保存在本机文件行，不同步到其他设备。

数据回归使用原创 UTF-8 文件，完成导入后切到能成功解码但文字不同的 windows-1252，再切回 UTF-8：不同 SHA 的新正文没有旧位置／批注；换回后相同正文 SHA 接回原位置、书签和批注；原件字节不变，重新建立 ReaderService 后仍按文件上保存的 UTF-8 策略打开。确认框因此明确“原文件未变时，换回原编码可找回”，不承诺原件已修改时仍能接回。

模拟器 Debug 构建、4 项定向单测与 2 项 UI 回归通过：完成态成功但乱码的往返切换、完成任务回收重开、本机记忆、相同副本首选来源及手选分组；UI 覆盖确认／取消、从设置重新读取后再次打开工具栏、“更多”入口及暂停／失败菜单。初轮 UI 捕获到设置页退出仍保留旧 sheet gate，已修正且原断言复跑通过。深浅色取图在打开书籍前设定外观，6 张画面已人工核对。证据 `build/EncodingDetection/{change-final.log,change-final.xcresult,change-appearance.log,change-appearance.xcresult,change-screens/}`；失败现场保留在 `change-encoding.log`。未操作真机。 编码行的强调色／上下箭头及“可更换”无障碍标签由深浅色定向 UI 回归再次验证，通过；更新截图和日志为 `build/EncodingDetection/{menu-affordance-screens/,menu-affordance.log,menu-affordance.xcresult}`。

来源元数据只用于可选编码控件，查询改为不抛错。记录缺失、JSON 损坏或刷新移除 fileID 时返回空值并写 ReaderSource 日志（仅缺失原因／错误域和代码，不含来源内容），不阻断已取得的 lease 和正文监测；重新准备后的标签也使用同一入口。新增 session 集成单测覆盖上述三种情况，验证 readingID 保留、window 发布可读正文、error 为空及 encodingLabel 为空（本书行／更多入口的共享显示条件）。模拟器 Debug 构建与 4 项定向测试通过，正常切换找回数据、回收重开和统计异步启动继续通过。证据 `build/EncodingDetection/{source-metadata.log,source-metadata.xcresult}`；日志已核对，未操作真机。

编码重启采用会话内唯一 task，首次 await 前占用，重复选择忽略；忙碌状态由 task 派生并传给本书行、更多及暂停／失败菜单，显示“正在重新读取”并禁用。任务保持到对应 worker 结束，失败或取消统一释放。离页取消排队请求，服务在创建导入前检查取消；新 lease 在后续 await 前转交会话，编码策略回传时核对当前 ID/打开尝试，迟到结果不能覆盖离开的会话。服务已创建的来源关联及 worker 保留正常所有权，完成后回收未采用 lease 的导入，不另行删除用户的暂停／失败前缀。

用可控 continuation 挂起创建前／创建后的返回，不用 sleep 制造重叠。连续 windows-1252、UTF-8 两次调用只有第一次获准，最终读取编码、本机策略及文件 book_id 一致；只读 SQLite 核对 import_jobs 仅剩当前任务。离页前已创建的迟到任务完成后没有残留 job／来源记录，未创建的取消请求不改策略；失败释放占用且不创建导入。模拟器 Debug 构建、5 项单测与 1 项深浅色菜单 UI 回归通过；正常数据找回和来源容错继续通过。证据 `build/EncodingDetection/{restart-final.log,restart-final.xcresult}`，未操作手机。

## 2026-10-17 正文编码识别与手选分组

直接导入与渐进导入共用 Rust 的 BOM → 不含 ESC 的合法 UTF-8 → chardetng 1.0.0 探测器，最多 64 KiB 样本加 1 字节 EOF 探查；真实 EOF 严格校验，仅 64 KiB 上限截断的 UTF-8 多字节前缀不算错；含 ESC 的输入交给 chardetng 识别 ISO-2022-JP。GBK 猜测统一用 gb18030，其他采用 encoding_rs 名称；不传 TLD/系统语言，不增加 fallback，严格解码及 normalization-v1 未改。原来直接导入失败后整书重试的路径已删除。38 项手选编码按六组展示，排除 replacement/x-user-defined 及其别名，固定原生菜单顺序，中英文文案同步；新依赖许可随 App 分发。

14 个原创样本在测试运行时生成输入字节，两条真实导入路径均核对识别名称、规范正文、SHA 与原件不变；既有简体 GB18030 固定 SHA 回归仍通过。Nix Rust 测试 89 项通过，原有 1 项长书性能测试忽略；Clippy（all-targets/all-features，-D warnings）、fmt、`git diff --check` 通过。iOS 27 模拟器 Debug 构建与 6 项定向单测通过，覆盖全部手选项/英文文案、回收重开、暂停移动后恢复/重启、首选副本与许可。新增 UI 用例通过，实际经历失败页→分组纠正为 UTF-16LE→进入正文并推进有效阅读位置，兼容当前滚动/分页偏好；截图已人工核对。

自动识别样本保留 EOF 短 windows-1252（以 é 结尾）与 ISO-2022-JP，共 16 个原创样本；删除手写无 BOM UTF-16 探测及其两个自动识别样本、专属启发式测试。原 14 项内容与预期、旧简体固定 SHA 不变。无 BOM UTF-16 需手动选择，识别能力以 chardetng 为准，不自建启发式。失败页 UI 夹具不再预设错误编码，直接验证自动导入失败后手选 UTF-16LE/BE。Nix 核心回归 90 项通过、1 项既有性能测试忽略；Clippy（all-targets/all-features，-D warnings）、fmt 与 diff 检查通过。iOS 27 模拟器 Debug 构建及 2 项定向单测、2 项 UI 恢复测试通过：两种字节序均在自动导入失败页看到更换入口，确认手选后显示正确正文并推进有效阅读位置；另覆盖全部分组与回收重开后的手选策略。失败页和恢复正文截图已核对。证据：`build/EncodingDetection/{no-heuristic-rust.log,no-heuristic-clippy.log,no-heuristic-fmt.log,no-heuristic-swift.log,no-heuristic.xcresult,no-heuristic-screens/}`。本轮未操作真机。

额外尝试的旧 `testFirstImportReadsBeforeCompletionAndCanPauseResume` 未通过；干净 main `42548d1` 同用例也失败于等待 scrollText，本分支初次失败在封面上的进度断言，不能将两个断言处的失败称为同一已证实根因。旧用例保持不变、不计入通过，本轮不扩修其固定阅读模式/封面假设。基线工作树已移除，证据保留在 `build/EncodingDetection/{baseline-ui.log,baseline.xcresult,swift-tests.log}`。

用户确认尚未发布，允许本次改变旧开发版结果；统计不足的极短 GBK 单字 D6 D0 按固定库识别为 windows-1252，已固定断言，用户可手选。发布后升级识别库须保持样本和已支持文件的正文身份不变。手选策略仅在本机文件行和任务描述保存，不经 CloudKit 同步，另一台设备可能需要手选相同编码才能得到相同正文 SHA；本轮只核对代码，未做跨设备或真机验证。日志与最终截图：`build/EncodingDetection/{rust-tests.log,clippy.log,fmt.log,menu-confirmed.log,screens/}`。

## 2026-10-17 发布持久化基线与逐条容错

完成发布冻结第 2、3、4、5、9 项：连接、共享授权和用途默认值逐条读取，坏会话不影响其他会话；日志只含集合键/行序号，不含 JSON、凭据或正文。读取不回写，保存时保留不可识别条目并按稳定 ID/用途键更新可识别项，显式删除与清除字段仍有效。用途默认值读取此前键值数组与字符串键对象，保存为对象；JSON 整体损坏则拒绝覆盖。授权撤销的 generation 仍生效，未知授权不能恢复已撤销权限。

SQLite 以 v20 为支持基线，逐级事务入口正式步骤为空；测试用模拟步骤验证顺序、失败回滚和继续升级，ReaderCore 入口验证高低版本拒绝且版本号/原库保留。无自动清库或删除重装提示。阅读设置 Tab 存储值为稳定英文，旧开发中文值按本轮决定不迁移；App Debug/Release 版本均为 1.0.0，构建号仍为 2（后续上传单调递增）。AGENTS 与相关专题改为发布兼容规则，正文算法和 normalization-v1 身份未改。

Nix 中 3 项迁移单元测试、9 项 ReaderCore 回归通过，`cargo fmt --all -- --check` 与 Clippy（all-targets/all-features，`-D warnings`）通过。Xcode 27.1 / iOS 27.0 模拟器 Debug 构建通过，25 项不同 Swift 定向测试通过（首轮 24 项，补测 3 项含 2 项重复）：逐条容错/原始条目与未知字段保留/损坏容器拒绝覆盖、共享授权撤销、坏会话留存、Tab 标识、版本错误中英文、用途默认值、阅读预览及许可资源。实际构建产物的 CFBundleShortVersionString 已核对为 1.0.0。`git diff --check` 通过。

证据在本机 `build/ReleaseFreeze/{rust-migrations.log,rust-reader.log,clippy.log,swift-tests.log,swift-final-tests.log}`。首次 Swift 尝试遇到 Xcode 更新后模拟器服务版本不匹配，系统组件初始化完成后重跑通过，环境失败留在 `swift-tests-environment.log`；未重置模拟器或操作真机。未部署 CloudKit 生产 schema；同步 payload 前向兼容的追加实现与验证见下一节。

## 2026-10-17 同步 payload v1 与隔离边界

Swift 存储边界统一校验顶层整数 v、完整键集合和嵌套类型；兼容默认字段白名单为空，Optional 显式编码 null，未知 key 保留且不进入投影或 pending 转移。存在无法理解的候选时不以较新 v1 降级替代：位置写入/压缩、批注编辑/合并/删除、统计清除及 pending 转移/删除均按作用域阻断。无法解释的统计清除阻断相应展示；无法解释的事实保留并提示统计不完整。未知阅读状态保留原字符串并显示“其他（当前版本不支持）”，仅显式改状态时替换；封面同 id 字节不可变。

Xcode 27.1 / iOS 27.0 模拟器 Debug 构建及 47 项定向测试通过（UserDataTests 33、AIReadingToolsTests 13、本地化 1）；另 1 项 pending 已转正后迟到未知记录的补测通过，验证不能绕过快速路径、泄露旧位置或释放待转移身份。矩阵覆盖两种到达次序、完整 null 与缺键区别、未知嵌套字段、错类型、大整数精度、真实保存服务入口、书目编辑和统计界面的旧内容隔离。首轮发现 resolve 把隔离误报成普通冲突，已提前检查并复跑通过。Nix 中 1 项状态往返和 8 项 user_projection 测试、Rust 格式检查与 Clippy（all-targets/all-features，-D warnings）通过。

每次打开的兼容提醒只自动呈现一次；确认后刷新批注、翻页自动保存、后台/退出保存不再重弹，预览导航仍可继续；主动更改阅读位置失败仍说明原因，重新打开重新提醒。新增真实 ReaderSession 用例连同 UserDataTests 35 项及退出冻结回归 1 项通过（共 36 项），Debug 构建与 `git diff --check` 通过，证据 `build/ReleaseFreeze/Sync/notice-regression.log`。

证据：`build/ReleaseFreeze/Sync/{final-regression.log,pending-alias-test.log,rust-checks.log}`。这些用例在本机模拟独立记录到达，不代表真实双设备 CloudKit 同步验收；未操作真机或部署生产 schema。发布前旧开发编码不兼容，按用户决定由开发者删除重装开发版并清理开发环境数据；应用不会自动清库，发布后的兼容规则不变。

## 2026-10-17 政策与支持站迁入主仓库

`build/SiteDesign` 的配置、content、templates、static 迁入 `docs/site/`；正文、样式和图片不改，仅将支持页两处旧站政策链接改为 Zola 内部链接。public、preview、空 sass 不纳入源码，构建产物已忽略。正式根地址改为 `https://suxiaoshao.github.io/moonread/`，App 中英政策／支持链接与现行文档同步；旧 moonread-site 记录标为历史迁移，注册 OAuth App 的地址待公开切换后在 GitHub 设置更新。

项目 Nix devShell 提供 Zola 0.23.6，现有 flake.lock 无需变更。`zola build`、`zola check`（含外链）通过，生成页面 76 处本地链接／资源目标全部存在；actionlint、nixfmt、`git diff --check` 通过。iOS 27 模拟器 `AppStorePrivacyTests` 4 项通过，包含中英文政策／支持 URL 断言，Debug 构建通过。证据：`build/SiteInRepo/{zola.log,local-links.log,workflow-check.log,app-links-tests.log}`。

Pages 工作流仅配置并通过语法检查，未启用 Pages 设置、未修改仓库可见性、未部署新站；新 URL 在线可达性待仓库公开后验收。旧站在新站上线验证后由用户确认删除。本轮未操作真机。

## 2026-10-16 公开前当前树清理

真实书名、作者、私人阅读关联及会话数量从公开记录移除，历史测量采用匿名样本和近似大小，保留性能数字及热缓存等局限，不将历史实测改称为原创夹具。资料审阅、封面提取与书架搜索使用虚构元数据；诊断开书入口只生成原创样本，不再打开用户数据库查找原件。封面回归改为离线原创 HTML 与程序生成 PNG，经生产获取／暂存流程校验，不再请求第三方书站或分发其封面。本机绝对路径和模拟器标识已移除；原始审计、截图、数据库和构建证据仍只在忽略的 `build/`。

根 MIT 许可与第三方声明已补齐：9 个 Swift 包、Cargo.lock 的 180 个 registry 包（包括工具／测试／非 iOS 依赖，并非全部进入 iOS 二进制）、12 款 SwiftMath 字体、LobeHub 和 Pi 许可、开发用 SwiftUI skill。完整文本作为 `ThirdPartyNotices.txt` 分发；MPL 对应版本源码取得方式见根第三方声明。11 张来源未闭环的中间 SVG 替换为 LobeHub 1.95.1；24 张服务商图标路径和 viewBox 全部与固定来源一致，证据 `build/OpenSourcePrep/icon-provenance.json`、`provider-icons.png`。商标权不随 MIT 转移。

Rust 封面提取 5 项及书架搜索 1 项通过，严格 Clippy 与 rustfmt 检查通过（`build/OpenSourcePrep/{rust-cover,rust-search,clippy-final,rustfmt}.log`）。模拟器 45 个不同用例通过：AIFollowUp 36、附件渲染 1、AppStorePrivacy 4、UI 4；覆盖原创封面回放、资料审阅／改名、许可资源／公开链接／SQLite、图标选择和原创开书诊断夹具。正常 Debug 与 READER_OPEN_DIAGNOSTICS 构建均通过，App 中许可资源与源码逐字节一致；截图 `screens/settings-about-public-links.png`、`release-screens/provider-picker.png` 已核对。最终成功日志为 `affected-final-tests.log`、`public-resources-diagnostics-tests.log`、`release-tree-final-tests.log`。首轮曾在结果归档滞留，停用额外诊断采集后同组复跑正常成功，不依赖被停止命令的退出状态。当前树导出 Gitleaks 扫描未命中（`gitleaks-current-tree.log`）；该扫描不覆盖 Git 历史、GitHub 正文或旧运行日志，不作全仓历史无泄露保证。

2026-10-16 用户将公开联系邮箱改为 `suxiaoshao@gmail.com`。App 联系入口、测试、发布说明及政策／支持站同步更新；四个正式政策／支持 URL 和首页已核对 HTTP 200、新邮箱存在且旧邮箱不再出现，证据 `build/OpenSourcePrep/site/`。欧盟 DSA 商家邮箱修改另行处理，本轮未改。Codex 认证保留现状，#18 官方 SIWC 与 iOS 本机回调验证是仓库公开前的独立前置项；本轮不处理历史或 GitHub 设置，也未操作手机。

许可全文可从“设置 → 关于月读 → 第三方许可”打开，支持滚动、选择文字、动态字号和深色，页首提供 12 个 MPL 组件的具体版本源码链接。随包 TXT 的说明改为面向用户，不再要求查找仓库文档。独立 worktree 使用自己的 `build/DerivedData`，受影响单元与 UI 共 2 项通过：逐字节重组全文、链接版本与资源一致；UI 覆盖浅色、深色 AX XL 和英文的入口及正文加载。日志 `build/OpenSourcePrepReview/tests.log`、截图 `screens/third-party-licenses-{light,dark-ax,en}-{sources,text}.png`（均位于该 worktree 的证据目录），已目视核对；不重复无关全量回归。

Large 开书诊断样本保持原 20–30MB 档：运行时重复原创段落 285,715 次，UTF-8 共 24,000,060 字节（十进制约 24MB），不提交大文件；生成与原子写入在后台执行。已有不足 24MB 的隔离夹具会重新生成。READER_OPEN_DIAGNOSTICS 构建及大小／段落结构断言通过（1 项），证据 `build/OpenSourcePrepReview/large-fixture-tests.log`。该验证只证明夹具大小与构建，不是新增性能测量。

## 2026-10-16 ChatGPT 官方 SIWC

连接卡片与模型选择弹窗现在统一调用“已登录且已授予套餐 scope”的展示判断，needsLogin 即使仍有旧 scope 也不显示套餐标识／用量入口。原生搜索不再丢弃 SDK error 事件底层错误：ChatGPT 的 code、param（对应工具错误 field）与本地化说明保留至 Agent 输出，401 沿用确认失效处理；取消传播，非 ChatGPT 保持通用错误。移除暂存资产清理后重复包装错误的路径，统一在原生执行边界分类。

模拟器 Debug 构建及 44 项定向回归通过（42 单元、2 UI），日志 `build/ChatGPTSIWC/plan-badge-native-errors-tests.log`。新单元覆盖未登录／未授权／已授权／needsLogin 的共用展示规则；通过真实 SDK 流式事件路径覆盖 ChatGPT 流内及非 2xx structured failure、非 ChatGPT 通用错误、结构化／纯文本 401 的 token 清理和注册保留、重复调用不联网及取消传播。回归原生工具、认证和用途／容量选择 UI；仅注入 transport 与合成凭据，没有真实服务或手机操作。

非 2xx Responses 的结构化 `error.code/param/message` 与流内错误统一分类；非结构化错误在读取后重建相同正文供 SDK 保留原 HTTP 错误。目录 401、Responses 401（含非结构化正文）与 refreshExpired 共用确认失效入口，清当前会话 token、保留注册身份／client／scope、移除已认证标记并更新 needsLogin；取凭据在 await 前后都检查失效状态，迟到目录成功不恢复失效会话。只传递会话指纹用于匹配，旧请求 401 不得清理新登录。

2026-10-17：模拟器 Debug 构建及 38 个不同定向用例通过（36 单元、2 UI），包括非 2xx SDK 错误 code／param／message、原始正文回退、目录与 Responses 的 401 清理和注册保留、失效准入、重复失效幂等及旧 401／新登录竞态；仍覆盖六码终止刷新恢复。第一批日志 `build/ChatGPTSIWC/http-errors-session-tests.log`，最终 await 后准入与目录守卫改动另复跑 25 项相关单元，日志 `http-errors-session-final-tests.log`；没有削弱断言，没有真实服务请求或手机操作。

终止性 refresh 恢复覆盖官方六个错误码：刷新时的 `invalid_grant`、`invalid_refresh_token`、`token_expired`、`refresh_token_expired`、`refresh_token_invalidated`、`refresh_token_reused`。只清理匹配该次刷新旧 token 的凭据，并保留不含 token 的 client／身份／已授予 scope 注册映射，所有请求入口同步更新 needsLogin；迟到旧错误不能清掉新登录。`invalid_client`、网络和临时服务错误保留凭据。普通退出保留 scope 选择，重新登录不强制同意，只有未授予套餐授权时才强制；删除连接在同一次退出操作中同时删除该连接 registration 与内存 client 映射。套餐标识只取已授予的 direct scope，身份登录不等于获准使用套餐。

`response.failed` 与 `error` 保留原始 code／param，按官方账户资格、能力、路由、身份／授权上下文及临时不可用分类显示；未知 code 也保留，不误报为“回复未完成”，不自动重试未改变的请求或切换计费。模拟器 Debug 构建及 35 项定向回归通过（33 单元、2 UI），日志 `build/ChatGPTSIWC/terminal-recovery-tests.log`；覆盖六码清理和 needsLogin、临时错误保留、旧刷新与新登录竞态、退出与删除的注册生命周期、scope 标识，以及九类官方 Responses 错误和未知码在 SDK buffered 路径中的 code／param 与单次请求。UI 回归覆盖无痕取消／loopback 完成及账户容量。本轮仅合成 transport／凭据，不操作手机、不做图片测试。

登录浏览器现统一为 `ASWebAuthenticationSession`，在 start 前开启 ephemeral，展示锚点使用登录页实际窗口。用户真机反馈 SFSafariViewController 的独立持久 cookie 使多个 Google 账号无法切换，因此删除该生产路径；每次重新登录使用无痕会话，仍由随机端口 loopback 收码，浏览器的自定义 callback scheme 不参与 OAuth。校验回调后先通知界面关闭浏览器，再继续换 token。应用主动关闭不覆盖成功结果；用户关闭 ChatGPT 窗口则终止尝试并显示“已取消登录”。OpenRouter 仍使用同一无痕浏览器，按既有无回调 PKCE 契约在关窗后保留粘贴代码入口，应用内取消才结束授权。

模拟器 Debug 与正常签名真机 Debug 构建通过。21 个不同受影响用例通过（17 个认证单元、2 个连接单元、2 个 UI）；新增测试覆盖 ephemeral 设置、当前窗口锚点、主动关闭后迟到取消不覆盖结果、用户取消／启动失败、旧尝试隔离，以及 loopback 通知先于尚未完成的 token exchange。UI 使用 DEBUG 下本机合成授权页实际驱动系统 ASWebAuth，验证关闭、取消提示、重试、点击网页完成后主动消失、连接页可继续操作与欢迎提示；无真实服务授权。最终日志 `build/ChatGPTSIWC/{ephemeral-browser-final-tests,ephemeral-browser-openrouter-regression}.log`；截图 `ephemeral-browser-screens/` 的 manifest 已对应到成功后界面并目视核对。真机包日志 `build/ChatGPTSIWC/Device/ephemeral-final-build.log`，多 Google 账号的实际选择仍由用户自行登录核对。

“ChatGPT 账户”替代旧 Codex 设备码与私有网关：动态注册、稳定 host ID、PKCE/state/nonce、随机端口 `127.0.0.1/auth/callback`、公开 JWKS RS256 与 issuer/audience/azp/expiry/nonce/sub 校验，凭据仅存 Keychain。无效回调不消费机会，旧尝试不能删除新尝试；退出先关闭准入、等待已有刷新原子保存，再撤销最新 refresh token。网络或 5xx 撤销有限退避重试；未确认撤销则保留本机凭据并明确报错，不声称已退出。

OAuth 回调先验证 state；首次动态注册的拒绝或其他错误不要求 `client_id`。`access_denied` 结束本次尝试，本机回调页返回 HTTP 200“已取消，可以返回月读”，应用显示“已取消登录”；其他 OAuth 错误显示授权失败。错误 state 返回 404 且仍可接收该尝试后续的有效回调，不交换或保存凭据。中英文文案均已提供。 Rebase 后模拟器 Debug 构建与 28 项定向回归通过（26 单元、2 UI）；新增用例通过真实本机 HTTP 回调覆盖首次注册拒绝、其他 OAuth 错误、错误 state 后继续及尝试清理，其他回归覆盖签名／刷新／退出／协议回放／目录／容量与浏览器关闭。日志 `build/ChatGPTSIWC/{oauth-refusal-tests,rebase-contract-tests}.log`；无真实授权请求，未操作手机。

令牌交换成功但未授予 `chatgpt.tokens.use.direct` 时，先验证 ID token，再在 Keychain 保留账户与签发 client 映射；套餐使用单独禁用，连接页提供“你没有允许月读使用 ChatGPT 套餐”与“重新授权”。主动恢复沿用已保存 client 和完整 scopes，以 `prompt=consent` 请求同意；普通登录不强制同意。账户目录使用连接持久快照，自动检查同样遵守 24 小时窗口；并发检查不重复请求，手动刷新强制获取，失败保留旧快照且不循环自动重试，退出清除该连接快照与检查状态。

模拟器 Debug 构建及 30 项定向回归通过（28 单元、2 UI），日志 `build/ChatGPTSIWC/consent-and-catalog-tests.log`。新用例覆盖未授予套餐许可后的身份／client 持久化、重建认证服务后沿用 client 与完整 scope、未授权不发目录或推理请求；目录覆盖重入／重载命中、过期后台刷新、并发检查、手动强刷和失败保留。既有认证／协议回放／公开目录缓存／浏览器完成及手动关闭／容量 UI 回归通过。仅使用合成凭据与注入 transport，未做真实授权或操作手机。

账户目录只使用 `visibility=list`、精确 slug 和服务端顺序，不加入 Pi 型号。缺少容量时，按用户确认，仅可给已有型号编辑“上下文预算”；刷新保留，目录后来给容量则替换并提示，隐藏／移除型号不会复活。图片输入缺少明确能力证据时保持未知并禁用附件，待用户真机登录核对真实字段；图片生成在设置及请求边界禁止，其他 API Key 通道不变。公共 Responses 每次 `store=false/stream=true`，函数工具使用 moonread namespace，历史调用同步带 namespace；SDK 摘要调用仍在网络上使用 SSE，只把 completed 终态适配回 JSON。失败、不完整或无 completed 不算成功，用量错误提供安全文案和 ChatGPT 用量入口。

模拟器 Debug 构建通过，分批受影响回归覆盖 110 个不同用例，最终各用例均通过（汇总 `build/ChatGPTSIWC/test-summary.json`）。使用合成凭据与运行时生成 RSA 密钥，无真实 OpenAI 授权／推理请求。定向认证覆盖无效 state 后继续、旧尝试、一次消费、签名与各声明、granted scope、刷新、退出中拒绝新工作、账户预算、SSE 终态及 SDK 摘要编码／解码；回归已有 Agent phase、四协议工具往返、原生服务及共享同意。首轮受影响回归中旧设备码夹具的模型失败用例未通过，已改为正确的已认证目录夹具并复测通过；旧 UI 对验证码的断言也改为仍等待授权的实际按钮状态，浏览器完成／手动关闭回归通过。各批日志在 `build/ChatGPTSIWC/{affected-tests,ui-and-final-auth-tests,final-auth-and-browser-tests,contract-final-tests,delivery-tests,route-final-tests}.log`，以各用例最后的运行结果为准。

截图 `build/ChatGPTSIWC/screens/{approved-login-providers,chatgpt-context-budget,chatgpt-plan-welcome,native-purpose-settings}.png` 已核对。此前临时浏览器→loopback 合成小试验分别覆盖 ASWebAuthenticationSession 与 SFSafariViewController，此前生产实现曾选后者；按用户多账号反馈现改为前者的无痕会话，探针代码已丢弃，证据仅留 build。用户随后在 iPhone 13 验证真实 ChatGPT 登录与普通回答正常，目录显示 5.6–6.1 并自动返回上下文容量，未触发手填。该用户验收不覆盖刷新错误／撤销恢复或分发许可；当前应用没有图片输入入口，本轮不安排真机图片测试。旧 Codex 开发配置不兼容、不迁移，未主动清空旧 Keychain 凭据。

## 2026-10-16 精简订阅登录

Copilot 连接、认证枚举、交换 token、动态请求端点、目录解析／内置数据及图标直接删除；Kimi、Meta、xAI 设备码、刷新和专用 token 交换也删除。认证只保留 API Key、暂保留的 Codex 与 OpenRouter PKCE。Kimi 国内／国际会员 API Key、Meta API Key、xAI API Key 及 xAI 原生搜索／图片通道保留；Kimi 页面提供官方控制台与适用范围说明。没有旧连接迁移或兼容分支：含已删除认证值的旧开发连接配置不兼容，需重新配置 AI 连接，未主动读取／清空凭据。Codex 登录未改官方 SIWC；GitHub OAuth App 未删除，未继续设备码或 token 测试。

同一 iPhone 18 Pro／iOS 27 模拟器，正常项目 Debug 签名测试构建及 94 项定向回归通过：AIStageOne 60、ProviderContract 10、NativeTools 15、DataSharingConsent 7、UI 2。新增验证剩余认证集合／旧值不可构造、Kimi 两地 key 预设、非 Codex 不能进入设备码流程；回归 Codex 设备码／目录、OpenRouter 单次 PKCE、xAI API Key 搜索／单多参考图、API Key 配置与内容共享。UI 确认登录选择仅 Codex／OpenRouter，Kimi 引导／控制台链接可见且无登录按钮。内置目录结构比对确认仅移除 github-copilot，其余供应商数据不变。

日志 `build/RemoveCopilot/targeted-final-tests.log`，结果 `build/DerivedData/Logs/Test/Test-Moonread-2026.10.16_16-25-37-+0800.xcresult`；截图 `build/RemoveCopilot/screens/{approved-login-providers,kimi-membership-api-key,overview}.png`，已人工核对。首轮编译因删除 Copilot 后误把仍需追加 OpenRouter／Baseten headers 的变量改为 let 失败，恢复其可变性后上述最终回归通过。仅合成数据与注入 transport，无真实服务权限、付款或真机验收，未操作手机。

## 2026-10-16 上架准备

隐私清单加入 App Resources，按方案声明三个 required-reason 类别及五项可选 AI 数据流；SDK 最小 fork 为 `suxiaoshao/swift-ai-sdk@9843cba`（原 c82deb2）和 `suxiaoshao/Litext@c1d74fe`（原 3.6.4），各只加清单与 Package 资源。上游当前树无清单，检索证据 `build/AppStorePrep/*upstream-tree.json`。不升级其 API。

iOS 使用系统 SQLite，其他 Rust target 保留 bundled；Xcode 显式链接 sqlite3。Rust 数据库 22 项通过（`rust-database-tests.log`）；App 清单、WAL／外键／RETURNING／并发读取、单书投影、暂停导入 4 项模拟器定向测试通过（`privacy-database-final.log`）。iOS 27 SQLite 为 3.54.0；App 和两个 SDK bundle 均有清单，otool 确认系统 libsqlite3。仅安装 iOS 27 运行时，iOS 18 实际版本／运行验收仍为发布前缺口，不能由新系统测试代替。

AI 内容共享预检、运行时／摘要及原生服务接入同一许可服务。受影响 AI／UI 125 项通过（`consent-integration-tests.log`），实际发送前零内容请求、拒绝保留草稿、许可后单次发送，以及失效／撤销／多 owner 均覆盖；等待状态／摘要门槛补测 8 项通过（`consent-state-final.log`）。中英、应用浅深色、辅助功能 XL 确认页实际截图 `build/AppStorePrep/screens/`，按钮可达、非空无障碍 label 与拒绝后草稿断言通过；未把 AX 自动化当成实际 VoiceOver 朗读验收。仅合成内容和注入 transport，无真实服务／账户／手机。

许可页布局补测：底部 safeAreaInset 固定两个全宽按钮，正文独立滚动；只保留导航标题，接收服务／host 与次要 endpoint 集中展示，仅按当前 scopes 展示紧凑图标列表，政策 Link 使用强调色。图标占位随字号缩放。受影响 UI 用例四场景（浅色、深色、英文、英文 AX XL）最终复跑通过，断言两个按钮初始无需滚动即可点击、宽度超过视口 85%、均在窗口内、正文滚动前后按钮 minY 变化 ≤1pt，以及拒绝保留草稿。日志 `build/AppStorePrep/consent-fixed-actions-final-tests.log`，最终截图 `screens/consent-fixed-actions/ai-sharing-{light,dark,en,en-ax}{,-actions}.png`，对照 `overview.png`；实际截图核对按钮与文字无裁切，不代替真实 VoiceOver 朗读。

关于页显示正式政策／支持链接和公开联系邮箱 suxiaoshao@gmail.com。四档消耗型商品为 star／tea／snack／book，USD 基准价 0.29／0.99／2.99／6.99，本地 StoreKit 配置为美国 storefront，实际界面使用 StoreKit 的本地化价格。新增一颗星和说明后，14 项 TipJarTests、3 项隐私／链接测试、1 项本地 CloudKit 模型检查，以及 4 项 UI 回归共 22 项通过（`build/AppStorePrep/public-release-prep-tests.log`）。UI 验证购买、重启、深色／AX 大字号、公开邮箱和独立 schema 页面；浅深色及各配色渲染附件为 `final-attachments/`，精选截图 `screens/final-public-ui-overview.png`。StoreKit 本地成功不代表 App Store Connect 商品或沙盒付款已配置。

许可服务补充真实解析 account ID 的不可逆指纹和凭据变更前失效；不保存凭据或原始 account ID。补测账户切换、首次预检、摘要门槛、原生服务及本地模型／隐私共 29 项通过（`prep-final-tests.log`）。只改变内容共享许可失效，不调整订阅登录连接的去留或认证协议。

网站四页与简单首页经用户审阅授权后发布，独立公开仓库 `suxiaoshao/moonread-site` 提交 `aa88d9f`；只含 HTML 与 .nojekyll。历史四个 URL（现已迁移，旧站暂保留）为 `https://suxiaoshao.github.io/moonread-site/{privacy,support,en/privacy,en/support}/`，逐页 curl HTTP 200、正文／日期／公开邮箱核对通过（`site-verification.json`、`site-live-*.html`）。生效日期 2026-10-16，署名 © 2026 suxiaoshao，无分析脚本、第三方字体或登录；可选 AI 第三方发送在政策中单独披露。首发地区实际网络可达性仍需最终发布验收。

CloudKit 准备入口只在 DEBUG 编译，显式启动参数进入独立检查页，不启动正常书架存储流程；模型从同一六类 SwiftData schema 生成，封面 bytes 的 external storage 由单元测试核对。初始化开发 schema 代码使用隔离临时 store，完成后卸载；本轮仅本地 report 与结构测试，没有执行开发库写入或生产部署。部署清单见 `docs/dev/data/cloudkit-release-checklist.md`，Console 权限／索引与真实跨设备生产同步留给发布验收。

正常 Release 未签名本地归档通过（`release-archive.log`、`Moonread.xcarchive`），无 READER_OPEN_DIAGNOSTICS。最终 App 含 App／SwiftAISDK／Litext 三份清单，最低部署值 18.0、系统 libsqlite3 链接、无 statfs／fstatfs 未定义符号、无 benchmark 符号（`release-artifact-audit.json`）。共享 SwiftPM mirror 统一 Litext 根与 MarkdownView 传递依赖到最小 fork，最终解析和归档无 conflicting identity 警告。Xcode Organizer 已生成 `Moonread-PrivacyReport.pdf`，文本与渲染核对包含五项、均为 App Functionality／Linked YES／Tracking NO，与清单工作表一致；报告本身不验证理由用途或真实服务行为。未上传、未签名分发、未操作手机。

## 2026-10-16 主题化引导与支持月读

三条 TipKit 提示共用 ThemedTipStyle/ThemedTipCard：背景 surface、文字 ink、关闭与图标 secondary、同页卡片的 border；书架继承应用主题，阅读提示继承阅读主题。使用指南各节同样使用主题卡片与显式 ink 标题，不改变指南文案或提示资格。

提示卡片的文字与 44pt 关闭按钮现为垂直居中，已目视核对单行与两行提示。关闭／动作消失回归各两次通过（`build/TipJar/tip-alignment-{light,dark}.log`）；显式保存应用与阅读器浅深色后、同会话启用 TipKit 的六图用例通过（`tip-alignment-explicit-final.log`），实际截图 `build/TipJar/alignment-screens/`（三处提示各浅／深色，`overview.png` 为对照）。初次截图试验先启用提示再离页配置外观，触发一次性资格而失败；改为先配置主题再启用提示，不改变生产资格规则。

商品读取由 TipJar 持有单一 Task，与视图 `.task` 的取消无关；未 ready 的页面重入等待已有读取，没有读取时才新建，完成后原子更新 ready／unavailable 并释放任务。旧的取消回 idle 路径已移除。五项定向测试通过（`build/TipJar/owned-catalog-tests.log`）：旧页面取消后立即重入等待挂起读取，最终 ready 且只读一次；失败重入重试、缺商品、读取／购买互斥与 ready 不重复均通过。

等待批准状态限定为打赏页本次停留：同商品重试先清除、离页全部清除，旧停留的迟到 pending 不重新加入；后台批准仍完成交易并感谢。五项定向 StoreKitTest 通过（`build/TipJar/pending-review-tests.log`）：重试、离页／迟到结果、实际 Ask to Buy 被拒且无批准交易时不残留、离页后批准、取消／失败。中英文提示同步改为“已请求批准，批准后会自动完成”。

设置最后一组新增“支持月读”。StoreKit 2 读取三个消耗型商品的本地化名称、说明与 displayPrice；购买中全部价格按钮暂停，取消静默、错误行内重试、批准中保留提示。应用根监听 Transaction.updates 并处理 unfinished，只有 verified 且匹配打赏商品的交易才 finish 和短暂感谢；金额、次数与历史不写入应用存储。重复回调仅在内存去重，月相复用现有减弱动态规则。共享 scheme 的 Debug Run 已选择 TipJar.storekit。

验证设备为已有 iPhone 18 Pro／iOS 27 模拟器，使用 build/DerivedData。StoreKitTest 必须采用本机验证成功的模拟器 ad-hoc 签名配置 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-`，不使用 Apple 账户或个人签名；无签名首轮取商品为空，记录在 `build/TipJar/unit.log`，签名后的商品与重复购买通过 `catalog-signed.log`。

- `build/TipJar/final-tests.log` 中 6 项 UI + 9 项单元共 15 项零失败、TEST SUCCEEDED。打赏 UI 显式切换应用浅深色后再次 2 项通过（`appearance-final.log`），已覆盖旧的继承外观截图。正常 Release 模拟器完整构建通过（`release-build.log`）。9 项 StoreKit/状态/渲染单测覆盖：商品类型与当地价格、重复消耗型购买、取消的结果及错误边界、购买失败、未验证交易不 finish/感谢、后台批准完成、商品读取失败重试、缺少商品、购买/加载互斥与全部状态截图。取消错误注入在 Xcode 27 被包装为不认识的 ASDServerErrorDomain 907；未向生产代码添加错误码分支，取消契约以 PurchaseResult.userCancelled/StoreKitError.userCancelled 验证，其他失败与交易流程使用真实 SKTestSession。
- 渲染矩阵在模拟器 UIHostingController 中生成：6 个内置配色 × 普通/辅助功能字号 × 三提示卡片/指南/打赏页，加加载、购买中、等待批准、错误、感谢、读取失败的浅深色/大字号及减弱动态，共 61 张。`build/TipJar/renders/`；这是托管视图渲染，三提示并排样板不代表实际同时出现。实际 App 引导与打赏 UI 截图为 `build/TipJar/screens/`，通过的 UI 用例包含新书架、指南浅深色/大字号、提示按动作消失和重启不再出现、打赏入口/三档价格/感谢/重启清状态。
- 额外实际取消付款框试验未通过：关闭自动确认后仅保持“正在付款”，截图中系统付款框并未出现，无法点击取消（`ui-corrections.log`、`screens/tip-jar-purchase-sheet.png`）。不将此记为取消 UI 已通过；该试验不保留为不可运行的回归用例。真实 App Store Connect 配置、真机沙盒完整付款及实际取消仍待开发者验收；本轮未操作手机、未输入或读取账户凭据。

## 2026-10-16 首次使用引导

使用指南为原生说明页，从设置和内置空书架进入，不创建小说、阅读进度或统计。文案按现有界面核对：跨页选取需在终点再次长按并选择拷贝／“批注到这里”；书签和批注在“更多”；小说文件的系统 iCloud Drive 与阅读数据同步分别说明。AI 未连接的现有模型选择页已有“还没有可用模型”“先连接一个 AI 账户并加载模型。”与“添加连接”，本轮不修改 AI 引导。

三条原生 TipKit 提示分别覆盖首次导入、显示阅读工具和长按选字，关闭或完成动作后不再显示。导入提示采用工具栏下方原生 TipView；模拟器中菜单的 popoverTip 在已符合资格时仍未展示，未保留双路径。阅读提示按实测高度保留正文视口，独立断言正文 frame 不超过提示顶边。普通 UI 测试统一关闭提示，专用用例使用隔离本地提示记录。

内置根发现状态在本地首页发布前确定；首次完成的元数据快照（包括空快照）经交接、实际目录扫描采用及页面目录读取后才允许显示“还没有小说”。发现中、失败、超时均不把未知当空；账户代次、根变化与快照 revision 拒绝迟到结果，允许失败后重试与超时后新快照恢复。本地已有内容在云发现期间仍显示。

- iPhone 18 Pro／iOS 27 模拟器定向验证通过。`build/Onboarding/accepted-tests.log` 8 项通过，覆盖四种独立新会话（无云欢迎书、云空、云有书、本地有书且云待发现）、指南大字号、两条阅读提示及导入提示关闭持久化、发现采用／错误／代次／超时等单元测试。
- `final-appearance-regression.log` 8 项通过，覆盖显式浅／深色指南、提示与正文空间、返回／面板／选区／分页回归及首页快照和选区菜单。测试夹具的内存 ModelConfiguration 显式关闭 CloudKit，避免隔离测试触发系统无连接异常；返回回归明确先选择滚动模式，所有既有断言保留。
- 目录读取成功和失败均使用请求开始时捕获的账户代次；旧代次失败不得使新代次变为不可用。新增及相关 3 项单元回归证据：`build/Onboarding/stale-directory-review.log`。
- 发现状态最终定向复跑 3 项通过（`build/Onboarding/discovery-final.log`）；正常 Release 模拟器完整构建证据为 `release-build.log`。
- 最终截图：`build/Onboarding/screens/`，包括 `onboarding-guide-{light,dark,ax}.png`、滚动后截图、三种新安装及本地待发现、云发现占位、三条提示。仅合成 TXT。真实账户 iCloud 发现和真机 VoiceOver 尚未验收；未操作手机。

## 2026-10-16 夜读图标与月光助手

桌面图标、LaunchSeal 和 BrandSeal 统一为深蓝夜空、暖金弯月、星与翻开的书。阅读助手改为固定品牌色的 40pt 深蓝圆盘与暖金弯月，56pt 完整画布可点；六种状态为空闲、正在回答、等你确认、完成、有结果待看与未完成。工具姿态分类、五官、道具、上浮、弹跳及出现时压缩形变全部删除。普通回复／整理上下文为空闲，工具与推理统一工作状态；具体活动仍由既有 VoiceOver 值说明，名称、提示、结果播报及通知时长保持不变。

工作光晕以 3s 周期在 0.10–0.22 间呼吸，完成月相在 0.4s 内渐盈、光晕单次散去并于 900ms 后停止时间线；后台暂停，不可见时由视图生命周期停止。减弱动态时光晕静止、月相直接切换，出现／离开使用 0.15s 淡变，普通模式为 0.3s；没有移动正文或状态跳动。空文件夹、空对话及阅读预览共用空闲绘制。

- iPhone 18 Pro／iOS 27 模拟器：7 个 AIReadingMoonTests、2 个渲染测试与阅读入口／关于页和空文件夹两项 UI 回归通过，最终证据 `build/Moonlight/final-tests.log`。保留原有通知／打开对话／主动停止的断言；新增统一工作状态、光晕上下限与静止月相断言，阅读入口实际验证画布角落点击与拖动。
- 最终正常 Release 模拟器完整 App 构建通过（`release-final-build.log`），最后防闪时序版本的 7 个状态、2 个渲染与入口／主屏两项 UI 用例再通过（`delivery-tests.log`）。参数为设计时长，不作逐帧真机时序结论。
- 主屏定位用例通过（`installed-icon-test.log`），实际桌面图标为「夜读」，不是只检查资源文件。成功渲染附件设置 keepAlways 并具名保存；两项渲染复跑通过（`retained-render-tests.log`）。
- 最终截图 `build/Moonlight/screens/`：`light/dark-still-40.png` 为六种状态依次排列（空闲、工作、确认、完成、待查看、未完成），120pt 放大与 t0.2／t1.5 为中间帧；`moonlight-about-{light,dark}.png`、`moonlight-empty-{light,dark}.png`、`moonlight-reading-idle.png` 与 `moonlight-installed-icon.png` 为实际界面。浅色未完成状态使用直接调暗的品牌色，避免降低透明度反而提亮。
- 启动画面由通过的 XCUITest 会话录屏核对：`ui-launch.mp4`、截取的 `launch-verified.mp4` 与 `screens/moonlight-launch.png`。先前两次独立 CLI 截图夹具出现旧缓存／目录写入错误，失败证据保留，不记为启动通过；没有据此改源码或清理数据。
- 默认位置实际验证为右下，位于标题下方、底部面板上方；旧 `moonlight-reading-idle.png` 是测试主动拖到屏幕 (0.3, 0.35) 后的画面，不能作默认位置证据。新增默认、拖动后与内置“还没有小说”截图在 `build/Moonlight/review-screens/`，分别为 `moonlight-reading-default.png`、`moonlight-reading-dragged.png`、`moonlight-builtin-empty.png`；新内置空状态共用月光空闲 MoonView。
- 外沿改为一次绘制不透明 paper 色底盘并在其后加轻阴影，避免先描边再填充的第二次阴影压暗外沿。浅深色在墨色背景上直接采样的纸色断言保持 ±2 色阶，修前失败、修后通过。最终 7 个状态、3 个渲染与默认位置／内置空状态两项 UI 用例共 12 项通过：`rebase-review-final.log`；整合后的选字 Tip UI 也通过（`rebase-review-tests.log` 对应成功用例，该日志整体因修前像素断言失败，不记为全通过）。正常 Release 模拟器构建证据 `rebase-release-build.log`。
- 仅用现有模拟器与合成 TXT，不操作手机。截图与录屏为本机证据，不提交 build/；没有把状态渲染或模拟器回归记为用户真机验收。

## 2026-10-15 正文空行显示投影与长空白窗口

Rust 保存原文及绝对 UTF-8 范围，以 LF／EOF 确认并合并空白段；保留片段、省略区间、投影锚点、前后取数游标与 revision 在同一快照返回。正文预算 64KiB，单次至多 256 个源块，已确认空白不占正文预算；不再以四个物理块限制可见短段。严格扩展不反向回找，Awaiting／End／Beginning／Deferred 不清空当前可读正文，不自动移动或保存位置；保护完整可见范围与选区，忙碌拒绝不消耗请求去重键。

Swift 的不可变 ReadingText 同时持有显示文本与唯一的分段 TextCoordinates 映射；空白段在显示投影中省略，正文统一 paragraphSpacing，标题保留自身留白。删除旧的 readingBlank、零高度空白 delegate、双行数、空白页合并及 report(end-1) 自动推进，排版版本为 3。保留与空白无关的末尾无字符 extra line fragment 处理。拷贝、原生 copy、选中文字搜索与 AI excerpt 统一按完整原文选区异步读取 Rust 的显示文本范围结果；批注／书签／AI 附件范围仍为原文包络。搜索算法及多行拒绝不变，ReaderService.textRange 仍供原文工具和批注使用。

- Nix Rust core lib 27 项、reading_foundation 7 项通过，1 项既有性能样本忽略；Clippy all-targets、-D warnings 与格式检查通过。覆盖精确 coverage、前后方向、长段空格保留、跨块标题、暂停续读后 LF／正文、仅 EOF 确认、八个短正文岛跨巨量空白。证据：`build/ReaderBlankLines/projection-final-{rust,clippy,format}.log`。
- 单行选区搜索用显示文本命中原文位置，含换行查询仍拒绝；定向用例通过。`projection-selection-search.log` 与 `ProjectionSelectionSearch.xcresult`。
- 原生 15 个空行用例与 12 个受影响 TextLayoutTests 通过，3 个真实 App UI 用例通过。最终证据 `ProjectionOwnedMapFinal.xcresult`、`projection-owned-map-final.log`（统一视图持有映射后的复跑）；上一轮 `ProjectionLineGeometry.xcresult` 亦通过。覆盖 Unicode／映射／复制／预览、位置恢复／选区／分页、完整 Session→Rust→Controller 双向长空白，含滚动和分页停在空白取数游标中途反向、完整可见范围保护、忙碌请求与 Deferred 去重。
- 真实 App 手势覆盖滚动／分页 × 有封面／无封面前进后退；合成末段加长以便真实滚到视口顶部，顶部锚点断言保留。最终截图在 `build/ReaderBlankLines/owned-map-final-screens/`，逐帧取证在 `pixel-anchor-both-directions.mp4`。所有材料为合成 TXT，只用现有 iOS 27 模拟器，未操作真机。
- captureViewport、replaceContents、reportScroll 共用第一条完整可见正文行几何，没有完整行时取相交行。顶边位于段间距及 ±1／小数物理像素、前补／裁剪的 10 组用例通过，实际保存原文位置保持 281728，不退到上一段。独立比较同一字符的片段顶边及真实字形基线，位移约 0.091–0.104pt，均小于 0.5pt。这是取行契约修正；原先 `ProjectionFinalNative.xcresult` 的一次重取锚点差异未证明为可见画面跳动，失败证据保留，未据此修改 Rust 边界。
- 分页恢复对照：已准备普通书 current 与 main(03dcdb7) 都直接恢复原文位置 888；旧合成夹具绕过原始 SHA 快开缓存，首次打开创建新 draft，current／main 均先显示封面。夹具改走真实准备后，current 长空白书能读到 181053 并重开恢复；main 同样夹具初始在 90000，三次翻页未推进。证据 `PagedResumeOrdinaryMain.xcresult`、`PagedPreparedSameDataMain.xcresult`、`ProjectionPreparedGesture.xcresult` 及对应日志。未发现一般的“已保存进度仍停封面”回归，未改变产品封面行为。
- Debug 模拟器 30 次样本：普通 156000 原文字节／61360 保留字节，frame 平均 2.635ms、投影 1.273ms；长空白 600020 原文字节／20 保留字节，frame 0.436ms、投影 0.006ms。frame 为整个 API 耗时，未单独测锁占用；不是 Release 或真机性能结论。开发缓存 schema 为 20，无旧格式迁移；原文、SHA 和阅读数据坐标不变。

### 选区范围与保留空白评审回归

新增唯一 `display_text_range`：按完整原文包络去除已确认的空白区段，保留段落分隔 LF。单屏、跨页、应用／原生拷贝、选中搜索与 AI excerpt 共用它，不取末页 substring、不拼接当前窗口。读取在后台执行，未确认尾部与 Ready 窗口一致暂不可取，显示输出上限 1MiB、省略空白不占额度；会话持有消费任务，替换或离开时取消，迟到结果不得发布。跨页并跨 1MiB 以上省略空白的结果与逐页显示文本拼接完全一致，单屏相同，离页取消断言通过。

`projectionAnchor` 允许是非空白段中的保留空格，Ready 表示投影位置已确认且可映射；`hasNonWhitespacePayload` 只描述载荷墨迹。定位／扩展只跳过已证实空白，以保留 source frontier 连续推进。`projection_end`、块、空白和 revision 原子发布；未确认尾部截出 Ready，反向仍可读取左侧确认数据。已删除非空白字符索引；schema 20 不兼容旧开发缓存。两倍预算以上段内空格／TAB／全角空格的精确锚点、双向推进、UTF-8 边界、暂停恢复前缀确认与 LF／EOF 区分通过 Rust 定向测试。

Rust core 27 项、reading_foundation 9 项通过、1 项既有性能样本忽略；Clippy `--all-targets -D warnings` 和格式检查通过：`build/ReaderBlankLines/review-accepted-{rust,clippy,format}.log`。最终 17 个空行／选区原生用例、12 个受影响 TextLayoutTests 与 App 跨页拷贝 UI 用例通过（`ReviewFinal2.xcresult`、`review-final-2-swift.log`）；包括两个以上窗口预算的段内空格精确开书恢复、滚动／分页实际到达后续“乙标记”并回到“甲标记”，不是只检查 Ready。最终异步消费任务版本的跨页拷贝／粘贴、单屏搜索和离页取消也通过（`ReviewConsumerFinal.xcresult` 对应成功用例），未把该包整体记为通过：附加离页测试的旧夹具从显示字节推原文位置报 InvalidRange，已改为分段映射取点、保留断言；3 个选区／搜索／离页用例在 `ReviewCancellationFinal.xcresult`、`review-cancellation-final.log` 全部通过。截图 `build/ReaderBlankLines/review-final-screens/`（含菜单、原生粘贴与四种段内空格到达画面）。直接从后台 UI Runner 读剪贴板触发系统粘贴权限框，该次停测不作通过证据；最终 UI 用例在月读内用原生粘贴验证，不改权限或产品代码。仅模拟器，无真机操作。


常用定位：[开书验收与正式交付](#开书云交接修复验收与正式交付2026-10-13)、[真实等待栈](#2026-10-13-真实开书等待定位与云交接修复)、[首页修复前基线](#首页启动稳定性基线2026-10-12修复前)、[AIStageOne 审计](#aistageone-历史断言审计2026-10-13)、[待完成的验证](#待完成的验证)。

## 开书第二轮：SHA 硬件后端与统计启动（2026-10-12，真机采集待完成）

基于第一轮 `556a5bb`，本轮未提交。sha2 0.11 使用默认运行时检测后端，digest 输出统一为64字符小写十六进制；原始输入、规范化正文和 CountingReader 仍使用原有字节输入，不改变 schema／身份／快开校验。升级前用0.10.9真实导入生成固定值（留在本机），新增空值、abc、55/56/63/64/65字节、多段分块、前导零、超过1MiB，以及UTF-8／BOM／GB18030／UTF-16LE和CRLF规范化比对。

正文监测在取得settings和lease后立即开始，统计启动任务按attempt受控；token在await前后校验，离页取消并stop，迟到任务不能启动timer或覆盖新clock。统计从实际启动后且正文可读时开始，不回填准备／等待时间；writer仍持有自己的lease，后台导入生命周期不变。预排版未实施。

- Nix Rust1.99.0，核心69项通过、1项既有性能测试忽略，Clippy `--all-targets -D warnings`通过；模拟器Rust target测试产物编译通过。证据 `build/ReaderOpenRound2/{rust-tests,clippy,rust-sim-test-build}.log`。
- SDK前移至`c82deb28c16799b10a19cf301ae6bbf76d1406b5`，仅新增Responses工具JSON排序的实现/合并；AI runtime42项加provider1项通过，初轮合计48项通过。新增/受影响统计7项最终通过，包括真实viewport下后台迟到启动不计时、恢复前台不回填、writer持有lease、取消/stop、旧attempt、监测不等待统计、settings失败和首次封面续读。证据 `swift-tests.log`、`statistics-background-tests.log`。
- Release模拟器诊断通过：串行/异步×两本×续读/首次各1次，共8次开书；无缓存合成长书导入1次等待完整完成。首次场景记录正式封面，不把停在封面的时间当正文时间。模拟器数据仅验证路径，不作真机p95结论。证据 `sim-benchmark.log`、`sim-events.jsonl`。
- 最终签名Release诊断包构建和严格签名校验通过，`device-final-build.log`。初次设备构建在补测试时使用旧模块失败，最终重建通过；失败不记为成功。用户确认手机插线解锁后开始XCTest，runner在建立IDE连接前peer refused／exit74，尚未产生第二轮有效样本；已立即通过Herdr告知cover-planner，等待连接处理或既有手动点按方案。`device-benchmark.log`不记为测试通过。
- 本轮单包0.11，包内交错统计串行／异步；跨轮比较只使用上一轮保存的`build/ReaderOpenLatency/device-events.jsonl`中both样本，注明不同时段/热状态/依赖版本变化，不称为四组严格交错。不清数据、不改写小说、不提交build/。功能与依赖锁文件的拆分参考保存在本机`build/ReaderOpenRound2/boundary/`。


## 开书唤醒与延迟准备页（2026-10-12，本机回归与真机续读对照）

已接入按阅读lease id的变更代次、单次恢复的多等待者和worker实例token事件；快开成功／完整导入完成／失败／暂停／实际恢复唤醒监测，首次可读前缀仍保留150ms兜底。OpeningRequest携带独立id与单调routeRequested，书架／搜索／最近／导入及详情直开入口统一传递；准备内容区300ms、操作反馈800ms，并受初次push完成约束。已有可读窗口不因后续失败／暂停退回准备页，正式封面保留。根部淡入已移除，只有确实得到可见display机会的准备扉页到内容使用局部200ms淡入；减弱动态效果直接替换。

- `build/ReaderOpenLatency/affected-tests.log`：最终非诊断构建11项定向测试全部通过，包括多等待者与取消／超时竞态、300/800ms边界、ready优先、出现完成幂等、旧attempt／后台过滤、开书取消与3项导入/文件恢复回归。
- Release模拟器`sim-fourway.log`：四组×两本合成样本×续读／首次阅读，共16次真实Button→LibraryModel.open→native push/返回的短回归通过。每条件只有1次，用于行为验证，不能作为p95性能结论；包含首个较慢样本。`sim-slow.log`：深浅色×0/100/250/299/301/500/799/801/1500ms gate，共18个场景通过；按实际就绪与push时刻判断显示档位，不把注入值当作总就绪时间。`gate-cancel.log`：3秒gate暂停、继续及未就绪立即返回用例通过，验证finished清理和展示取消路径。
- 录像`sim-replay.mov`、`sim-slow-replay.mov`，短片`fast-light.mp4`／`slow-light.mp4`／`slow-dark.mp4`及逐帧拼图留在同目录。浅色快开和慢开拼图已目视核对：内容区保持纸色并保留导航返回，快开没有准备扉页，慢开有标题和操作反馈后显示阅读内容。模拟器样本由私有隔离存储和合成文本驱动，不代表真机显示时间。
- 真机签名Release诊断构建通过，主App云权限保留；测试目标清空继承的主App entitlements，避免测试Runner误继承iCloud权限。前几次XCTest握手拒绝／exit74未产生有效样本，不能计为性能结果。用户确认启用UI自动化并重插USB后，`device-fourway-enabled-ui.log`已进入实际测试；小书为3715字节的自带故事，长书为约24MB的已下载样本（只读），快开缓存和用户存储／源偏好均隔离，四组同一优化Release诊断包交错切换。基线在同包中恢复8415d5f的固定轮询、立即准备页和根淡入行为，并保留相同埋点，不是另一份未经插桩的历史二进制。
- 用户要求使用手机后已停止采集，共130次有效续读，各条件16–17次；原定20次未完成，真机首次阅读未开始。Small baseline→both中位数150.920→123.015ms，Large349.482→214.501ms。Small both最大167.534ms较display-only124.259ms差，不宣称全面最优。各组中位数／p95／最大值及分段见`build/ReaderOpenLatency/results.md`、`device-events.summary.json`；nearest-rank p95在当前样本量等于最大值，保留全部样本。Large ready→canRead99.824→3.450ms，原始SHA75–77ms。worker与lease返回并行，分段不可简单相加。热缓存、隔离数据的自动点按不代表冷缓存／下载／全用户书架。回调为可见字形／透明度display机会，非光学测量；录像来自模拟器。真机首次阅读／正式封面未采样，模拟器首次阅读未强制showingCover=false。中断不记为整条XCTest通过，手机已交还用户。
- 关闭READER_OPEN_DIAGNOSTICS和AI_TESTING的签名Release构建通过，`production-build.log`为BUILD SUCCEEDED，codesign严格校验通过；包`build/ReaderOpenProduction/Build/Products/Release-iphoneos/Moonread.app`。尚未以该正式包宣告真机体验验收。未提交、未推送。


## 书架 SHA 方案开书测量（2026-10-12）

SHA 身份方案的前置真机测量已完成。Release 运行于 iPhone 13（iOS 27.0.1）；使用已下载的大型样本 A（约24MB）和 B（约16MB），只读源文件。这里保留匿名化的历史性能结果，不将当时的文件描述为原创测试夹具。测量缓存、用户存储与偏好隔离，测试会话禁用后台云书架更新。

两轮有效测试各对每本执行ABBA12次（现有快开A6次、额外完整原始SHA读取B6次），全部命中快开缓存并记录正文展示。最终轮次中位数：样本 A 的 A/B首屏340.562/318.051ms，完整读取+SHA17.917ms（15.577–22.936）；样本 B 的 A/B首屏329.869/319.916ms，SHA11.496ms（10.667–19.036）。首个有效轮次SHA中位数分别15.614/10.912ms，完整数据保留。文件大小比1.437，两轮SHA中位数比分别约1.431/1.559。B首屏较低不能解释为SHA加速：既有150ms状态轮询、视图过渡与调度影响计时；首屏为正文视图出现后的两个display-link回调埋点，不是光学测量。

最终轮次每本各3次哈希中取消均在hashEnd前退出，无缓存命中；取消请求到线程退出：大型样本 A中位数1.370ms、范围0.948–3.135；大型样本 B0.699ms、范围0.445–1.777。A在协调访问后取消仍完成缓存查找再退出，分别4.467ms（4.237–8.313）和3.101ms（2.814–4.956）。另保留首轮协调访问前取消数据。所有结果为已下载、预建快开缓存的重复读取，有热系统缓存局限，不代表冷读取、首次导入或下载成本，也不代表正式SHA索引实现验收。

详细数据、口径及无效轮次说明在`build/LibrarySHA/results.md`；有效原始记录为`run-isolated`、`run-cancel-active`的log/json/summary.json。`build-cancel-active.log`构建成功，`install-cancel-active.json`安装成功。临时三份源码已恢复，补丁仅在忽略目录`instrumentation-final.patch`；设备仍安装带启动参数测量入口的临时包。该阶段未提交或推送；用户随后已批准正式实施，结果见下方“书架文件定位与 SHA 关联”。


## AI 流式显示缓冲与平滑跟随（2026-10-12）

第一阶段已实现并完成本地回归；用户已在 iPhone 13 真机确认平滑显示手感可接受，并授权提交。显示缓冲仅管理当前活动文本块的展示前缀，权威内容、runtime 和存储不变。按字素／英文词边界推进，目标200ms、批次250ms追赶保护；工具、reasoning、确认、结束及离页时放完。历史和重新打开直接显示全部内容。CADisplayLink 仅在显示或滚动有积压时运行，不使整个 SwiftUI 会话每帧失效；AX label 来自已显示正文。

跟随使用连续临界阻尼（omega=32），小积压每帧≤1/3行高，大积压连续提速且每帧≤有效视口1/8；没有按内容类型分支、逐词淡入或容器高度动画。用户拖动立即停止跟随，非跟随继续按行锚定；输入区和排队胶囊 inset 同步调整并保留已有跟随积压。减弱动态效果直接显示并即时贴底。

### Release 回放与性能

`build/AIStreamSmoothing/approved-build.log` 的 Release 模拟器测试构建成功；使用 AI_TESTING 仅开放既有 fixture／runtime 测试钩子。8个场景覆盖深浅色、即时基线／平滑、普通正文／压力流。基线是同一 Release 二进制开启减弱动态效果后的即时显示路径，不是另一个历史构建。实际 UITableView／原生 Markdown 控制器回放合成数据，无真实服务请求，也不是手机对话端到端测试。

- 普通场景每100ms约12个汉字，偶尔短列表／行内代码。文字流阶段最大位移6.667pt／帧（行高约20.29pt）；完成时约60pt复制操作栏增高，按统一积压规则最大9pt／帧，约215–217ms收敛。
- 压力场景每100ms约20–80字，含换行、列表、代码块、表格及中途工具。最大49.333pt／帧，积压291pt；有效视口682pt，分别小于1/8视口85.25pt和半视口341pt。
- 全部平滑场景显示延迟≤277ms；已有可见文字行无反向移动。普通文字流上限、工具前放完、结束放完、上翻期间offset位移≤2pt断言均通过。逐帧数据同时记录每条渲染行的UTF16位置、窗口y及新末行位置；录像已抽帧核对文字持续存在、按段落向下生成，未见正文空白或新末行先在可读区域闪现再推走。
- 主线程运行时间（thread_info，相邻display-link采样间）>16ms：即时基线18帧、平滑2帧；各场景最大值分别为19.6–37.7ms与12.4–20.8ms。模拟器初筛改善，仍有超预算帧，不代替真机测量。
- 收敛边界如实保留：上一轮压力值350.026／350.092ms，按毫秒精度记为约350ms（`completion-frames.json`）；最终回放浅色350.068ms、深色360.531ms，后者在343.9ms仍余2.333pt，下一采样帧到达底部。三次代表实测350.1／350.1／360.5ms均保留。`approved-tests.log` 的2项测试中缓冲边界单测通过，回放测试仅此一处超过当时351ms断言；用户随后明确约350ms不是硬阈值，授权自动断言采用≤400ms容差，曲线保持不变。最终 `tolerance-tests.log` 的2项 Release 测试全部通过（TEST SUCCEEDED）；复测压力收敛350.090／350.012ms，显示延迟≤277ms、无反向，主线程>16ms基线19帧／平滑0帧。原始数据另存 `tolerance-frames.json`，不覆盖录屏那轮数据。

录屏：`build/AIStreamSmoothing/stream-smoothing.mp4`（正常速度，深浅色即时基线和平滑依次对照）；原始录屏 `approved-replay.mov`，数据 `approved-frames.json`、汇总 `approved-frames.summary.json`。只包含合成内容，均留在忽略的build目录。

### 回归与交付

`build/AIStreamSmoothing/regression.log` 的5项受影响回归全部通过（TEST SUCCEEDED）：展开标题逐帧位置、分页与inset锚点、Markdown缓存／AX文本、挂载转移所有权、搜索第59答。签名 Release 构建成功（`build/AIStreamSmoothing/device-final-build.log`，未带AI_TESTING），产物 `build/AIDevice/Build/Products/Release-iphoneos/Moonread.app`。`git diff --check`通过。用户随后在 iPhone 13 真机试用并确认第一阶段可接受；真机 VoiceOver 长回答朗读仍未验收。


## AI 过程条目展开（2026-10-12）

工具组和 reasoning 标题使用整行按钮，图标、标题和空白区域均可操作，辅助功能值为“已展开／已收起”。展开状态按分离的 group／reasoning ID 存在 AIConversation，进入行内容版本及高度缓存键，随会话释放、不持久化；cell 回收不重置。单个工具仍打开详情 sheet。

点击立即停止跟随，以被点标题所在行为锚点。已结束且没有摘要文本的 reasoning 显示“已思考”（英文 Thought），仅运行中的空 reasoning 显示“思考中”；保留状态行，不改变过程分组。

标题窗口坐标诊断确认旧实现存在 cell 顶边不动、内部标题移动2pt的情况；另捕获 UIHostingConfiguration 内容受到34pt底部 safe area影响，内部标题偏移17pt。因此 SwiftUI 行改用顶对齐、固定内容测量高度的 UIHostingController，显式清空 safeAreaRegions，统一标题内边距；原生 Markdown 行不变。该调整未接入 ListViewKit，也未将其他行改成原生 UIKit 内容。

高度在 performBatchUpdates 中更新，使用同一个 Core Animation 事务以0.25秒 easeInEaseOut 同步动画 cell／contentView 的位置和裁剪边界，展开内容从标题下方露出，chevron 旋转。动画中暂停锚点 settle，结束后记录高度缓存和实际锚点。减弱动态效果时无动画。不增加临时底部空白：收起若超过正常 offset 上限，只按不足量一次性 clamp，无动画、无回弹。

- 真实 hosting 行的控制器集成测试使用 CADisplayLink 记录标题在窗口中的 presentation 坐标，同时记录上方行和下方边界。覆盖普通／减弱动态效果 × 工具组／reasoning × 底部／上翻 × 展开／收起，共16场景、415个样本。无不足量时标题和上方行位移均0pt，满足≤0.5pt；普通动画边界有16–17个不同位置，逐帧没有反向移动。减弱动态效果只出现更新前后位置。底部收起工具组／reasoning 分别下移288／282pt，恰为不足量，只出现旧、新两个标题位置，无二次移动。证据：`build/AIExpansionAnimation/frames-final.json`、`frame-summary.json`。这是合成控制器测试，不是真机测量。
- UI 自动化点击图标、标题和空白区均可展开／收起，滚出再返回保留状态，两个 Markdown 正文块可见且 AX label 非空，单个工具详情正常；断言“已思考”存在、“思考中”不存在。展开后下一标题被输入框遮挡时，测试手动滚动露出再点击，符合不自动滚动的规则。
- 本轮6项不同的受影响测试通过：逐帧位置、Markdown缓存／AX、保留视图所有权、搜索第59答、展开交互、资料建议审阅。前4项在 `final-tests-2.log` 通过；该次展开UI因点击输入框下的标题失败，不能记为整轮成功。修正测试手势后，展开UI和资料审阅在 `interaction-final.log` 均通过（2项、0失败）；该次 xcodebuild 在用例完成后滞留归档，不把其退出状态记为成功。为最终视频重新执行展开UI，`video-test.log` 为 TEST EXECUTE SUCCEEDED。此前runtime定向验证见下节，本轮未重复无关测试。
- 模拟器交互录像 `build/AIExpansionAnimation/expand-collapse.mp4`、滚出再返回截图 `expanded-retained.png`；最终原始录像为 `interaction-fresh.mov`，已抽帧核对展开、收起及滚回后的正文；早先长录屏不作最终画面证据。逐帧指标保存在同目录。录屏使用合成内容。iOS 签名构建通过（`device-build.log`，BUILD SUCCEEDED），产物 `build/AIDevice/Build/Products/Debug-iphoneos/Moonread.app`。
- 本轮由设计师安装后，用户已在真机确认展开修复正常并授权提交。后续平滑显示作为独立阶段验证，结果见本页对应条目。

### 原生 Markdown 回收后空白（2026-10-12）

通过本地文件快照暂存本轮展开实现、恢复其修改前代码，保留上一轮等待行／摘要请求／系统指引／phase 实现及相同合成 fixture；在旧 DisclosureGroup 上操作箭头，再向前、向后各滑动5次。`build/AIMarkdownMount/baseline-returned.png` 复现“第14答”和“接着核对内容。”的空白，AX 查找均为 false（`baseline.log`）。旧版展开状态在回收后也会收起，因此截图中的展开状态与新版不同；正文空白在两版均出现，不是展开行版本变化导致的新回归。对照后完整恢复展开实现。

根因在 AINativeMarkdownCell 的挂载所有权：块视图按 ID 保留并转移至新 cell 后，旧 cell 的 markdown 引用仍指向它。旧 cell 后续 layout 会改写视图 frame，prepareForReuse 或挂载别块时会无条件 removeFromSuperview，从新 cell 移除视图；同实例 mount 的提前返回也不能修复丢失挂载。独立测量视图与高度缓存仍正常，因此出现保留高度的空白。确定性转移测试在修复前失败4个断言（`ownership-before.log`），包含尺寸被旧 cell 改写和视图被卸下。

修复仅收紧挂载关系：layout 和 unmount 只操作实际属于当前 contentView 的视图，mount 同时核对实例和实际父视图。解析缓存、nativeText 选择规则、行版本、行高策略不变；没有新增数据或兼容逻辑。

- 修复后同一 fixture 展开并滚出／返回，`build/AIMarkdownMount/fixed-returned.png` 已目视确认两处正文恢复，工具组与 reasoning 仍展开。UI 测试新增两处静态文本存在、label 非空、isHittable、frame 高度大于0的断言。
- `fixed-tests.log` 的5项受影响测试全部通过（TEST SUCCEEDED）：旧 cell 延迟布局／回收／挂载别块的所有权测试、缓存与AX文本、展开逐帧位置、展开及回收UI、搜索第59答。原有展开位置与正常底部 clamp 断言未放宽。仅复测本次受影响部分，不代表真机 VoiceOver 验收。
- 签名构建通过（`build/AIMarkdownMount/device-build.log`）；产物仍为 `build/AIDevice/Build/Products/Debug-iphoneos/Moonread.app`。`git diff --check` 通过，未提交、未推送、未安装或操作手机。临时对照源码与证据均在忽略的 build 目录，工作区已恢复全部上一轮功能并叠加此修复。

## AI 等待与中间说明（2026-10-12）

普通等待行仅显示 AIProcessLoading，保留“等待回复”的 accessibilityLabel；压缩时保留 archivebox、“整理上下文”及转圈。中间说明继续使用原有过程区与折叠规则，没有改变列表或滚动行为。

支持思考的 Responses 模型默认请求 `reasoningSummary: "auto"`，包括 Codex 登录和 API key：摘要属于协议／模型能力，不应按认证方式区分。应用模型能力同时传给 `forceReasoning`，避免 SDK 的模型名识别遗漏已支持的模型；非思考模型不请求摘要，不改变已选 reasoning effort。锁定 SDK 的 OpenAIResponsesModel 把选项编码到 `reasoning.summary`，将 summary SSE 增量转换为 reasoning 事件，沿现有 runtime parts 进入过程块。

英文系统指引要求在一组相关工具调用前用用户语言简短说明，简单单次查询或已解释步骤的延续可省略，不复述工具结果。Codex 的 instructions 替换默认提示词，测试直接核对其完整请求字段；API key 使用 system/developer 输入。

正常完成路径已由 SDK ToResponseMessages 将文本 providerMetadata 转为 providerOptions，runtime 原样持久化；OpenAIResponsesInput 从文本选项读回 itemId／phase。本次补齐中断路径：live／pending parts 保留并按供应商合并 start、delta、end 元数据，中断或重启恢复 assistant 文本／reasoning 时写回 providerOptions。跨模型／供应商仍按原规则剥离不透明选项；未新增旧格式兼容或迁移。

- 隔离模拟器44项定向测试通过（`build/AIProgress/tests.log`，TEST SUCCEEDED）：runtime41项、Markdown缓存／AX文本1项、等待行截图1项、搜索第59答1项。新增覆盖 Codex/API key 请求 summary=auto、非思考模型省略摘要、instructions 新指引、summary 增量进入 reasoning 块、commentary/final_answer 持久化后重开并进入真实 SDK 编码的历史 payload，以及中断／重启 pending parts 的 itemId／phase 保留。
- 合成截图8张在 `build/AIProgress/screens/`，深／浅色 × 标准／Accessibility XL × 等待／压缩均已目视核对。普通等待无省略号图标或可见文字；压缩状态图文保留。未使用私人对话或真实服务请求，截图不代表真机 VoiceOver 验收。
- iOS 签名构建通过（`build/AIProgress/device-build.log`），产物为 `build/AIDevice/Build/Products/Debug-iphoneos/Moonread.app`，交由设计师安装。本轮未安装或操作手机，未提交、未推送；`git diff --check` 通过。

## AI 流式输出与消息列表（2026-10-11）

数据设计见[流式稳定性](../ai/rendering.md#稳定身份与增量投影)，当前列表见[UIKit 设计](../ai/rendering.md)。runtime 保存有序 pendingParts 和 step，文本／思考块在 live、提交和分页重开间使用稳定 ID；历史投影缓存，完成时保持过程展开，重开后折叠。SwiftUI ScrollView 的滚动补丁已由 UITableView 替换。

手机已安装的 UITableView 基线按块使用 diffable data source、UIHostingConfiguration 横向边距和版本化行高缓存。Markdown 解析文档按块缓存在会话模型，cell 回收或 reconfigure 后同步使用已有文档，新解析完成前保留旧内容。首轮回放曾发现 controller 重建导致正文空白；缓存修正后的同快照回放已恢复正文。流式中不显示本轮复制操作栏。排队气泡复用正式组件和输入 ID，保持 0.6 不透明度；胶囊浮在输入框上方，以实测高度加间距计入 table 底部 inset，跟随时无动画贴底，非跟随时保持可见行锚点。

### 本地回放与性能边界

在隔离环境回放会话快照验证列表行为；没有调用真实模型服务。快照、截图和录屏只保存在忽略的 `build/`，不随源码分发，报告不引用对话正文或私人使用数量。

- UIKit Release 回放覆盖发送、reasoning／工具／文字增量、排队、快慢上翻、加载较早和回到底部，4815帧，跟随最大 gap 0.000003pt、最终 gap=0；无整页空白、活动 turn 的复制操作栏采样为0。胶囊 H=52pt，跟随显隐扣除同帧内容增长后的 offset 误差<0.00001pt；非跟随消失时可见行位移=0，视口不变。非手势且视口不变的相邻帧共同可见行位移为0。一次 drag_end 内部布局曾记录3pt误差并在同帧归零，未出现在相邻显示帧；不把内部日志最大值与实际显示帧混为一谈。录像及发送逐帧图已检查，没有先跳再回。证据为 `build/AIUIKit/replay/` 的 metrics、inset-transitions、send.mov 与 send-inset-frames；搜索定位录屏在 screens/search.mov。滚动期间主线程 CPU 超过16ms共8个采样，最大60.5ms，明细见 scroll-main-cpu-over-16ms.csv；这仍是性能限制。
- 受影响原生40项通过（runtime39项＋Markdown缓存1项），包含稳定块身份、队列转正式消息、前插分页锚点以及底部 inset ±52pt 的跟随／非跟随断言；业务UI4项通过（搜索历史定位与回到底部、点击／拖动收键盘保留草稿、资料审阅应用、封面候选来源应用），见 `build/AIUIKit/final-tests.log`。这次命令在全部用例结束后滞留归档，已终止，不标记其退出状态成功。临时选字测试首轮把系统菜单项当按钮查找而失败；截图已有选区和拷贝菜单，修正查询后的单项复测通过且命令正常成功，见 selection-test.log。诊断代码已移除，复现补丁仅存 build/AIUIKit/instrumentation.patch。
- 浅色／深色和 Accessibility XL 截图见 `build/AIUIKit/screens/`。正文横向边距恢复；排队气泡在胶囊上方完整可见。CommonMark 对紧邻中文引号的强调分隔符可能显示字面 `**`，为原有解析行为，本轮不修改。
- Release 初筛为模拟器合成数据：每条780字，50→100→150，随后在同进程 showMessage100；每阶段5秒、两次完整运行。指标是 MainActor 排队探针最大延迟和进程 RSS，不能当作精确函数耗时或真机结果。证据为 `build/AIUIKit/bench-lazy-*.log`、`bench-inset-*.log`。

| 阶段 | 原 Lazy 最大延迟 | UIKit 最大延迟 | 原 Lazy RSS | UIKit RSS |
| --- | --- | --- | --- | --- |
| 首屏50 | 256–700ms | 192–499ms | 353MiB | 348–351MiB |
| 追加至100 | 7–26ms | 93–99ms | 351MiB | 357–359MiB |
| 追加至150 | 1.5–1.9ms | 115–135ms | 348MiB | 371–373MiB |
| showMessage100 | 61–88ms | 65–123ms | 354MiB | 364–365MiB |

showMessage100 发生在150条之后，含前阶段分配留存，不是独立冷启动100。另一次早期 UIKit 冷启动未完成整轮采集，曾观察首屏约800ms，说明启动波动；不能据两次完整运行断言首屏稳定优于旧实现。追加存在明确回归，未满足原“不劣于 Lazy”的严格指标。设计师确认作为试用限制，不阻止安装；试用后单独用 Time Profiler 主线程栈定位分页追加成本，不把功能通过解释成性能通过。一次性 VStack 曾测得1.29–1.59s调度延迟、647–879MiB RSS，已否决。


### 分页追加 CPU 栈定位

覆盖安装后，在隔离模拟器对优化的本地合成驱动附加 Time Profiler。有效证据是 `build/AIUIKit/pagination-attach.trace`，阶段时间在 pagination-bench.log，完整窗口主线程栈在 append-main-stacks.json。首次直接 launch 采样没有产生 BENCH 标记，排除，不用于结论。

附加开始晚于追加至100，捕获追加至150：该阶段开始后500ms内共184个主线程采样（1ms采样周期）。其中141个栈包含 AttributeGraph 更新，124个包含 PlatformViewChild.updateValue，69个包含 UITableView 可见 cell 更新，67个包含 prepared cell 创建；recordVisibleHeights/cellForRow 查询链21个。各项是包含式栈计数，存在重叠，不能相加。mergeEntries、messageRows 和 diff 计算各仅1个采样。

这次采样支持主要成本在 UIKit/SwiftUI cell 创建、自适应布局和可见高度读取链，未支持“全量投影或 diff 算法为主因”。栈不能证明新页50行全部被测量，仍需独立布局计数或针对性消融确认；不据此声称已找到或修复全部性能问题。本轮未再修改已交付手机版本，定位结果已交给设计师。

### 原生 Markdown 第一步验证（2026-10-11）

按[原生化方案](../ai/rendering.md)仅替换文本块：MarkdownView 4.8.3（MIT），保留 UITableView、块 ID、跟随与锚点逻辑，其他行仍用 UIHostingConfiguration。缓存归会话所有，按块保存最新解析内容及显示视图；测量用独立的 24 项 LRU sizing view 池，按版本、宽度、字号缓存高度。流式结束重新完整解析。当前内容构建同步发生在主线程，不宣称后台解析；显示视图池尚无容量上限，分页累计仍是限制。没有接入 ListViewKit，没有复制 FlowDown 的 AGPL 源码。

同一模拟器、同一 780 字合成数据、相同 Release 优化及临时诊断驱动，每阶段5秒，两次完整运行。下表为 MainActor 探针最大调度延迟范围（ms），不是函数精确耗时，也不等同实际丢帧数。showMessage100 在150条阶段后同进程执行，不能当独立冷启动。下表是补齐 AX label 和旧版本高度缓存清理后的最终两轮数据。

| 阶段 | 旧 Lazy | UITableView + SwiftUI 正文 | UITableView + 原生正文 | 原生 RSS（MiB） |
| --- | ---: | ---: | ---: | ---: |
| 首屏50 | 256–700 | 192–499 | 243–722 | 328–343 |
| 追加至100 | 7–26 | 93–99 | 43–120 | 334–344 |
| 追加至150 | 1.5–1.9 | 115–135 | 26–32 | 328–342 |
| showMessage100 | 61–88 | 65–123 | 102–111 | 320–329 |

对应旧 UITableView RSS 分别为348–351、357–359、371–373、364–365MiB。150条追加有明确改善；100条追加波动覆盖旧基线，不能称为稳定改善，仍未达到旧 Lazy。首屏方差大，showMessage100 未证明改善。最终两轮 RSS 较低，但之前未加 AX 的原型初筛曾达到349–377MiB，不能以少量进程 RSS 样本认定缓存内存问题已解决。没有受控消融证明波动由 AX 引起。最终原始数据为 `build/AINative/bench-native-ax-{0,1}.log`、performance.json，初筛保存在 bench-native-{0,1}.log；旧基线在 `build/AIUIKit/bench-inset-*`、bench-lazy-*。

补齐 AX 后同一私有快照 Release 回放4969个显示帧，发送、流式、排队、上翻、分页和回底均有正文。静止且视口不变时共同可见行相邻帧位移0，跟随最大 gap<0.000001pt，最终 gap=0；活动 turn 复制栏采样0，发送后整页空白采样0。滚动区间主线程 CPU>16ms 由旧版8个采样变为2个，但最大60.5→97.5ms，最坏长帧回退；未加 AX 的初筛为1个／22.4ms，不能只报初筛较好值，也没有消融证据归因于 AX。最终长帧在最后一次拖动结束前，显示帧间隔104.8ms。拖动结束边界内部锚点误差25.67pt同帧归零，跨该边界 offset 16.67→-16pt、共同可见行移动32.67pt；随后静止位移0。这一边界混有手势尾部和顶部回弹，不能把静止统计外推为“全程位移≤2pt”或完整跳动验收通过。发送过渡30fps连续抽帧和发送／上翻4fps概览已查看，未见整页闪空或静止时先跳再回，完整录屏保留。证据：`build/AINative/replay/` 的 lifecycle.log、metrics.json、send.mov、send-frames.png、scroll-frames.png、send-transition.png、drag-end-transition.png；初筛回放保存在 replay-initial/。

渲染调整通过 MarkdownView/Litext 公开的文档处理、附件与绘制接口实现，没有依赖补丁、fork 或私有类型访问。代码和表格采用新库样式，段落间距保持新库默认。具体差异：

- 一级／二级／三级标题恢复为 28／24／20pt（正文17pt时），随字号比例缩放；保留标题内行内代码字体。
- 有序列表恢复普通数字加句点，支持两位数字与嵌套；无序圆点、任务复选框、缩进仍采用新库样式。
- 强调移除新库的彩色下划线，中文不加装饰；粗体正常。紧邻中文引号的句内 `**` 两版仍可能显示字面字符，本轮不修。行内代码仍使用圆角底色。
- 代码采用新库浅深主题、复制／展开按钮。**行号是已接受的已知差异**：当前公开 API 无关闭配置，不为此修改依赖；以后上游提供配置时再评估。
- 表格采用新库标题栏、复制／展开入口和列对齐。Accessibility XL 下仍需横向查看；截图不代表 VoiceOver 表格导航验收。
- 链接使用主题强调色；辅助功能继续来自同一解析结果。

辅助功能首次回归暴露新库正文缺少 AX label，导致搜索测试末页正文断言失败。已在 MarkdownTextView 容器补 `.staticText` 和解析节点生成的纯文本 label，随内容更新；链接提供 custom actions，单测校验朗读文本顺序、去除强调标记及链接动作名称。搜索第59答断言恢复通过，实际截图可见末页正文（search-conversation-latest.png）。当前以整块朗读，未实现逐段 AX 元素；长回答的朗读顺序、焦点与自动滚动仍须实际 VoiceOver 验证。[Apple 官方说明](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app)指出 VoiceOver 不支持 Simulator，需真机。原型已安装真机试用，VoiceOver 反馈待用户提供，**不能作为已验收的可交付结论**。

受影响回归：原生 runtime39项及缓存1项通过（tests.log）；键盘点击／拖动收起保留草稿通过（affected-tests.log），该批因测试进程读剪贴板触发授权而终止，不能算整批成功。去掉内容读取，仅验证剪贴板版本变化后的链接／选字／复制及缓存复测通过（gesture-final.log）。AX 补丁后缓存/同源文本/链接动作单测和原会话搜索 UI 测试均通过，命令 TEST SUCCEEDED（ax-final.log）。以上为模拟器证据，未做真实账号请求或真机 VoiceOver 体验验收。

临时驱动、计数和录屏入口已从源码移除，复现补丁仅在 `build/AINative/instrumentation.patch`；本轮开始前的未提交 UITableView 基线保存在 build/AINative/baseline/。最终无诊断代码的模拟器构建成功并启动书架（formal-build.log、formal-launch.log、screens/formal-launch.png），git diff --check 通过。原型及基线均未提交、未推送。第一步结果已交设计师；最坏长帧、缓存容量和实际 VoiceOver 仍是限制。用户选择先真机试用，暂不进入第二步。

渲染调整的最终对照图在 `build/AINativeFollowUp/screens/`：10组 `*-compare.png` 均为左旧右新，覆盖标题、列表、强调、代码、表格、链接及深色／Accessibility XL。已目视核对标题层级、普通数字编号、无强调下划线及保留行号。定向测试中，搜索第59答、链接／选字／复制、缓存与同源 AX 文本均通过（style-tests.log）；新样式单测的字号与编号断言通过，初次宽度断言因合成段落太短而失败，加长段落后重跑通过（style-unit.log，TEST SUCCEEDED）。这次没有改变滚动算法。临时诊断入口已再次移除，仅保留 `build/AINativeFollowUp/instrumentation.patch`；干净源码构建通过并正常启动书架（formal-build.log、formal-launch.log、screens/formal-launch.png），git diff --check 通过，未提交。真机 VoiceOver 门槛仍未完成。

### 原生 Markdown 真机试用安装（2026-10-12）

用户选择先在真机试用，暂不进入第二步。cover-planner 已用当前工作区的 MarkdownView 原型及渲染调整签名构建，覆盖安装至 iPhone 13。已核对 `build/native-md-device-build.log` 的 BUILD SUCCEEDED 和 `build/native-md-device-install.log` 的安装成功结果（bundle ID：`dev.moonread.Moonread`）；按执行者报告，本次未清理数据。上述日志不包含启动或产品验收证据。

用户已在 iPhone 13 上试用，认可滚动和流式输出手感，并授权收尾提交。真机 VoiceOver 长回答朗读、焦点顺序及自动滚动仍待验收，不记录为已通过。第二步暂缓。

收尾已确认所有 Swift 源码无 SwiftStreamingMarkdown 引用，删除 project.pbxproj 中的 package／产品／链接项及 Package.resolved 条目；Xcode 重新解析时一并移除其独有的传递依赖。隔离模拟器 `clean build` 通过；AI 定向回归42项通过：runtime39项、原生 Markdown 缓存与 AX 同源文本1项、渲染样式1项、会话搜索第59答1项。证据：`build/NativeMarkdownFinal/clean-build.log`、`ai-tests.log`。源码和工程／锁文件无旧依赖残留，`git diff --check` 通过。此次仅更新源码与文档并提交，不推送、不操作手机，build/ 私有快照与诊断补丁不纳入提交。

### 原生 Markdown 长帧追加定位（2026-10-11）

保持原型渲染与滚动逻辑不变，用同一私有快照和同一 XCTest 手势序列做两轮 Release 回放，Time Profiler 只附加模拟器 App。第二轮补充解析／安装／测量计时及 MOVE、willEndDragging、didEndDragging 日志。样式调整在采样后启用，不混入原长帧定位。

- 原97.466ms CPU帧（帧间隔104.75ms）没有在两轮中复现；两轮滚动区间最大分别24.190ms和14.084ms，CPU>16ms分别2帧和0帧。不能用新帧替代原帧或宣告最坏长帧已解决。
- 第一轮24.190ms所在51.127ms窗口有23个主线程采样：5个含 UITableView prepared-cell／height 链，4个含 UIHostingContentView.systemLayoutSizeFitting，7个含 _UIHostingView.layoutSubviews，4个含 settle。以上是包含式计数、互相重叠，不能相加。窗口未采到 native Markdown 解析、CoreText framesetter 或 AX 文本提取链，支持该帧归为 **a 类：剩余 SwiftUI cell／表格自适应布局**。当时正在上翻，历史行进入／重排与流式更新同时发生，宽度、字号未变，尚未提交；不能再细分为单一触发原因。
- 第二轮另见冷启动的原生内容安装43.72ms、测量26.75ms（墙钟时间，分别13和8个主线程样本）；栈含字体首次加载／字体回退及 CoreText typesetter，属于独立的 b 类冷路径证据，发生在首次发送之前，不能用来解释滚动中的原97.5ms。解析计时最大2.11ms。原始对齐结果见 native-duration-maxima.json。
- 原长帧时机：结束前约150ms内发生首轮回答提交、队列转新 turn、胶囊消失及列表更新，随后到达末次顶部拖动结束。两轮采样的末次拖动均早于这次提交（约3秒、6秒），没有重现该时序重叠。Profiler／自动化会改变时序；提交附近还可见 XCTest AX 查询栈，不把自动化成本直接当作日常触屏成本。
- 原32.67pt位移：contentSize不变，offset由16.67到-16（顶部边界），共同可见行相应移动；内部锚点误差25.67pt紧接归零。它发生于drag_end和布局恢复边界，原日志没有 MOVE／手势目标，**尚不能确认是纯顶部回弹或手势尾部，也不能排除应用锚点恢复**。第二轮新增日志未再发生该边界，末次减速落点约7pt，没有到达-16顶部。滚动代码本轮未修。
- 第二轮4693帧：静止共同可见行最大位移0.124pt、最终gap=0。回底过程中有1个CAD采样返回空可见行数组，下一帧恢复；该时段录屏抽帧检查未见整页闪空，不能把日志计数写成零，也不能凭录屏排除短于采样间隔的瞬态。

证据仅保存在忽略的本机目录 `build/AINativeFollowUp/profile{,2}/`：replay.trace、lifecycle.log、main-stacks.json、metrics.json、send.mov；第二轮空行采样附近抽帧为 empty-sample-contact.png。报告不包含私人对话正文。上述为诊断结论，不是性能修复或第二步实施许可。

### 数据清理边界与真机状态

以下是有序 pendingParts/step 存储调整时已经执行的一次性清理记录；UITableView 重构不改变存储格式，不重复清理。

- 用户已授权一次性清理 iPhone 13 的 AI 会话数据。真机核实路径为 `Library/Application Support/Moonread/ai-conversations.store`、同名 `-wal`/`-shm` 及 `.ai-conversations_SUPPORT/_EXTERNAL_DATA` 图片目录。AI schema 仅含会话、head、entry、asset，关闭 CloudKit。阅读数据使用独立的 `reader.sqlite3`、`user-data.store`、`pending-users.store`；连接配置在 `Library/Preferences/dev.moonread.Moonread.plist`，凭据在 Keychain。以上阅读库、配置、Assets、小说和 iCloud 均不清理。清理前目录元数据见 `build/AIStreamDiagAfter/device-*-before.json`，未读取配置或凭据内容。
- iPhone 13 已完成一次性定点清理与覆盖安装，并成功启动。App 关闭后通过 House Arrest/AFC 仅删除上述三个 AI 数据库文件与 `.ai-conversations_SUPPORT` 整个专属目录，逐项确认不存在；清理前后其余同级文件、阅读库、Preferences 和 Documents 的大小、类型、修改时间一致。未卸载 App，未操作 Keychain、小说原件或 iCloud，也未在源码加入清理或兼容逻辑。日志为 `device-cleanup.log`、`device-install.log`、`device-launch.log`（均在 `build/AIStreamDiagAfter/`）。用户后续反馈发送与手动滚动仍有跳动，当前修复尚未通过体验验收。

正式 UIKit 版本签名构建成功，已用 devicectl 覆盖安装 iPhone 13 并成功启动；没有卸载或清理数据，保留现有会话、阅读数据、连接配置和凭据。证据为 `build/AIUIKit/device-build.log`、device-install.json、device-launch.json。真实账号及手机手感待用户验收，安装／启动成功不代表体验已通过。

## AI 结果卡片与资料审阅（2026-10-11）

实现范围见 [设计](../design/ai.md#结果卡片与资料复核)：任务头进入消息滚动区域，回到底部使用浮层、应用操作有独立底栏；资料与封面结果整卡可点；资料预览使用 chip、文本切换与编辑；文件重命名经快照校验和 `renameLibraryItem(replace:false)` 执行，与 metadata 分别报告。

- 使用隔离的 DEBUG UI fixture，书名为“星灯渡口_林澄”，作者与标签为固定 fixture 值，简介和封面图片为合成测试数据；未复制小说正文，未调用真实模型服务。改前四页截图在 `build/AIReviewEvidence/ai-review-before-*.png`。
- `AIFollowUpTests` 34 项：33 项通过，1 项真实网页回放按默认配置跳过；包括新 rename 嵌套 schema、非法名称／跨书来源拒绝、真实重命名与阅读进度保留、同名冲突不覆盖、生成后外部改名拒绝、资料保存成功而重命名失败时分别反馈、replace 默认保留移除标签、编辑稿切换、去空白／重复标签与实际计数。日志 `build/AIReviewEvidence/tests.log`。
- UI 4 项通过：完整审阅交互、资料应用、封面来源／候选选择／设为封面，以及浅色／深色 × 默认／Accessibility XL 的四页面截图。完整交互覆盖新增 chip 取消恢复、移除 chip 默认保留再选择、编辑后切回原内容和建议、全部取消后 0 项禁用、只确认重命名后实际保存。
- 详情 AI 入口在标准字号并排、辅助功能字号纵向各占一行，避免逐字断行；原浅／深色 Accessibility XL 验证后，按设计反馈补跑深色详情页定向 UI 测试并通过。最终截图 `ai-review-after-dark-ax-detail.png`，日志 `stacked-layout.log`。目视确认两个入口完整、chip 换行、应用栏不压正文、封面完整 fit 且说明对齐。截图在 `build/AIReviewEvidence/ai-review-after-*.png`，改前／改后对照为 `before-after.png`，大字号概览为 `dark-ax-overview.png`；追加日志 `accessibility.log`。
- Xcode 27 在用例结束后出现结果包归档滞留；上述通过数来自 XCTest 直接输出，截图由测试直接写出。已停止完成测试后滞留的进程，不把不完整的 xcresult 作为证据。
- Xcode 模拟器与 iPhone 签名构建通过；已用 `devicectl device install app` 覆盖安装到配对 iPhone 13，未卸载或重置 App 数据。日志 `device-build.log`、`install.log`、`launch.log`；`devicectl device process launch` 成功。
- 真机产品验收：用户已在 iPhone 13 上试用，报告没有问题。本次不沿用上一轮查找封面的验收结论。

## 查找封面页面图片（2026-10-11）

已接入 Rust `cover_page` 提取器（`scraper 0.27.0`、`url 2.5.8`）与 Swift 串行获取流程。只解析搜索来源页面声明的一层图片，完整规则见[工具契约](../ai/tools.md)。保留2 MiB解析输入、每页4个地址、每次8个候选和短边100px／宽高比1.2限制，未为真实站点放宽规则或设置伪装 User-Agent。图片、网页正文和凭据不提交仓库。

### 第一层：fixture、构建与集成

- Nix Rust 定向测试：`cargo test --target-dir build/cargo --locked -p moonread-core cover_page`，5项通过。覆盖优先级、HTML实体与签名查询、最终响应地址与多个 base、JSON-LD数组／ImageObject／深度保护、GB18030、相对 lazy、空白书名、兜底数量和2 MiB截断。日志 `build/CoverEvidence/rust.log`。
- `cargo clippy --target-dir build/cargo --locked -p moonread-core --all-targets -- -D warnings` 通过；iPhone `aarch64-apple-ios` 核心 `cargo check` 通过，见 `clippy-final.log`、`device-core.log`。Xcode 模拟器构建同时编译 arm64 与 x86_64 Rust slice，并生成 UniFFI 绑定。
- iPhone 18 Pro / iOS 27 模拟器，`AIFollowUpTests` 首轮30项，29项通过、1项网络回放按默认配置跳过，见 `tests.log`。后续最终6项封面定向测试全部通过，见 `final-tests.log`：页面提取／最终响应 URL／不递归、尺寸99/100及1.2边界、去重与8候选停止、保存失败、save后连接取消、已有候选后Task取消、保留其他调用与已提交资产、Referer初始及重定向处理。
- 重定向规则测试直接调用实际 `willPerformHTTPRedirection` delegate，页面最终URL使用 `CoverFetchURLProtocol` 响应 fixture；没有把这些fixture描述为真实服务器重定向验收。
- 旧的独立直链下载入口已删除，无后缀／通用MIME测试改走实际候选流程，定向复测见 `direct-final.log`。

### 第二层：来源回放

早期曾用公开网页回放确认页面图片提取可行；这不等于 App 内托管搜索验收。公开回归现改为离线原创 HTML 与程序绘制的封面，不再请求第三方书站或保存其封面。历史本机图片、私人快照与原始证据不随源码分发。

当前复测入口是 `AIFollowUpTests.testOfflineOriginalCoverReplay`，经 `CoverFetchURLProtocol` 调用生产获取流程，校验页面声明提取、候选数量、来源和保存字节；不需要账户或网络。

### 第三层：用户真机验收

真机签名构建成功，并已覆盖安装到 iPhone 13；没有卸载或清空数据（`build/cover-device-build.log`、`build/cover-device-install.json`）。2026-10-11，用户用自己的搜索账号在 App 内实测，报告“查找封面”实际可用。逐本书的来源、候选数及应用结果没有另行记录。最低系统版本的验收没有进行。

## 目录混排与一级布局菜单（2026-10-10）

目录菜单顺序为操作、布局、导航；目录与全部小说均使用 inline Picker，列表/网格在第一层显示原生勾选。目录移除文件夹/书籍分区，保留根目录总览；集合视图按核心返回顺序展示。最近阅读跨文件夹与小说混排，未读按修改时间，空文件夹保留在最后。首页入口和搜索分组不变。

- 核心：`build/library-mixed-core-final.log`，61 项通过、1 项既有测试忽略。新增覆盖跨类型阅读顺序、后代阅读时间、已读同时间自然名称、未读修改时间及嵌套空目录保留。
- 模拟器：iPhone 18 Pro / iOS 27，`build/library-mixed-ui-final.log` 为 `TEST SUCCEEDED`，3/3 通过：混排列表/网格及根目录/子目录/全部小说一级菜单、布局切换与重启保留、跨书籍和文件夹的连续多选/取消。第一轮混排断言发现集合视图仍按类型分区；删除这层分区后以上最终回归通过。
- 目视检查：`build/LibraryMixed-Shots/` 的 list、grid、menu、subfolder-menu、all-books-menu 五张图确认原生勾选、操作/布局/导航顺序，以及空目录最后且仍可见。证据为默认字号深色模拟器，未验证 iOS 18、辅助字号和真机。
- 审阅修正：集合列表显式对齐文字列分隔线，子目录“全部小说”使用 `books.vertical` 图标；`LibrarySort::Name` 保留原有文件夹优先，仅阅读排序混排。`build/library-review-core.log` 书架测试 12/12 通过，`build/library-review-ui.log` 混排与菜单测试通过且 `TEST SUCCEEDED`；目视检查 `build/LibraryReview-Shots/` 两张新图，确认书籍/文件夹分隔线统一及菜单图标。
- 真机：检查原数据库为 schema 15 后先停止覆盖安装；用户随后授权清除阅读数据并重装。卸载前只读递归检查本地内置书架 `Documents` 为 0 个文件（`build/phone-reset-documents.json`），未操作 iCloud 或外部小说原件。当前 schema 16 真机签名构建通过，iPhone 13 卸载、安装和启动成功（`build/library-device-build.log`、`library-device-uninstall.json`、`library-device-install.json`、`library-device-launch.json`）；界面效果待用户试用。未提交或推送，不操作 stash，暂存区保持原状态。

## 本地化资源与导入错误（2026-10-10）

继续使用简中文案 key。18 条英文数量资源加入 `one/other`（多数量句子分别替换）；补充 17 条翻译上下文。修复“后续准备中”、恢复导入失败及封面/标签无障碍标签的动态文案。导入任务保存 `ReaderError` 的类型和诊断参数，读取时用当前 App 语言呈现；核心开发格式提升为 schema 16，无旧格式迁移。

- Rust：`build/i18n-core.log`，60 项通过、1 项既有测试忽略；新增失败落盘/重新打开/重试清除/暂停无错误的验证。
- 首轮编译资源测试：`build/i18n-native.log` 通过，直接读取英文语言包，验证 0/1/2、两个独立数量及非首位数量参数。
- 最终资源与重启错误测试：`build/i18n-resource-final.log`，`testEnglishLocalizationCountsAndImportMessages` 通过且 `TEST SUCCEEDED`；覆盖编译资源单复数、文本/数量混合参数、封面与标签无障碍文案、UniFFI 传递与核心重启后的错误类型及英文显示。简中使用开发语言 key 回退，未假定存在独立 `zh-Hans.lproj`。
- 暂停恢复和英文 UI：`build/i18n-final.log` 中 `testPausedImportHandoffResumesAndPromotesPendingReadingData`、`testBookshelfEnglishSearchAndDarkAppearance` 分别通过。该轮新增测试错误假定简中有独立资源目录而失败，修正后按上一条单独复测通过；旧 xcodebuild 在已输出测试完成结果后卡住收尾，仅终止该进程。
- 目视检查英文深色搜索截图 `build/I18n-Shots/search-english.png`：My Library/Unread 为英文，样例书名与目录名保留原文；未据此宣称全部页面或字号均已验收。

范围：不代表全应用语言或大字号验收；未安装手机、未重置手机数据。新的核心开发格式不能直接打开 schema 15 数据，后续试用需按开发格式规则处理。

## 书架首页：继续阅读优先（2026-10-08）

`LibraryView` 首页把最近一次正式阅读的书单独作为“继续阅读”行（60×84 封面、书名、当前章节、按当前阅读位置计算的进度条与百分比，点按沿用 `model.open` 续读），其后“最近阅读”只列接下来的两本，不重复第一本；“查看全部”进入原有完整最近阅读页。只有一本时不显示“最近阅读”分区，“查看全部”移到“继续阅读”标题右侧；没有阅读记录时只显示书架根入口，不显示任何分区标题。书架分区标题改为“书架与文件夹”，三处标题同一样式，行间不加分隔线。设置、添加、独立搜索、Tab、目录树、长按小说详情与从最近移除、加载状态和查询均未改变。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 构建 | 模拟器 build-for-testing 通过 | `build/home-build.log` |
| 定向 UI（隔离书架样例 `--ui-test-bookshelf`） | `testHomeResumesFirstAndKeepsRecentsAndShelves` 通过：继续阅读、最近阅读、书架与文件夹依次出现，三本书分为一行加两行且继续阅读行更高；“查看全部”唯一，完整页仍含三本；从继续阅读续读后返回首页，同一本仍在首位、位置不变（1pt 内）；长按移除两本后“最近阅读”消失、“查看全部”仍在；再移除最后一本后继续阅读与书架分区标题都消失；书架可进入并返回，首页下拉刷新后仍显示书架。`testHomeResumeFirstAccessibilityType` 通过：辅助功能大字号下同样三段且继续阅读行更高 | `build/home-ui-1.log` |
| 画面 | 三本、一本、无记录、完整最近阅读页与大字号首页 | `build/Home-Shots/` |

未解决的验证限制：`testWelcomeHomeUsesSingleAddMenuAndOrdinaryBook` 在从书架打开欢迎短篇后等待滚动正文 `scrollText` 失败（与此前记录的“示例以分页打开”同类，发生在首页断言之前，未归因到本次改动，未修改阅读内部）；其首页断言已改为“继续阅读”但本轮未执行到。样例中三本书的最近阅读顺序在不同运行间不同，首位书不固定。未运行深色、iPhone 13 尺寸的 UI 自动化或全量测试。设备构建与签名检查通过，已覆盖安装到 iPhone 13 并启动，随后核对进程仍在运行；未卸载或清空数据，CloudDocuments／CloudKit 权限保留（`build/home-device-build.log`、`build/home-device-install.json`、`build/home-device-launch.json`）。真机首页体验待用户确认。

## 选字菜单：阅读操作、学习与共享的平铺分组合并（2026-10-08）

用户在展开的选字菜单列表中看到前五组、最后一组（跨页选取、设为章节）完全不可见。经批准只做最小的不折叠调整：`ReadingView.selectionMenu` 把相邻的批注组与工具组合为一个无标题 `.displayInline` 分组，动作顺序、数量与出现条件不变，常用组与原生查询、其他系统建议分组的结构和顺序不变；没有子菜单、标题、提示或按选区长度的判断。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 结构 | `testSelectionMenuUsesAnyOverlapAndPreservesTheSelectedTextRange` 通过：常用组动作不变；原生 lookup 分组为同一对象；根菜单为常用组、lookup、一个无标题内联组，后者依次为（写批注／批注到这里）、批注整段、从这里跨页选取，可整理目录时再加设为章节 | `build/selection-candidate.log` |
| 改动前后画面（同一隔离测试样例、同一启动参数与阅读排版；只截图，不执行菜单动作） | 默认动态字体：改动前依次可见“标注 拷贝 全文搜索｜查询 翻译 搜索网页｜学习…｜共享…｜写批注 批注整段”，面板在批注整段后干净结束；改动后画面相同，面板底部位置相同，没有露出“从这里跨页选取”的任何部分。辅助功能字号：前后均只可见到搜索网页，其后不可见。XCUI 在改动后把“从这里跨页选取”报告为可点（818–860），但截图中未绘制 | `build/SelectionMenu-Shots/baseline/`、`candidate/`、`bottom-compare-default.png`；`build/selection-baseline.log`、`build/selection-candidate.log` |

只合并批注与高级操作的对照结果：实现符合批准的结构，但未达到显示继续提示的产品目标。在这两种设置下，去掉一条分隔线没有带来可见的继续提示，最后的动作仍未露出；是否保留此合并或改用其他方案（如此前讨论的具名子菜单）留待用户决定。UIKit 不公开该列表的高度、裁切或滚动指示的控制方式，其他字号、宽度、语言或系统动作下结果可能不同。改动前的一次截图尝试在“批注整段”上滑动而打开了其编辑页（隔离测试数据，未保存），该步骤已删除，未采集下滑后的画面。设备构建与签名检查通过，已覆盖安装到 iPhone 13 并启动，随后核对进程仍在运行；未卸载或清空数据，CloudDocuments／CloudKit 权限保留（`build/selection-merge-device-build.log`、`build/selection-merge-device-install.json`、`build/selection-merge-device-launch.json`）。真机菜单效果待用户确认。

“学习…”与“共享…”合为一个分组：临时 DEBUG 追踪显示系统原始顺序为 standard-edit、replace、open、format、lookup、learn、speech（“语音”：朗读、朗读…、暂停，展开列表中未显示）、share，三者选项均仅为内联；运行时 `UIMenu.Identifier.speech.rawValue` 为 `com.apple.command.speech`，与系统提供的一致。`ReadingView.mergingLearnAndShare` 在处理 lookup 与 standard-edit 之前，仅当原始顺序中连续出现仅为内联的 `.learn`、（可选的）`.speech`、`.share` 时，用一个无标题内联分组替换它们，子项为 learn 的原子项、原语音分组对象、share 的原子项；其他结构原样，追踪已删除。`testSelectionMenuJoinsLearnSpeechAndShareOnlyInTheSuppliedShape` 通过（三者、相邻两者、未知中间分组、非纯内联选项；用占位命令，只证明结构），原有结构用例仍通过。画面（同一隔离样例与排版，只截图）：默认动态字体下学习…与共享…同在一组，少一条分隔线，“从这里跨页选取”在面板底边被截断、露出一部分，形成可见的继续提示，设为章节仍在下方；辅助功能字号下仍只可见到搜索网页且底边干净，没有提示。学习…打开系统“自定义短语”并填入选中文字，以取消关闭、未保存；共享…从选区打开系统共享面板，未选任何目标即关闭。以上呈现以截图为证；用例只断言关闭后回到正文，不断言系统界面，也未验证完整的保存或共享流程。语音命令可见时的呈现未测试。设备构建与签名检查通过，已覆盖安装到 iPhone 13 并启动，随后核对进程仍在运行；未卸载或清空数据，CloudDocuments／CloudKit 权限保留（`build/selection-learnshare-device-build.log`、`build/selection-learnshare-device-install.json`、`build/selection-learnshare-device-launch.json`）。真机菜单效果待用户确认。证据：`build/selection-suggested-actions-2026-10-08.txt`、`build/selection-speech-id.txt`、`build/selection-learnshare.log`、`build/SelectionMenu-Shots/learnshare/`。

## 阅读页底部“目录／搜索／设置／更多”、更多四项与右上小说详情（2026-10-08）

底部四列等宽：目录、搜索、设置、更多均一步直达。“更多”与快捷设置相同，是同一 `ReaderBottomPanel` 中替换工具上方内容的一种模式；两者互斥、选中时使用强调色，四列工具固定不动，没有菜单或额外 sheet。常规字号下“更多”为“书签／书签列表／笔记／详情”四项，复用底部工具的 `ReaderToolLabelStyle`，与下方四列同字号、同列宽、同 56pt 可点高度，无图标底板，书签选中仅为实心强调色；辅助功能字号下改为同样短名称的纵向行，整行 52pt 为可点区域。“书签”名称固定，空心／实心强调色图标以原生符号替换动画切换（减弱动态效果时无动画），保存后面板保持打开，封面上与保存进行中不可用；辅助功能读作“书签”并带已添加／未添加状态与提示，“笔记”“详情”的辅助功能名称为“标注与笔记”“小说详情”，语音控制两种名称都接受。书签列表与笔记在同一 sheet 中沿目录展开路径展开；× 或下拉回小档回到“更多”，选择记录跳转正文后回到阅读，底部“目录”直接打开的目录仍关闭回阅读。小说详情保留导航栏右上原生 info（主题 ink）与“更多”的“详情”两个入口，返回均恢复打开前的面板；封面页“小说详情”保留。“更多”中显示仍可用的撤销行，快捷设置打开时仍隐藏并暂停。

列表闪现修正：此前首次打开书签列表或笔记时，sheet 先按默认 `tab` 绘制，`.task` 中 `prepare` 又因新书把 `tab` 重置为目录，并在等待目录与记录加载期间按目录绘制，且先按标注种类加载一次再换回书签。现在 `openLibrary` 在发布面板前同步调用 `tools.select`，sheet 不再有 `destination` 参数，`prepare` 换书时不再重置 `tab`；书签与标注共用的 `notes` 记录所属种类，切换到另一种时同步清空旧行、显示加载并以代次作废旧请求，同种刷新保留现有行。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 构建 | 模拟器 build-for-testing 通过 | `build/more-tiles-build.log` |
| 原生 | `testLibrarySelectionIsSynchronousAndDropsOtherKindRows` 通过：选择后标题种类立即为目标、等待自身记录；同种保留行；切到书签时标注行立即清空并显示加载；换书后仍保持所选列表 | `build/more-tiles-ui-1.log` |
| 定向 UI（标准、辅助功能大字号） | 均通过：封面上书签不可用；四列与右上 info 位置；四个图块标准字号同行等宽、详情在末位，大字号纵向排列，屏幕上可点高度均不小于 44pt；设置↔更多互斥且四列不动；保存后书签为已添加并保持打开；书签列表 × 与下拉回到“更多”；“详情”图块与右上 info 打开的详情都回到“更多”；选择记录回到阅读；搜索胶囊在“更多”关闭后恢复 | `testInlineMoreToolsBookmarkAndLists`（`build/more-tiles-ui-1.log`，改动拖动起点后复跑 `build/more-tiles-ui-8.log`）、`testInlineMoreAccessibilityType`（`build/more-tiles-ui-7.log`） |
| 受影响回归 | 通过：小说详情编辑与右上返回、目录样例、快捷设置锚定、撤销胶囊 | `build/more-tiles-ui-2.log` |
| 首帧画面 | 录屏 30fps 帧：首次从“更多”打开书签列表由图块直接过渡为“书签”标题与书签行，没有目录搜索框或章节行；随后切到笔记时，“标注与笔记”下没有出现书签行 | `build/more-tiles-video.mp4`、`build/MoreTiles-Shots/first-open-bookmarks-30fps.png`、`switch-to-notes-30fps.png` |
| 样式统一 | 底部工具样式复用后定向 UI 两项通过：标准字号下四项与下方四列中心、宽度各自对齐（2pt 内），可点高度不小于 44pt；书签状态、列表返回“更多”、详情返回、选择记录回到阅读、搜索恢复未回退 | `build/more-style-build.log`、`build/more-style-ui-1.log`、`build/MoreStyle-Shots/` |
| 画面 | 标准与大字号的图块、书签状态、列表、返回“更多”、搜索恢复 | `build/MoreTiles-Shots/`、此前 `build/MoreDock-Shots/` |

大字号可点高度：首次测得“书签”行 42.25pt。面板宽 386pt、屏幕 402pt，sheet 以约 0.96 缩放绘制，而当时 44pt 行高外的 4pt 上下边距不在按钮内；改为整行 52pt 可点后通过，44pt 断言保持不变。

未解决的验证限制（未在基线上比对，也未修改阅读内部或默认值）：大字号下从列表导航栏按两档高度差下拉，两次（默认速度与慢速停顿后松手）都弹回大尺寸，未回到“更多”；改为从 sheet 顶部拖动指示条按同样距离下拉后通过。标准字号下从导航栏下拉此前通过。原因未查明，留待用户在真机上判断。越过最小档的快速下拉会整体收起 sheet 回到阅读，这一行为未单独验证。`testReaderSettingsSectionsLiveParagraphsAndPersistence` 两次运行在两次点按左右边距增加后分别读到 24 和 28（期望 20），起始值随此前运行递增，似为模拟器中保留的偏好状态，未归因到本次改动，本次改动不写入边距。`testImmersiveControlsOverlayWithoutMovingText`（分页 `pageText` 底边 840 对 874，`ReadingView.swift` 只在滚动模式去掉底部 34pt 安全区；仅为源码解释）、`testBodyBookmarkAppearsInBothModesAndDisappearsOnRemoval`、`testReadingToolsPreviewBookmarkSearchAndNote`、`testReturningToLibraryClearsPreviewAndUndoCapsules`、`testReaderCoverScrollAndResume`、`testAnnotationTapRetainsWholeParagraphAfterReopen`、`testReaderBackRespectsPanelsSelectionAndPaging` 本轮未复跑，仍为此前记录的限制。若干次 xcodebuild 在记录用例结果后未退出，仅终止了本人的对应进程，不把这些命令的退出状态记为成功。未运行深色、iPhone 13 尺寸的 UI 自动化或全量测试。设备构建与签名检查通过，已覆盖安装到 iPhone 13 并启动，随后核对进程仍在运行；未卸载或清空数据，CloudDocuments／CloudKit 权限保留（`build/more-style-device-build.log`、`build/more-style-device-install.json`、`build/more-style-device-launch.json`）。手机上的交互体验待用户验收。

## 目录、书签列表与标注笔记分开；章节行与“回到当前章”（2026-10-07）

阅读页右上 (i) 改为原生“…”菜单：目录、书签列表、标注与笔记、小说详情；底部“目录”直接打开目录，底部书签仍一步添加／移除。三个列表各自标题与 ×，没有分段切换；目录栏内“…”只含整理目录／重新识别目录／恢复自动目录。章节行：短章名单行，右侧精确字数与累计估算覆盖；放不下时章名最多两行、说明在下方。固定定位按钮移除，改为列表底部按需出现的“回到当前章”。用户手机截图仅作参照；测试使用合成的通用章名目录（DEBUG `--ui-test-chapter-catalogue`，约 1 万字一章、含一个长章名）。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| UI 回归 18 项（模拟器 iPhone 18 Pro / iOS 27） | 13 项首轮通过：目录样例标准与辅助功能大字号、浅色目录与工具栏、工具栏 ink、章节计数与当前章（浮动返回替代旧定位）、目录纠错与重新识别、预览失败、输入收起、详情编辑与返回阅读、阅读中搜索、结构化批注冲突、删除批注选择、搜索胶囊。2 项因“目录”同时匹配菜单项与底部快捷而定位失败，测试改用 `showChapters` 后，`testCrossPageNoteCancellationDoesNotCreateAnnotation` 复跑通过 | `build/chapter-v2-regression.log`、`build/chapter-v2-rerun.log` |
| 目录样例行为 | 菜单四项可达；书签列表独立标题无分段；目录不含小说详情；当前章可见时无浮动按钮，滚走后出现、点按回到当前章并消失；输入时不出现，提交后筛选隐藏当前章时出现，点按清除筛选；关闭目录后正文位置不变 | `testChapterCatalogueRowsAndReturnToCurrent` |
| 画面 | 标准：短章名单行右侧“10,500 字 · —”，长章名两行并在下方显示说明，当前章强调色，浮动按钮位于最后一行下方；辅助功能大字号：各行改为章名在上、说明在下；浅色阅读配色下同样 | `build/ChapterV2-Shots/` |
| 原生 | 章节说明覆盖规则（恰为 0 隐藏，未知 —、未完成 +、不足 1% 保留）沿用上一节用例 | `build/chapter-b-native.log` |

未解决的验证限制（未在基线上比对，也未修改阅读内部）：`testAnnotationTapRetainsWholeParagraphAfterReopen` 在定位修正后改在长按选段一步失败，选中的是示例开头标题段而非章节正文；`testBodyBookmarkAppearsInBothModesAndDisappearsOnRemoval` 在改字号返回后点按正文，控件未收起；`testReaderBackRespectsPanelsSelectionAndPaging` 断言 `scrollText`，而示例以分页打开；`testReadingToolsPreviewBookmarkSearchAndNote` 的像素查找未找到已绘制批注。这些失败步骤都不经过新目录、列表或菜单代码，留待用户判断。

未覆盖：模拟器测试环境中目录样例没有产生阅读覆盖记录（含真实阅读后返回、重启），画面中覆盖均显示“—”；零、非零、不足 1% 与未完成计数由原生用例覆盖。模拟器测试未以 iPhone 13 尺寸运行；设备构建成功，已覆盖安装到 iPhone 13 并启动，随后核对进程仍在运行（`build/chapter-v2-device-build.log`、`build/chapter-v2-device-install.json`、`build/chapter-v2-device-launch.json`）。未卸载或清空数据，手机上的交互体验仍待用户验收。

## 工具栏图标颜色、目录 sheet 紧凑页头与章节行（2026-10-07）

工具栏导航、工具与新建图标统一由 `toolbarGlyph()` 使用当前主题 ink；根级 tint 仍为 accent，选中／当前、焦点、主要提交与破坏性颜色不变。目录 sheet 改为一条原生栏（一个“…”菜单含书名标题、小说详情与目录工具；中间分段控件；右侧 ×），辅助功能字号或放不下时分段控件回到内容区并显示书名；章节行章名整宽最多两行，其下一行合并字数与覆盖，仅“完整计数且覆盖恰为 0”时省略覆盖。用户手机截图仅作参照，正文内容未写入仓库。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 图标颜色（模拟器 iPhone 18 Pro / iOS 27，取像素） | 深色：书架齿轮与＋、对话齿轮与新对话均为同一 ink（248,234,222）。首次测量对话齿轮偏暗（222,210,198），其标签为单独 Image；改为与书架相同的 Label 后一致。浅色：书架齿轮与＋同为深色 ink | `build/ChapterB-Shots/dark/`、`build/ChapterB-Shots/light/` |
| 目录 sheet 画面 | 深色与浅色阅读配色下，栏内为“…”、分段控件、×，搜索行为输入框加定位；菜单首行书名；辅助功能大字号下分段控件在内容区、栏内显示书名；通过现有目录编辑生成的长通用章名两行显示，大字号下两行后截断 | 同上 |
| UI | 新增目录页头／行（标准与大字号）、浅色、工具栏用例均通过；目录纠错与重新识别、章节计数与当前章、预览失败、输入收起、详情与返回阅读通过 | `build/chapter-b-ui.log`、`build/chapter-b-ui2.log`、`build/chapter-b-ui3.log` |
| 原生 | TextLayoutTests 68 项通过，含新增章节说明覆盖规则（恰为 0 隐藏，未知、未完成计数、不足 1% 保留） | `build/chapter-b-native.log` |

`testReaderCoverScrollAndResume`：从封面详情点“返回阅读”后，回到封面的断言已通过（`readingChapter` 为“封面”）；随后测试有意停在封面时，`revealControls()` 因找不到 `readingSettings` 而改为点按 `pageText`，封面没有正文文本视图，于是失败。以干净 HEAD（c2bcac5）临时工作树单独运行该用例，同一步骤同样失败（`build/cover-baseline.log`），属本次改动之前已有的测试定位器问题，未修改产品状态或该用例；临时工作树已移除。

未覆盖：示例书在测试环境没有阅读覆盖记录，画面中各章显示“—”；零、非零、不足 1% 与未完成计数由原生用例覆盖，未截取对应画面。未安装手机。

## 可复用搜索页、阅读中搜索与对话结果快照（2026-10-07）

搜索页改为由宿主持有会话和结果动作：搜索 Tab 保持全局快速入口；目录“在此书架中搜索”和详情作者／标签推入当前导航栈的情境搜索，各有独立的输入、token 与结果，返回回到原目录或原详情，不切换 Tab，也不影响搜索 Tab 的会话。阅读中进入详情后的作者／标签搜索推在详情之上，原阅读会话保持暂停；按用户选择的策略，另一本书在其上打开，返回逐级回到原书与原位置；选正在读的这本书由阅读页提供的返回动作直接结束详情呈现回到原书。对话搜索结果改为快照，不再显示进行中／等待确认。对话命中范围、每个对话最新命中及整轮定位保持不变（见 design/ai.md 与 ai/agent.md 的记录）。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| UI 9 项（模拟器 iPhone 18 Pro / iOS 27） | 全部通过：阅读中搜索打开另一本书再返回、选当前书回到原书且位置不变、详情编辑与返回阅读、作者／标签情境搜索、全局与目录搜索会话互不影响、书架范围与所在文件夹、对话结果打开与定位、键盘收起、慢查询、英文深色 | `build/search-hosts-ui-final.log`；截图 `build/Search-Shots-Hosts/` |
| 原生 | TextLayoutTests 与对话搜索用例 | `build/search-hosts-native.log` |

过程记录：首次实现中，在详情之上调用详情自身的 dismiss 无效（同时有搜索页推在其上），改为阅读页通过环境提供“回到阅读”动作，直接结束详情呈现。回到原书时控件按进入详情前的状态恢复可见，紧凑章节标题因此隐藏；测试改用导航标题与阅读位置核对原书，没有为定位器改变产品状态。临时 DEBUG 记录已删除。

未覆盖：手机未安装；iOS 18 未运行；阅读中嵌套打开多层书籍未做长时间使用验证。

## 三个 Tab、原生取消与搜索键盘收起（2026-10-07）

改为“书架／对话／统计”三个 Tab 加尾侧系统搜索入口，设置由书架、统计、对话首页右上角的统一齿轮推入各自导航栈；设置子页和就近入口不变。取消（×）改用系统原生的清空并离开、回到来源 Tab，删除此前约 1 秒的查询／token 恢复判断；只有打开结果再返回时保留查询、结果与位置。

键盘问题证据分开：用户手机（iPhone 13，iOS 27.0.1）截图为顶部输入框、键盘弹出、无 ×、空白内容；从截图底部淡出的图标推断手机可能仍为较早构建，未确认。iPhone 18 Pro / iOS 27 模拟器在当前构建中复现同一布局：打开结果并返回后搜索为导航栏内未激活输入框，点其清除按钮获得焦点但没有 ×，点按、拖动空白都收不起键盘。修复只用原生能力：`.searchFocused` 绑定；结果列表上的同时点按只请求失焦（不作用于输入框、清除和 token）；`scrollDismissesKeyboard(.immediately)` 与 `scrollBounceBehavior(.always)` 使空页也可拖动收起。仅此即解决，未加入“获得焦点即进入激活态”的规整。实测发现对话结果行原为 NavigationLink，键盘弹起时第一次点按只收起键盘、不打开对话（旧断言因摘要含同样文字而误通过），已改为与书籍行一致的 Button 推入同一路由，并改为断言聊天页实际打开。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| UI（模拟器） | 11 项定向用例中 10 项首轮通过；对话用例按上述原因修复后，与键盘用例复跑均通过。覆盖空页点按／拖动、重新聚焦、有结果点按保留文字和行、行点按打开阅读、返回无键盘、返回后清除再点按／拖动收起、书架 token 筛选下点按保留 token 且不回目录、取消清空并回来源（首页／目录）、设置信息结构与 Tab 可见性、AI 连接设置入口 | `build/tabs-b-ui.log`、`build/tabs-b-ui2.log`、`build/search-keyboard-ui.log` |
| 原生 | TextLayoutTests 与对话搜索共 68 项通过 | `build/tabs-b-native.log` |
| 画面 | 首页左上齿轮、三个 Tab 加尾侧搜索圆形按钮；设置页推入且书架 Tab 选中；键盘收起后仍在搜索 | `build/Tabs-B-Shots/`、`build/Search-Shots-Keyboard/` |

未覆盖：手机未安装新构建，修复在手机上的效果未验证；iOS 18 未运行。

## 搜索快速入口：独立显示、聚焦与取消回到来源（2026-10-07）

已安装 iOS 27 SDK 接口：`Tab(role: .search)` iOS 18+，`tabViewSearchActivation(.searchTabSelection)` iOS 26+，`TabRole.prominent` iOS 27+（Beta，与 `.search` 为不同角色，未采用）。实现为搜索 Tab ＋ 其 NavigationStack 上的 `.searchable` ＋ TabView 上的选中即激活；没有自绘浮动控件。把 `.searchable` 放到 TabView 的试验会在书架页导航栏也出现搜索框，已放弃。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 实际画面（iPhone 18 Pro / iOS 27 模拟器） | 搜索为四个导航 Tab 旁的系统圆形按钮；书架页无搜索框；选中即聚焦底部输入框；从阅读返回保留结果且无键盘；取消回到书架首页；再次进入恢复“山”及结果；书架 token 搜索取消回到“我的书架”目录，再次进入保留 token 与范围结果 | `build/Search-Shots-Detached/` |
| 事件顺序 | 临时 DEBUG 记录证实系统取消先清空文字、约 3ms 后报告退出，此时系统已回到上一个 Tab；据此以“已不在搜索”判定离开并恢复会话。记录代码已删除 | 本节说明 |
| UI 7 项 | 全部通过，新增“选中聚焦／清除不离开／取消回来源并保留查询／书架范围回目录并保留 token” | `build/search-detached-ui-final.log` |
| 原生 68 项 | TextLayoutTests 与对话搜索用例通过 | `build/search-detached-native.log` |

未覆盖：iOS 18 回退（普通搜索 Tab、取消回来源）未在 iOS 18 模拟器运行；“清空后 1 秒内取消”会按离开恢复清空前内容，属有意取舍；无手机安装。

## 统一搜索、对话定位与下拉刷新（2026-10-07）

范围：原生搜索 Tab（书籍／文件夹／已列出对话、作者／标签／书架 token、Rust 排序）、对话搜索与历史窗口定位、最近阅读／书架管理下拉刷新、统计／小说详情完整重读，以及书架刷新合并等待。使用项目 Nix 工具链、`build/AIDerivedData`、`-skipMacroValidation`、iPhone 18 Pro / iOS 27 模拟器。

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| Rust 核心 | 59 项通过、1 项保持忽略；新增排序／扩展名／作者／标签／书架范围用例；`cargo fmt --check` 通过 | `build/search-refresh-core.log` |
| 构建 | 应用与测试 build-for-testing 成功 | `build/search-refresh-build.log` |
| 原生（AIStageOne、AIRepository、TextLayout、AIFollowUp 共149项） | 新增对话搜索／历史窗口与刷新合并两项通过；另有 AIStageOneTests 3 个用例 4 处断言失败：`testUnifiedSelectionDraftValidationAndSaveTargets`（2 处）、`testPickerEffortDisplaySaveAndRequestAgree`、`testReadingAttachmentsPersistRemovalAndDoNotLeakFixedContext`。它们断言未发送会话重载后仍存在、附件保存后保留调用方 id，对应此前“草稿只留内存／独立出现项”行为；本轮未改相关代码，未做干净 HEAD 基线复跑 | `build/search-refresh-native.log`；运行在 “Selected tests” 完成后卡于收尾，已只停止该 xcodebuild 进程 |
| UI 7 项 | 全部通过：搜索 Tab 关闭清空、全书架结果→阅读→返回保留查询与结果、目录菜单书架 token、作者／标签 token、英文深色、慢查询转圈与关闭不发布迟到结果、网格不再有目录放大镜、对话命中定位与回到最新 | `build/search-refresh-ui-final.log`；截图 `build/Search-Shots/` |

实际画面已查看：搜索 Tab 为 Tab 栏第五项，输入框在导航栏；结果行书名命中强调、进度与“书架 / 路径”；author 与书架 token 为系统 chip；从阅读返回后查询和两条结果保留且键盘未弹出；对话行显示“你：”摘要；打开后命中消息位于屏幕中部，上方保留较早上下文。首次实测发现定位被底部锚定覆盖、且“回到底部”与“加载较新消息”重叠，已改为窗口模式不锚定底部并在窗口末尾隐藏“回到底部”，复测通过。原 `testBookshelfGlobalSearchLocalSearchAndNestedNavigation` 依赖滚动模式 `scrollText`，当前会话以分页打开，测试改为接受两种阅读布局。

未覆盖：命中底色强调在截图时已淡出，未单独截取；下拉刷新手势未做 UI 自动化（合并等待由原生用例覆盖）；没有真实 iCloud／CloudKit、外部书架提供方、手机安装或长对话性能实测。

## AI 统一会话与工具结果（2026-10-06）

普通对话首次发送前只保留内存草稿，发送后与入口任务共用持久会话、历史、head 与会话关联的外部存储图片；转入只改变列表分类和入口关联。原始工具结果只来自成功提交的历史，每次打开从原始结果和当前业务数据建立新审核，关闭丢弃编辑和选择，不保存审核草稿或操作成败状态。图片由实际解码决定可用性，不按后缀、MIME 名单、固定大小或格式名单提前拒绝。

本轮使用项目 Nix 构建阶段、`build/AIDerivedData`、`-skipMacroValidation`、签名 iPhone 18 Pro / iOS 27 模拟器和串行测试。结果如下：

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 应用与测试宿主构建 | 通过 | `build/ai-unified-integration-build-06.log`、`build/ai-unified-native-02.log` |
| 受影响原生回归 | 当前 45 项分次通过：首轮保留的 38 项与调整后的 7 项 | `build/ai-unified-native-01.log`、`build/ai-unified-native-02.log`、对应 `AI-Unified-Native-01/02.xcresult` |
| 受影响 UI 回归 | 8 项分次通过：首轮 3 项，修正定位后复跑 5 项通过 | `build/ai-unified-ui-01.log`、`build/ai-unified-ui-02.log`、对应 `AI-Unified-UI-01/02.xcresult` |

原生覆盖运行器 30 项、图片首次引用与历史保存、会话重开、提交前没有可操作卡片、封面重新审核与同候选再次应用、独立图片附件出现项，以及图片工具的实际字节消费。首轮有三项失败：一个无关屏幕缩放断言，以及两个人工注入删除保存失败的 SwiftData 内存回滚崩溃。按真实流程验证的要求，移除了失败注入及测试专用 hook，不为该人为异常修改正常保存／回滚代码，也不宣称失败回滚已验收。随后定向 7 项全部通过，实际使用 SQLite 验证保存、重开、会话／历史／图片级联删除，并验证会话删除后已应用的小说作者及独立封面字节仍存在。

UI 首轮通过模型启用／搜索、封面候选／工具详情／应用、转入后同一 sheet 与原入口重新打开。资料、笔记与整理等五项因子控件标识被外层卡片标识覆盖而定位失败；仅按实际控件树修正测试定位并保留业务断言，复跑 5 项全部通过（144.632 秒）。验证资料保存与再次应用入口、笔记编辑丢弃／现有编辑器提交、整理真实目录执行以及移除任务后已保存资料保留。附件位于 `build/AI-Unified-UI-Attachments-01/02/`，已查看资料审核／保存和整理执行画面。

测试使用隔离仓库／文件、离线模型及工具和 URLProtocol；没有真实登录、付费模型、搜索／生成／下载服务、手机安装、CloudKit／iCloud 或真实跨卷故障验收。此前临时任务、资源提升和持久审核状态的测试结论不作为本轮统一架构通过证据。普通模拟器启动成功并查看书架画面，记录 `build/ai-unified-normal-startup.log/png`；未重置应用数据。当前构建与上述受影响流程回归通过；未执行全套测试。

### 快捷启动、普通对话标题与封面候选呈现

快捷入口在点击时同步进入 starting，异步创建成功或失败后释放；普通全局对话用首条用户消息前40字符命名，与首次列入列表、发送队列和草稿消费同一事务，后续发送及已有书籍／任务标题不覆盖。候选“当前／已应用”标记和对应预览分支已移除，每个候选保留“设为封面”；实际业务封面对比缩略图、变化检查及即时保存反馈保持。

项目 Nix 工具链、`build/AIDerivedData`、`-skipMacroValidation`、签名 iPhone 18 Pro / iOS 27 模拟器定向构建和测试通过，3 项原生 + 2 项 UI 共 5 项全部通过（`TEST SUCCEEDED`）。原生验证首条标题／队列／列表／草稿同次保存、当前投影与持久标题一致且无额外命名请求，以及同封面重新应用；UI 验证开始前设置入口及候选／工具详情／预览／实际保存，成功后“设为封面”仍可用。日志为 `build/ai-pr6-scoped-latest-01.log`，结果包为 `build/AI-PR6-Scoped-Latest-01.xcresult`。

测试使用离线传输和隔离夹具，没有真实供应商调用或手机安装。Start 快速重复点击排除及失败恢复有源码检查，开始前 UI 回归不等于快速连点的运行时验收。AI 自动标题暂缓；用户当前试用的搜索尚未返回可用直接图片链接，离线封面夹具不能作为真实搜索已可用的证据。图片限制继续暂缓，本次未新增后缀、MIME 或大小门槛。

### 发送提交、内存草稿与存储精简

所有未发送文字和附件只留内存；普通新对话首次发送才创建数据库记录。首次发送原子保存会话、模型选择、首条队列及图片资产。schema 已删除 draft、readingDraft、readingDraftInitialized 和 draftRevision，延迟保存、saveAll 和草稿恢复路径也已删除。提交 Task 存在时禁用整个输入区，服务同时拒绝文字、附件和模型修改；完成或失败后释放，原先聚焦的输入框在可见页面恢复焦点。提交后允许再次发送相同内容；请求生成期间保留 steering／follow-up。

请求失败由运行器和历史映射；临时操作失败只发送即时事件，由当时可见的所属页面呈现可关闭原生提示，服务不暂存错误等待其他页面出现。删除入口只向调用者抛错，避免重复提示。提交失败保留内存输入供重试；已有任务、已提交队列、历史、检查点和资产保持持久。消息入队单独保存活动时间，转入任务的 follow-up 不依赖列表分类变更。

另外删除确认未使用的 books.normalization_version、AI 会话 created、StatisticsClear.id、PositionValue.updated 和 checkpoint.model；位置暂存交接删除不可达通用 Value/device 分支，仍保留位置、批注和事实的事务交接。Rust 当前 schema 为 15，只接受当前格式，不提供旧开发库迁移或兼容。UserData CloudKit 所需默认值、活跃实体、关联和索引保持。

初轮 13 项定向原生回归通过：`build/ai-memory-drafts-native.log`。存储精简后构建、13 项原生及 1 项阅读 UI 回归通过：`build/ai-storage-cleanup-final.log`，覆盖 SQLite AI 队列/历史/图片重开及级联删除、位置交接幂等与排序、统计清除及晚到事实、摘要检查点，以及内存草稿、失败重试和提交锁定。Rust 核心 58 项通过，1 项长书测量保持忽略：`build/storage-cleanup-core.log`。所属页面即时提示与活动时间修正后，5 项原生和 1 项阅读 UI 定向回归通过：`build/ai-send-notices-final.log`，验证转入任务的后续消息活动时间重开一致、单次失败通知、失败重试与提交锁定。新增无模型配置的阅读发送错误提示及快捷入口 UI 两项通过：`build/ai-operation-notice-ui.log`；验证原生提示可关闭、草稿保留及返回 AI Tab 后不重放，不发供应商请求。两项用例均报告 passed 后，xcodebuild 在结果收尾阶段未退出；中断后出现 IDE 内部断言，已终止该测试命令，不将这次命令记为 TEST SUCCEEDED。所有测试使用隔离仓库、离线 URLProtocol 和模拟器；没有真实供应商、手机或 CloudKit/跨设备验收，未执行完整 iOS 测试集。

### 历史增量更新与结果数量文案

运行活动只更新流式文字、推理、head 和状态，不查询或替换历史列表。首次连接读取最新 50 条，用户加载旧页时按 ID 向前合并；已加载范围保持，分页不能覆盖更晚的记录更新。数据库提交返回新增记录及对应终态变更，服务按 ID 追加/替换；消息结束、失败或停止保持记录身份。步骤记录提交后，先整理对应实时文字/推理，再一起发布，重入的队列/模型选择或流式通知不能提前发布尚未整理的步骤。

任务入口仅显示名称和当前运行/等待确认状态，不统计历史结果总数，也不表示未查看或未应用。移除提示说明任务及其结果会删除、已应用修改会保留；不新增应用状态或处理标记。

Xcode iPhone 18 Pro / iOS 27 模拟器构建和 39 项定向原生回归通过：`build/ai-history-publication-final.log`。覆盖 120 条历史连续加载、重复分页去重、流式及新增消息期间保留全部旧记录、停止终态按原 ID 更新、分页不覆盖较新终态，以及原有队列/取消/工具/压缩/恢复回归。受控时序测试在步骤已入库、实时文字尚未整理时插入模型选择，确认不会同时显示已提交和实时的相同回复。初轮长历史夹具手工编码不符合 SDK 消息结构，修正为实际 ModelMessage 编码后通过；不为夹具增加协议兼容。

资料应用与任务删除两项 UI 回归及数量文案原生用例通过：`build/ai-result-wording-ui.log`。验证结果行应用前后计数不表示处理状态、删除提示的实际文案，以及删除任务后已写入资料仍存在。用例均报告 passed 后，xcodebuild 再次停在测试收尾，已终止进程；不把该命令退出状态记为成功。测试使用隔离仓库、合成离线模型和 URLProtocol；没有真实供应商调用、手机或跨设备验证。源码中流式活动不再调用历史读取，未声称已完成真实长对话性能测量。

### 阅读会话归属与消息结果

阅读助手只使用本次阅读打开时选择的对话。关闭/重开助手保留该选择；实际退出书籍后，在弹窗关闭且返回完成时清理选择，再次进入默认新建对话。月亮不查找运行中或历史 SHA 对话；异步创建在赋值前复核取消、阅读仍活动及选择未变化。旧任务继续独立运行，历史选择保持显式操作。

结果从当前已加载的成功工具消息获得，按 entry/call/session 身份传递给卡片和复核；分页边界的工具结果不依赖已加载前一条调用。类型化结果在消息进入会话投影时解码，只随该加载范围存在；payload 改变才重解码，终态及流式更新不重解码。删除启动 loadResults、全局结果目录及 resultCount 汇总，任务入口只显示名称/当前状态；编辑、选择、应用中状态和反馈仍只属于本次复核。原始历史是唯一持久来源，来源/图片出处查询仅在实际操作需要时读取 owner 历史。

来源解析对 rg 的 partial 接受有效命中，不改其他工具或提案的成功规则，原有范围、引用和 owner 校验保持。已覆盖实际 rg 默认100条、显式2条分页及 SQLite 重开后的资料来源使用，并验证未知、未提交、跨 owner 引用仍不能解析。

初轮构建及30项原生通过：`build/ai-message-results-native.log`。最终消息投影缓存、运行器和来源回归36项通过：`build/ai-typed-projection-final.log`（TEST SUCCEEDED）。包含类型化结果归属、payload 失效、旧页不复活较新失效结果、分页边界卡片、120条历史、阅读新会话与旧运行线程并存，以及现有工具/队列/压缩/中断回归。

修正无数量入口定位后，5项 UI 和24项原生用例全部报告 passed：`build/ai-owned-message-results-final.log`。UI覆盖阅读弹窗重开保留输入、退出书籍再进入创建新输入，以及资料、封面、笔记应用和删除任务保留业务修改。首轮3个UI失败是测试仍以“名称 · 数量”寻找入口，改为名称/名称加状态定位并保留业务断言后通过。Xcode再次卡在用例结束后的收尾，已终止进程，不将该命令记为成功。所有验证为离线夹具、隔离仓库及iOS 27模拟器；无真实供应商、手机、跨设备或长会话性能测量。

## 统计日期删除后返回（2026-10-05）

普通导航返回时，StatisticsView 的 `.task(id: window)` 重新加载数据；隐藏页忽略统计通知不影响返回后的刷新。生产代码保持原文，没有新增刷新状态。

- 总览 → 当天 → 删除 26 分钟会话 → 返回：范围总时长 255→229 分钟，当天柱 57→31，书目行 113→87；4 个阅读日和 3 本书保持。
- 总览 → 书页 → 当天 → 删除该书当天唯一会话 → 先回书页：期间 113→87 分钟，累计 148→122，当天 26→0、显示空记录，阅读日 4→3；再回总览，数值为 229/31/87 分钟，日数和书数保持。两条均等删除完成后返回，保持近 7 天范围，不切 Tab、不手动刷新。
- 两条数值回归通过，最终日志 `build/pr5-delete-pop-final.log`、结果包 `build/PR5-Delete-Pop-Final.xcresult`。使用 Xcode 签名模拟器、项目 Nix 构建阶段、`-skipMacroValidation` 和 `build/AIDerivedData`；隔离 fixture 等待范围合计 255 分钟，本书累计另等完整 148 分钟。
- 既有记录开关和排版未变；删除推进的共享 generation 整数按开工快照还原，仅还原持久偏好，未另做重启检查（`build/pr5-preference-restoration.log`）。未清空应用数据，保留隔离 fixture 和新增独立缓存。未运行全套、安装真机或验证真实云端及最低系统；调查日志和打印已移除。

## Swift 源码目录整理（2026-10-04）

范围：33 份根级 Swift 文件移动到功能目录，按现有类型边界新增 7 份拆分文件；保留完整 BookMetadata、ReadingStatistics 与 LibraryPresentation 的 LibraryBookCover。改善文件导航与职责呈现，未改变 owner、actor 隔离、任务生命周期、JSON 投影、Swift/Rust 契约、存储 schema 或产品行为；未放宽 private/fileprivate。原有 file refs、Sources UUID 与 target membership 保留，新增文件显式加入应用 target，Xcode groups 对应真实目录。AI、资源、签名配置及部署下限保持。

- 项目 Nix Rust 构建阶段及 Xcode 27 模拟器构建通过：`build/swift-folders-build.log`。使用 `-skipMacroValidation`、`build/AIDerivedData`，目标 iPhone 18 Pro / iOS 27。工程 plist 检查通过；25 份未拆分文件逐字节保持，拆分前后业务代码行对照保持。
- UserDataTests 23 项、TextLayoutTests 65 项全部通过；额外两项现有 CloudAccountTests（CloudStore 账户确认、云设置窗口挂载）通过，共 90 项原生测试。日志及结果包：`build/swift-folders-regression.log` / `build/Swift-Folders-Regression.xcresult`、`build/swift-folders-focused.log` / `build/Swift-Folders-Focused.xcresult`。云用例使用注入身份和本地 SwiftData，不代表真实云端。
- 4 项现有 UI 用例通过：开书/详情编辑/返回阅读、章节临时查阅确认续读、搜索临时查阅退出并恢复正式位置、设置层级及统计记录页面导航。统计图表书目行与排版模式断言失败；定向复跑这两项并补现有原生阅读预览用例，3 项均在 fixture 或默认偏好断言处失败。两轮 test 命令返回 65，不能声称 UI 全部通过。
- 失败证据：既有设置用例暂停记录并选择分页；`ReaderService.sourceDefaults` 仍使用 UserDefaults.standard，UI-test session 只隔离用户数据目录，未隔离统计开关和 readerSettings。只读当前模拟器应用偏好确认 `Moonread.statisticsEnabled=false`、`mode=Pages`，字号保留前次修改。统计 fixture 经 saveReading 使用当前记录开关，因此没有可用统计书目行；排版首轮期望滚动而实际分页，复跑及预览的固定字号断言也受保留值影响。未清空数据、调整产品偏好存储或扩大到测试隔离修复。
- 普通模拟器启动成功：`build/swift-folders-startup.log`、`build/swift-folders-startup.png`；测试画面附件导出到 `build/Swift-Folders-Attachments/` 和 `build/Swift-Folders-Preview-Attachments/`。已查看普通启动书架、排版修改页面与全屏阅读预览画面；启动与局部画面检查不代替未通过的完整统计图表/排版持久化 UI 路径验收。
- 未执行真机安装、iOS 18 运行、真实 CloudKit / 两设备同步或完整 UI 审计；未提交、推送、重置应用数据，也未操作外部/iCloud 小说原件。历史验证和构建日志路径保留。

## AI 正文范围检索与前后文（2026-10-04）

- `rg` 支持单书 chapterRef / startUtf8 / endUtf8 范围，Rust 在扫描前限定边界；继续使用有效章节投影。`read` 支持 contextOffsetUtf8 与前后非空段数，Rust 处理 UTF-8 边界，AI 结果继续按预算分页；工具数仍为10。
- Rust 定向16项通过（library_tools 8项、user_projection 8项），包括全书前部超过2000命中时仍可搜索后部章节、范围越界、多字节字符边界及前后空行：`build/ai-scoped-tools-rust.log`。
- 应用及测试宿主构建通过，iOS 27 模拟器 AIReadingToolsTests 8项通过：`build/ai-scoped-tools-swift.log`。覆盖 SDK typed 参数、章节限制、正文范围排除、命中位置展开前后文、非法组合、原有分页及无正式阅读副作用。
- 本次没有接入网页工具或编码转换工具，没有更改数据 schema 或添加历史兼容。未在真实模型中重跑历史小说问答，未安装手机。

## AI 前置接入验证

两个候选库已联合链接为独立 iOS 验证应用，在 iOS 27 模拟器启动并检查中文 Markdown 明暗画面；最低部署版本设为 iOS 18，不代表 iOS 18 运行验收。SDK 默认停止和小块 SSE 交付的两个测试失败，已通过公开 fetch 注入验证任务独立取消与及时交付可行；三种 HTTP 停滞/输出场景通过，服务端确认连接断开。两轮工具调用、下一步模型替换及中文上下文替换通过 mock 验证。详情与证据见 [AI 可行性](ai-feasibility.md#独立实测网络与-ios-构建)。

以下是独立原型的证据，产品接入情况见下方 AI 产品验证。宿主机上的 Codex 设备码登录、一次正常刷新、真实工具循环、生图与参考图编辑已通过；同一文本工具循环也在独立 iOS 27 模拟器应用中运行通过。证据与适用范围见上述 AI 可行性文档。iOS 完整授权、完整压缩与追加消息队列、长历史及真机交互仍未验收。

## 书架文件定位与 SHA 关联（2026-10-12）

正式实现以规范化正文 SHA 为唯一内容身份，原始 SHA + 解码策略只作快开映射。扫描按路径与类型保留最后已知关联，大小／修改时间不参与身份；普通文件及目录移动携带关联，不重新哈希整棵树。SourceImportWork 在后台协调读取完整原始 SHA，可取消；导入那一遍同时哈希实际解码输入，与期望值一致才在完成事务发布映射。暂停续读拒绝前缀、尾部或同大小替换，保留旧正文与用户数据，由用户显式“重新准备”才创建新任务。任务 generation 保留。

云交接保留意图、copied、published、路径、file id、原始 SHA、关联及解码策略，恢复时检查实际目标字节，删源前同次协调访问复核两端；源缺失仅允许已发布记录。移动后立即重绑暂停来源，重启从当前file id重新定位。AI提案比较已下载源原始SHA及授权根；未准备文件不主动下载，目录仍复核子项占用，不承诺识别同路径同结构目录替换。

- Nix Rust核心67项通过、1项原有长书测量忽略，`build/LibraryIdentity/rust-final-tests.log`；严格Clippy `--all-targets -- -D warnings`通过，`clippy-final.log`。新增覆盖扫描保留、文件与目录互换、跨书架／整目录移动、外部改名接回、真实内容变化保留旧书、同字节不同解码策略、暂停后前缀／尾部／同大小替换、预哈希后及解码中原始输入变化不发布错误映射、归并回收后的云回执、失败扫描和交接事务回滚。旧版本指纹测试已被SHA契约测试替代。
- Swift定向53项中52通过、1项既有用例跳过，`swift-final-tests.log`为TEST SUCCEEDED。涵盖真实本地文件改名／移动／目录移动、移动后不重开页面直接续读及重启续读、外部改名后的缓存接回、内容替换后旧位置和书签保留、云交接提交边界中断／部分清理／新文件出现／目标替换、同大小AI源变化拒绝及目录占用变化。首轮唯一失败为旧测试仍要求扫描内容变化清空book_id，改成新契约后通过；没有放宽字节一致性断言。
- 最后符号链接路径保护和提示文案调整后，6项受影响Swift测试再次通过，`swift-affected-tests.log`为TEST SUCCEEDED。独立模拟器会话启动正常，书架显示预置本地书目，截图`startup.png`已目视核对；启动日志`simulator-launch.log`。
- 签名Release构建成功，`build/LibraryIdentity/device-build.log`为BUILD SUCCEEDED，`codesign --verify --strict`通过。交付包为`build/LibraryIdentityDevice/Build/Products/Release-iphoneos/Moonread.app`，不含临时测量代码；`git diff --check`通过。
- 前置热缓存测量见本文顶部；随后真机试用确认重新连接书架可接回进度，移动后封面、进度和资料保留。真实 iCloud 目标逐出、上传和跨设备交接仍待环境验收，不以该试用代替所有云场景。
- reader.sqlite3升级为schema17，按开发约定不迁移、不兼容旧格式，不新增自动清理逻辑；现有schema16会报IncompatibleStore，安装前需处理旧开发正文／索引／任务缓存。用户SwiftData、小说原件、AI数据与凭据未被本轮代码或工具清理。本轮不安装、不操作手机，不提交、不推送。


## 设置页面信息架构（2026-10-02）

首页使用原生 Form/Section/NavigationLink，依次为阅读、书架与同步、应用及独立关于组，统一符号与当前值摘要。阅读记录设置由首页与统计 Tab 复用；减弱动态效果移入外观；屏幕方向与阅读方式区分。iCloud 按阅读数据与固定书架文件分组，首页明确显示阅读数据的开关／异常状态，关闭阅读数据不改变小说文件同步。

- 项目 Nix 构建阶段及 iOS 27 / iPhone 18 Pro 模拟器构建通过，初次构建日志 `build/settings-build.log`；最终代码也由后续 UI 测试构建。
- 四项关键 UI 分次通过：原生阅读预览与返回见 `build/settings-ui1.log`；首页顺序、记录状态摘要、分页摘要、外观摘要、统计 Tab 复用、清理后重启及英文深色最大辅助功能字号见 `build/settings-ui2.log`。首轮清理用例假定记录初始开启，前一用例暂停后无条件切换导致断言失败；测试改为根据真实开关状态明确暂停，产品记录／清理语义未改变。
- UI1/UI2 的 xcodebuild 在断言结束后卡于结果收尾，已仅停止对应进程；日志中的通过结果不代表这些执行正常生成了结果包。两项设置画面复跑正常完成于 `build/settings-ui3.log` / `build/Settings-UI3.xcresult`，附件在 `build/Settings-UI3-Attachments/`。测试截图也直接保存在测试进程临时目录，避免结果包无法收尾时丢失可读取的画面证据。深色最大字号首页上下部分及外观开关画面已查看，换行后仍可滚动访问和操作。
- 显式浅色和摘要定向复测通过于 `build/settings-ui4.log` / `build/Settings-UI4.xcresult`，浅色首页及外观截图已查看，附件在 `build/Settings-UI4-Attachments/`；测试明确选择浅色，避免受此前设备偏好影响。普通模拟器启动成功，进程仍运行，证据 `build/settings-startup.log`、`build/settings-startup.png`；启动书架画面已检查。
- UI 测试按既定配置禁用真实云能力；本轮 iCloud 分组与异常显示通过源码和构建检查，未执行真实账户异常、跨设备同步及系统语言设置跳转。iOS 18、VoiceOver 实际朗读与真机画面仍未验收。设置页已覆盖安装并启动，尚未做真机画面验收。

## 当前真机交付（2026-10-02）

当前为包含设置页整理、文件版本关联交接和同步账户意愿修复的云能力版本，使用默认配置及开发者团队自动签名构建，通过覆盖安装到 iPhone 13 并成功启动，未重置测试数据。新描述文件及应用签名已确认包含 iCloud Documents、CloudKit、指定云容器和开发推送权限。证据：`build/cloud-account-device-build.log`、`build/cloud-account-device-install.json`、`build/cloud-account-device-launch.json`，产物位于 `build/CloudCapabilityCheck`；临时日志可能被系统清理。安装与启动不代表真实跨设备同步、真实 iCloud 文件交接或全部真机交互验收。

## 阅读数据同步账户状态（2026-10-02）

Xcode 27、iPhone 18 Pro / iOS 27 模拟器，项目 Nix Rust 构建阶段及 Swift 构建通过，5 项定向原生回归通过：用户意愿与实际状态分离、账户不可用及同账户恢复、构建不支持时保留意愿、主动关闭、不同账户取消/重复刷新/确认、确认期间账户再次变化、初始化失败重试，以及旧初始化失败不回退新配置。原生 SwiftUI 设置页与确认弹窗已挂载到窗口，检查了大字号及英文视图文案，开关保持开启而同步暂停，设置确认入口与提示可见。

证据：`build/cloud-account-final.log`、`build/CloudAccount-Final.xcresult`、`build/CloudAccount-Shots/`；普通模拟器启动成功进入书架，画面见 `build/cloud-account-startup.png`。账户和存储工厂使用注入身份及本地内存 SwiftData，设置视图的 locale 注入只作用于视图文案；预先生成的状态消息仍使用运行进程语言。这些测试不代表真实 CloudKit 账户退出、框架清除本机资料、跨账户在途操作或两设备同步验收。接受系统退出账户后的原生资料保留语义，不增加备份恢复层；统计计算、清理和小说原件保护逻辑未改动。

## SwiftData 用户数据层（2026-10-02）

环境：本机 Nix 锁定 Rust 工具链，Xcode 27，iOS 27 / iPhone 18 Pro 模拟器。本轮按约定卸载并重装开发 App；没有旧格式迁移、兼容或备份，未操作外部目录或 iCloud 小说原件。

- Rust 当前核心 46 项通过，1 项原有长篇测量保持忽略；严格 Clippy `-D warnings` 通过。覆盖正文/编码/章节、导入暂停与恢复、来源缓存、Unicode 位置换算、统计时长和连续覆盖。新增检查确认用户投影只在 TEMP 表，重新打开 `reader.sqlite3` 不保留用户记录。
- 现有原生 57 项分次回归；全套运行有一项菜单过渡时序断言失败，改为等待原生过渡完成后定向复测通过。正式位置、临时查阅、离开阅读、批注合并、目录、图片及实际文件改名/移动/删除回归已通过。
- SwiftData 22 项通过：范围与空评论冲突、三个候选、相同编辑、陈旧解决、旧/新基线删除、撤销与离线编辑、合并条目与旧编辑的同页冲突、事实重试/重叠/清理、待定正文转入、外存附件与重启、ModelActor 后台执行和本地 context 提交可见性。本地 context 测试只验证存储可见性，不是双设备 CloudKit 验证。
- 当前批注编辑的临时内容仅在内存，取消丢弃；过去的持久草稿恢复结果不再作为当前产品行为。当前取消、确认与冲突 UI 结果见下面的最终业务边界验证。
- 400 KB 合成附件确认为邻接外部二进制文件，重启后字节一致；附件缺失返回空并使用文字封面。500 个元信息字段的后台批量保存约 0.44–0.46 秒，主线程判定为 false；这不等于长篇阅读叠加真实云导入的性能验收。

最新设备偏好交接调整后，模拟器构建及连续六次开书、位置/书签保留与任务回收的定向回归通过。再次卸载重装后启动正常，实际画面为固定“我的书架”、一本文本欢迎书与三个 Tab。

审查修复的原生定向回归为 19 项通过（18 项用户数据测试和原有相交批注合并测试）：整组合并条目共同参与冲突检查，后续条目的 A/B 评论不会被普通保存消耗；覆盖链式相交、新候选/新条目使旧解决操作失效、保留两者与手动编辑后只留一条、合并后再次普通编辑。删除选择关闭后仍保留冲突，重新选择保留可编辑，完成删除才留下单一删除结果。正式与待定存储在可控初始化失败后能重试；并发调用共享一次初始化，旧失败不能清除替换任务或回退新云配置。证据：`build/swiftdata-review-native-final.log`、`build/SwiftData-Review-Native.xcresult`。这里的配置测试使用注入工厂，不证明真实 CloudKit 账户启停。



证据：`build/swiftdata-core.log`、`build/swiftdata-clippy.log`、`build/swiftdata-native.log`、`build/swiftdata-ui.log`、`build/swiftdata-final-build.log`、`build/swiftdata-final-startup.png`；原生和 UI 结果分别见 `build/SwiftData-Store.xcresult`、`build/SwiftData-UI.xcresult`，截图见 `build/SwiftData-UI-Shots/`。

未验收：iOS 18 实际运行、同账户两设备自动上传/下载、账户切换和启停时旧容器在途操作、并发对象全量交付、附件迟到、统计清理的离线/时钟偏移传播、真机长时阅读。没有以本地注入、两个 context 或模拟器构建代替这些结果。


### 最终业务查询与取消编辑（2026-10-02）

- 删除批注的 UserDefaults 草稿、自动写入及消失收尾路径；X 和下拉关闭丢弃未提交文字、范围和冲突选择，勾号才保存。明确高亮动作仍立即保存。未解决的正式冲突关闭后保留。
- 业务读取创建独立只读 ReaderQuery，删除 set_user_projection 共享写入接口。当前章、目录、前后章、百分比定位、正文段落语义、搜索归属、书架/详情及统计都使用业务组装后的有效数据。搜索的正文前缀、身份和有效目录在同一事务内固定，后续批次不混入新目录版本。
- 封面业务层监听实际 ModelContext.didSave、持久存储远端变化及系统导入完成；等待附件不阻塞开书，多个同资源/尺寸订阅共享加载。始终挂载透明承载视图，避免空 Group 无子视图时订阅任务不启动。资源 ID/哈希/尺寸和任务代次隔离旧图片与取消结果。
- Rust 46 项通过（1 项既有长篇测量忽略），严格 Clippy 通过，日志 `build/final-query-rust2.log`、`build/final-query-clippy.log`。新增覆盖纠错改名/新增/排除/恢复后的直接搜索和章导航，以及搜索进行中目录变化的固定快照。
- 现有 57 项原生与 22 项用户数据回归分次验证。旧文件操作测试依赖先刷新共享投影，已改为直接业务查询并通过；最新 23 项定向结果通过于 `build/final-business-native7.log`。同一封面视图先文字、后图片的真实本地 SwiftData 提交通知测试及取消旧加载通过于 `build/final-business-cover6.log`；画面已检查，见 `build/Final-Cover-Shots/`。本地保存通知不是真实云附件交付验收。
- 四项取消/冲突 UI 分次通过：`build/final-business-ui2.log` 中已有批注 X/下拉取消、新建取消及正式冲突取消三项通过；跨页新建取消最终通过于 `build/final-business-cross3.log` / `build/Final-CrossPage-Cancellation.xcresult`。UI2 的跨页测试曾在原生菜单已展开时额外点击不存在的“下一页”，移除测试的额外点击后定向通过，未改变产品菜单实现。UI2 进程未正常收尾且已停止，日志中的三项通过不代表整个执行成功；截图可读取结果以跨页取消与封面包为准。测试准备也已支持分页扉页先于正文出现，并显式选择普通批注用例的阅读模式，避免依赖上个用例状态。
- 同 ID 更换哈希时的取消旧加载竞态定向通过于 `build/final-business-cover8.log` / `build/Final-Cover-Race.xcresult`。最新普通启动成功，书架画面见 `build/final-business-startup.png`。
- 当前环境仅 iOS 27 模拟器；真实云签名、iOS 18 运行、云附件分批/迟到事件与两设备端到端仍未验收。未安装手机，未修改外部或 iCloud 小说原件。


## 统计标题数据来源

2026-10-01，移除计时器和 ReadingSlice 的冗余标题参数；统计标题继续在保存时由书籍数据库取得。Rust 统计/小说详情集成及计时器单元测试共 11 项通过，新增回归覆盖暂停恢复、清理后新会话的书目和活动标题。iOS 27 模拟器构建及统计暂停、清理、重启持久化 UI 用例通过。证据：`build/statistics-title-core.log`、`build/statistics-title-ios.log`。此次不修改数据库 schema。

## 云书架中断恢复

2026-10-01，iOS 27 模拟器的 4 项定向回归通过：云书架激活后仅删除部分本地原件的重启恢复、交接失败按收据重试、同名替换/原件变化保护、暂停来源先重绑后清理。新增用例同时验证账户不匹配、未登录及尚未激活云书架时不恢复旧云根。证据：`build/cloud-root-recovery.log`。使用本地目录模拟交接及持久化书签，不代表真实 iCloud 容器暂时不可用的真机验收。

## 仓库自动检查

同步接入后的 Rust 工作区回归为 60 项通过、1 项已有长篇测量忽略；其中 9 项同步测试覆盖字段合并、设备偏好排除、SHA 延迟关联、渐进准备期间记位置/书签、上传中再次编辑、并发批注与删除、章节纠错/恢复、回读进度及无效云记录回滚。全 target/feature 的 Clippy（禁止警告）通过。证据：`build/icloud-core-final.log`、`build/icloud-clippy-final2.log`。

生命周期定向修复：Rust 渐进导入 10 项回归及 Clippy（禁止警告）通过；iOS 27 的 5 项原生回归通过，覆盖初始化失败重试／并发等待、导出暂存持有与中途失败清理、连续开书六次后的任务／授权回收、文件移动删除后的阅读数据保留及退出进度保护。1 项 UI 回归通过首次封面、退出、重新打开及正文续读。证据：`build/pr-lifetimes-rust.log`、`build/pr-lifetimes-clippy.log`、`build/PRLifetimes4.xcresult`、`build/PRLifetimesReader.xcresult`。真实分享宿主、文件提供方导出及进程被系统终止的端到端行为未在本轮实机验证；跨存储中断残余由定向回归模拟覆盖。

早期 CI 同款命令在本机验证：Rust 工作区 49 项通过、1 项长篇测量按原标记忽略；全 target/feature 的 Clippy（禁止警告）、Rust/Nix 格式、actionlint 和开发文档本地链接检查通过。iOS 27 模拟器无签名构建通过，首次书架/开书与原页面搜索取消两条 UI 用例通过。退出进度保护的旧测试补上“从封面进入正文”的准备步骤后，36 项原生单元测试全部通过，保留原有进度冻结与迟到回调断言；未改变产品代码。证据：`build/ci-rust-tests.log`、`build/ci-clippy.log`、`build/ci-local-ios.log` 的两条 UI 通过项、`build/CI-Local-Unit-Final.xcresult`。

当前 Linux CI 配置见[仓库与持续集成](repository.md)；本节 iOS 结果为本地验证，GitHub 是否通过以对应运行记录为准。

## 阅读统计

本地统计版本：Rust 核心 66 项通过，1 项已有长篇测量按原标记忽略；Clippy 禁止警告通过。新增计时/存储回归覆盖 120 秒闲置、暂停与查阅切换、午夜和墙上时间改变、重复保存、清理代次、禁用记录、正文 SHA 完成与任务回收；写统计不改变续读和书签。证据：`build/statistics-core-all.log`、`build/statistics-clippy.log`。

iOS 27 模拟器 4 条 UI 路径通过：统计页到单书图表/月历、深色英文、实际正文阅读后退出并重启持久化、关闭记录与清除后的重启保留；另有 2 条原生回归覆盖时段合并保持暂停/查阅边界，以及阅读发生地的公历日期。实际检查浅色中文、深色英文、圆环/时段与月历截图，修正日历坐标和图表颜色。证据：`build/StatisticsReleaseCheck.xcresult`、`build/StatisticsControlsFinal.xcresult`、`build/StatisticsControls.xcresult` 中两条原生通过项、`build/statistics-release-screens/`。

图表合成数据只在隔离 UI 测试库中创建；正式使用从真实阅读开始记录，不补造旧时长。尚未覆盖真机锁屏/控制中心长时试用、全部辅助字号/VoiceOver、跨时区旅行和长篇性能；统计自动同步已接入但真实云端待验收，回看分析尚未实现，不能将本地回归当作这些能力的验收。章节覆盖的当前证据见下节。

## 小说信息与章节覆盖

schema 11 的 Rust 核心全套 74 项通过、1 项已有长篇测量忽略，Clippy 全 target 禁止警告通过。新增回归覆盖完整正文 SHA 编辑门槛、字段与标签成员合并、封面引用及移除、3 秒连续可见门槛、慢滚重叠延续、不同访问不累加短停留、跨检查点覆盖、字符计数和清理后重算。证据：`build/book-details-core.log`、`build/book-details-clippy.log`。

iOS 27 模拟器的图片原生测试通过：降采样至最长边 1600px、草稿取消/保存和内容哈希校验。六条受影响 UI 路径通过：小说信息编辑及阅读返回、未读书准备后编辑与作者/标签/文件名组合筛选、封面详情与正文续读、统计到单书图表、章节列表以及工具面板关闭。检查了详情、封面摘要、筛选结果和章节百分比截图。证据：`build/book-details-cover-validation.log` 中 `testCoverDownsamplingSaveCancelAndHashValidation` 通过项、`build/book-details-statistics-ui.log` 中 `testStatisticsChartsAndBookNavigation` 通过项，以及 `build/book-details-return.log`、`build/book-details-regression.log`、`build/book-details-final-ui.log`、`build/book-details-filter-verified.log`。前两份日志还包含开发期间失败项，仅将以上明确通过用例作为证据。

模拟器和真机包构建通过。照片/文件选择器的真实取图过程、SwiftData 附件云端传输和双设备合并尚未完成端到端验收；本地图片与合并测试不代表真实云端通过。回看次数、正文地图尚未实现；统计自动同步已接入但云端待验收。

## 选字、卷集与详情配色

卷集识别的定向 Rust 回归与全 target Clippy 通过，覆盖“卷”接“集”、子章节归属和新一集内章号重启。证据：`build/chapter-series.log`、`build/chapter-series-clippy.log`。旧书的已生成目录需要使用现有“重新识别目录”刷新；iPhone 13 已对用户指定测试书应用新目录，并确认集标题成为可折叠上级、章节缩进显示，原文未改动。

首屏原生选字反向滚动已用真实拖杆复现：整屏封面放进 `contentInset` 或 `textContainerInset` 都会干扰 UIKit 自动滚动；后一种布局在拖向下沿时仍从正文滚回 `y=0`。相同手势在无封面视图中正常，证据：`build/reader-selection-edge-diagnostic.log`。当前用 `NSTextAttachment` 占显示文档空间，正文保留普通边距，附件前缀经原文坐标映射排除；复制与全选只包含原文。正文窗口更新在原生选区存在时暂缓，避免后台追加触发选区自动显露。

选字菜单按常用、系统工具、批注和高级操作排列，保留系统箭头展开。lookup 原生分组完整保留后，实际纵向菜单已恢复“搜索网页”；其动作在系统展示阶段补充，不能将分组拆成最初的子项快照。不以菜单显示代替翻译或网页搜索服务的网络验收。详情首卡浅色主题的背景像素与其他卡片一致，信息编辑与阅读返回通过，证据为 `build/reader-selection-regression.log` 中 `testBookInformationEditingAndReaderReturn` 通过项。

选字 UI 回归通过：批注保存、点击实际高亮重开/删除/撤销，以及先向下扩展终点、再向下移动起点选择杆。拖动前后比较同一章节标题的图像，实测有 5pt 的小幅位移，未再跳回封面或大片前文；断言允许 8pt，不能解释为像素级完全静止。证据：`build/reader-selection-complete.log`。真机镜像随后因手机使用而退出，触屏拖杆手感仍由用户试用确认。

回归截图保存在 `build/reader-selection-shots/`、`build/reader-selection-final-shots/`。上述中间日志含已单独定位的其他失败项，只引用明确通过的用例，不将整包标为通过。

菜单和详情入口调整后，两条受影响 UI 回归通过：系统箭头直接展开到批注操作并完成保存/重开/删除/撤销；右上角详情按钮与返回按钮同高，进入详情再返回保持原位置。实际截图确认展开菜单没有额外“更多”层，底部进度行没有详情按钮。证据：`build/reader-menu-details.log`、`build/reader-menu-details-shots/`。真机包构建、iPhone 13 覆盖安装与启动成功，证据：`build/reader-menu-details-device.log`、`build/reader-menu-details-install.json`、`build/reader-menu-details-launch-retry.json`；首次启动命令超时，重试成功。

顶部改为系统导航栏后，6 条 UI 与 2 条原生回归通过：滚动/分页工具显隐不移动正文、详情编辑与返回、封面续读、批注保存/重开/删除/撤销、拖杆到下沿不反向回到封面、向下移动起点、附件与 UTF-8 坐标/复制边界。已检查原生导航、菜单“搜索网页”和选区扩展截图。证据：`build/reader-native-controls-regression.log`、`build/reader-native-controls-shots/`。顶部独立 0.18 秒动画已删除；原生导航和 sheet 共用工具显隐状态，各自遵循系统转场，尚未做逐帧同步时间测量。

最终补充回归通过：选区未取消时收到新正文窗口不编辑原生文本，取消后更新仍保留当前行；封面与正文交界处窗口更新不移动原句；原生返回可取消，临时浏览原点不丢失。证据：`build/reader-native-controls-final.log`。

最终真机包构建、iPhone 13 覆盖安装与启动成功，证据：`build/reader-native-controls-device-final.log`、`build/reader-native-controls-install-final.json`、`build/reader-native-controls-launch-connected.json`。首次启动被锁屏状态拒绝，镜像连接后重试成功；打开阅读页，核对点击显隐的原生导航栏、底部工具和展开菜单中的“搜索网页”。菜单通过镜像指针操作检查，不以此代替真机触屏拖杆的速度/手感验收，后者仍待试用。

## 批注统一菜单与编辑合并

以下是重构前 schema 13 的历史回归，已被当前 SwiftData 验证取代：批注和同步定向 Rust 回归共 22 项通过，严格 Clippy 通过。覆盖按正文位置拼接评论、空评论、不完全交叉、确认前原范围与评论不变、确认后保存为一条、拒绝陈旧编辑、整组移除与撤销，以及合并范围/删除状态同步。证据：`build/unified-annotations-core.log`、`build/unified-annotations-clippy.log`。

iOS 27 模拟器最终 3 项原生和 1 条 UI 检查通过：点按在滚动/分页中保留完整原生选区并隐藏选择杆，不改变视口；任意交叉均提供编辑和危险色移除；跨两条批注打开同一编辑器，按正文顺序展示评论并合并保存；短批注点按菜单保留查询、翻译、搜索网页，移除后能整组撤销。证据：`build/unified-annotations-release-check.log`。

整段批注重开与全文搜索用例通过；原生菜单呈现时选区保持完整 59 字，未缩回首词。编辑器左侧关闭/右侧确认、正式保存、删除/撤销及重启保留正式评论已有回归；当前取消语义见本轮验证。整段选区证据为 `build/unified-annotations-exact-range.log`；编辑器流程见 `build/unified-annotations-final.log` 中 `testReadingToolsPreviewBookmarkSearchAndNote` 的通过记录。

实际菜单截图见 `build/unified-annotations-final-shots/`、`build/unified-annotations-paragraph-shots/`：编辑与红色移除在前，点按无选择杆，展开后保留系统查询、翻译、搜索网页，无自定义“更多”。点按与长按共用同一个菜单生成函数，原生 Select 命令执行期间才指定批注范围，不改变用户拖杆时的系统行为。

最终真机包构建、签名验证及 iPhone 13 重装成功。由于开发数据库格式变化，按约定重置本机 App 测试数据，未操作外部目录/iCloud 小说原件。启动被设备锁屏拒绝，真机启动及触屏体验尚未确认。证据：`build/unified-annotations-device-final.log`、`build/unified-annotations-uninstall.json`、`build/unified-annotations-install.json`、`build/unified-annotations-launch.json`。本地同步回归不代表真实云容器及跨设备验收。

## 书架、来源与文件管理

搜索结果与撤销布局：全书架/单书架搜索、搜索结果返回及所在目录跳转回归通过；实际截图确认结果为固定双行，封面与文字块居中，分隔线与文字起点一致，路径图标采用紧凑间距，只含书籍时不重复显示分类标题。删除/撤销在临时浏览与仅剩撤销提示两种状态均通过；共享收起内容撑满宽度，提示与撤销左右分布，不嵌套小药丸。证据：`build/search-row-and-undo-layout.log`、`build/standalone-undo-layout.log` 及对应 `*-shots/`。真机包构建、覆盖安装和启动成功，未重置已有 App 数据：`build/search-row-and-undo-device.log`、`build/search-row-and-undo-install.json`、`build/search-row-and-undo-launch.json`。

目录扫描路径：真机启动检查发现内置书架为空、全部小说却有条目，开书报文件不存在。原实现按未归一化的根路径长度截取枚举结果，在 `/var` 与 `/private/var` 指向同一位置时生成了错误相对路径。独立父路径别名用例复现空根目录和错误子路径；统一解析根目录、文件及云端元数据的路径后，该回归、首次预置/删除不补回、改名/移动/删除保留阅读记录共 3 项原生测试通过。证据：`build/LibraryPathDiagnostic2.xcresult`、`build/LibraryPathFixed.xcresult`。

Tab 下方空白带：iOS 27 原生视口诊断确认，书架的 `UICollectionView` 原先在 Tab 上沿截断（视口底部 791pt，窗口底部 874pt）。扩展容器底部安全区后，视口达到窗口底边，UIKit 自动保留 83pt 的滚动 inset。书架/设置导航 UI 回归通过，新增实际目录视口到底边的断言；iPhone 13 实际检查列表和网格，内容均经过浮动 Tab 后方，没有原来的整行截断。其他全部小说与设置页面使用 SwiftUI 原生滚动容器，未发现同样的视口裁切。证据：`build/LibraryViewportDiagnostic.xcresult`、`build/LibraryViewportExtended.xcresult`、`build/ReaderAndFolderDiagnostic.xcresult`。

文件选择交接与加载时机：5 项原生回归和 2 项 UI 回归通过。覆盖选择器先清空展示状态再交付 URL、进入目录后扫描继续运行、取消不重放旧选择、TXT 结果直接启动导入及失败重试、失败项授权清理、下载取消与迟到回调保护；UI 覆盖目录/全部小说/搜索加载与取消、封面内真实比例及稳定布局。证据：`build/LibraryLoadingHandoff.xcresult`、`build/library-loading-handoff.log`。真机覆盖安装成功，保留原有书架与数据；通过 iPhone 镜像从书架管理选择已授权的 iCloud Drive 目录后，直接进入包含 389 本小说的目录，不再需要再次打开/取消选择器来启动任务；随后重新打开并取消，保持在管理页，无旧动作跳转。该目录已有缓存，首次无缓存的等待由暂停扫描的原生回归和慢查询 UI 回归验证，未将它表述为真机冷扫描耗时测量。

iCloud 本地接入：iOS 27 无签名构建通过，3 项原生回归通过，覆盖复制中断保留原件/恢复收据、同名明确替换与复制时源变动保护、两阶段交接及暂停正文任务来源重绑；测试使用真实临时文件和替代 ubiquity 搬运函数，**不等于 iCloud 上传成功**。证据：`build/CloudHandoffFinal.xcresult`；交接后目标被删除不自动恢复的补充断言在 `build/CloudHandoffDeletion.xcresult` 通过。工程 entitlements、Info.plist 和项目文件语法检查通过；该轮使用 Personal Team 本地包；当前云签名及安装见上方真机交付，真实两设备同步、离线恢复和账户切换仍未验收，条件见[接入实施](../data/icloud-implementation.md)。

| 范围 | 已取得的证据 | 本地结果 |
| --- | --- | --- |
| 导入结果关闭与重试 | iOS 27 的 4 项定向回归通过：真实 SwiftUI 结果页绑定关闭触发清理；失败重试及恢复文件后的成功重试保留其他失败项；迟到关闭回调不清理新结果页；同名导入仍保留原件直到确认替换。使用临时目录验证关闭与队列状态，未测真实文件提供方的系统授权配额或手机下拉手势 | `build/ImportResultDismissal.xcresult`、`build/import-result-dismissal.log` |
| 原生多选容器与工具栏 | iOS 27 原生选区绑定与几何回归通过：入口不参与选择、UIKit/SwiftUI 选区同步、长短书名单行等高、原生 multiselect 配件、切换布局及忙碌状态。真实 UI 手势验证沿原生选择列单指拖动选中连续两项，再拖动取消；网格批量复制、连续重名提示与重试通过。列表固定行高、整行浅底及网格仅封面高亮的截图已检查。列表／网格既有回归覆盖全选删除、返回保护、菜单禁用与工具栏布局；网格滚动高度基线见原记录。双指滑动及边缘自动滚动的实机手感仍由用户试用确认 | 最终原生配件、固定行高与选择列拖选：`build/NativeSelectionGesture.xcresult`、`build/native-selection-gesture-attachments/`；网格复制通过项：`build/NativeSelectionFixed.xcresult`（该包还包含随后修正落点的拖选测试失败，不计整包通过）；既有滚动与导航：`build/library-selection-complete.log`、`build/LibrarySelectionBatchFinal.xcresult` |
| Rust 索引与正文身份 | 7 项书架定向回归通过，覆盖元数据作用域、自然排序、失败扫描保留清单、文件移动/删除后的 SHA 记录归属、正式最近阅读、递归封面与阅读排序；Rust 格式检查通过。既有 Clippy 证据保留 | `build/prepublish-bookshelf-core.log`、`build/prepublish-format.log`、`build/bookshelf-catalogue-clippy.log` |
| 原生文件操作 | 两项原生测试通过：真实临时目录中复制导入、同名替换保护、改名/移动/删除及书签/进度保持。不会操作用户小说 | `build/BookshelfNativeFinal.xcresult`、`build/bookshelf-native-final.log` |
| 目录持久化 | 新建、改名目录在重启后保持；嵌套浏览与阅读返回通过。页面内搜索和返回手势的当前证据另列 | `build/BookshelfUITests3.xcresult`、`build/bookshelf-navigation.log` |
| 书架多选与批量复制 | iOS 27 列表/网格回归通过：全选仅作用当前层、取消全选和已选计数同步、删除后移除失效选区；外部 TXT 批量复制保留来源文件、不递归复制文件夹，成功取消勾选、跳过项保留并可重试替换，不自动开书。连续两个同名文件的最终回归通过：跳过第一本、替换第二本，再重试第一本；原生警告框的关闭状态不再抢先推进队列。实际全选/部分选择/完成截图已检查，工具栏位置与禁用状态正常。原生文件同名替换测试确认选择前保留旧目标及输入原件。云端批量获取及 iOS 18 未在本轮运行验收 | 列表/网格 `build/BookshelfBatchSelectionFinal.xcresult`、`build/bookshelf-batch-final-attachments/`；最终连续冲突 `build/BookshelfBatchExplicitChoices.xcresult`、`build/bookshelf-batch-choices-attachments/`；原生文件保护通过项见 `build/BookshelfBatchSelection.xcresult` 中 `testLibraryImportConflictPreservesOriginalUntilReplacement` |
| 精简首页与首次使用 | 紧凑标题、单一添加菜单、普通文件入口和首次阅读返回更新最近记录的 UI 回归通过；首次预置不算已读、删除后重新初始化不补回的原生测试通过。搜索与英文深色两项通过，实际首页截图已检查 | 最终首页及阅读返回两项见 `build/HomeRefinementFinal.xcresult`、`build/home-refinement-final.log`、`build/home-refinement-final-attachments/`；首次预置原生测试、搜索与英文深色的通过项见 `build/home-refinement-tests.log` |
| 列表／网格 | 默认列表、网格跨目录与重启记忆、搜索取消后恢复网格、网格多选仅删除选中项通过，实际布局已看图 | `build/UIKitNativeSearchAppearance.xcresult` 中 `testBookshelfGridPersistsAcrossFoldersAndRelaunch`；截图 `build/uikit-native-search-appearance-attachments/` |
| 网格滚动条稳定性 | iOS 27 两项 UI 回归通过。用原复现场景的 25 个根级文件夹、122 本根目录小说及 1 本嵌套小说，普通目录连续 12 次下滑／12 次回滑，总高度始终为 13,674pt；全部小说 8 次下滑／8 次回滑，始终为 11,304⅓pt。此前同场景曾从 3,814pt 跳到 13,674pt。录屏检查滚动条稳定，文件夹网格、字母索引、列表切换和阅读返回同时通过；书目网格仍使用 LazyVGrid，只替换外层排版容器 | `build/LibraryGridHeightFixed.xcresult`、`build/library-grid-height-fixed.log`、`build/library-grid-height-fixed.mov`、`build/library-grid-height-fixed-frames.png`；修复前测量 `build/library-grid-height-diagnostic.log` |
| 阅读排序、文件夹封面与完整书目 | Rust 书架 7 项回归及 Clippy 通过，包含阅读/修改时间、递归作用域、最多四本预览、特殊目录名边界、移动后预览更新及纯元数据查询。原生拼音/自然数字分组测试、3 项 UI 回归通过：文件夹组合封面、书架内全部小说、网格字母跳转、原生列表索引、阅读返回；搜索范围、跨目录/重启布局、多选删除保留原行为。收紧字母分组间距后对应页面再次通过，最终截图已检查 | `build/bookshelf-catalogue-core.log`、`build/bookshelf-catalogue-clippy.log`、`build/BookshelfCatalogue.xcresult`；最终页面见 `build/BookshelfCatalogueFinal.xcresult`、`build/bookshelf-catalogue-final-attachments/` |
| 两阶段开书与等待反馈 | 6 项原生测试通过：进度单位/异常值、旧请求不能清除新等待、文件就绪才导航、取消后不恢复进度、文件访问不产生阅读记录、原文件操作保留阅读数据等。局部样式改为原生后，下载 25%→75% 进度条、百分比、取消再打开及文件就绪后开书的 UI 回归通过，截图已检查。比例来自可控测试输入，不代表真实 iCloud 下载回调已验收 | 核心边界 `build/LibraryLoadingFinal.xcresult`；原生进度样式 `build/NativeInlineLoading.xcresult`、`build/native-inline-loading-attachments/` |
| 整页与局部加载分层 | 3 项定向 UI 回归通过：首页慢扫描时仅有导航栏系统转圈，已有书目可进入；目录/全部小说/文件名搜索无内容时保留大月亮，完成与取消清理；阅读搜索药丸/详情收展、结果与临时浏览恢复正常。实际截图确认首页提示不覆盖“查看全部”、药丸布局完整 | `build/NativeLoadingToolbar.xcresult`、`build/native-loading-toolbar.log`、`build/native-loading-toolbar-attachments/` |
| 封面下载 | 列表／网格两项 UI 回归通过：封面内显示 25%→75% 原生进度，取消后可重新下载并进入阅读。几何断言确认进度位于封面范围，书目及更多按钮尺寸、位置不变，菜单保持可用，下载截图已检查。移除进度背后的封面文字残影后，网格下载最终用例再次通过。下载比例来自受控输入，真实提供方回调边界不变 | `build/LibraryCoverDownloadVerified.xcresult` 中两项下载用例、`build/library-cover-download-verified.log`、`build/library-cover-download-attachments/`；最终样式 `build/LibraryCoverDownloadFinal.xcresult`、`build/library-cover-download-final-attachments/` |
| 当前页面原生搜索 | 使用 `UISearchController` 接入现有导航项，iOS 27 原生放大镜与展开输入框截图已检查。五项定向 UI 用例通过：首页取消还原、全局/书架搜索及嵌套目录、进入阅读后返回保留查询且不弹键盘、网格取消及跨目录/重启、英文深色清空/取消、浅深主题标题与原目录视口保持。测试清空时限定搜索结果范围，避免误查仍保留的最近阅读列表。未新建搜索路由或自绘搜索控件；iOS 18 默认搜索布局尚未运行验收 | `build/UIKitNativeSearch.xcresult`；网格通过项见 `build/UIKitNativeSearchAppearance.xcresult`；原生标题通过项见 `build/UIKitNativeSearchVerified.xcresult`；英文最终通过见 `build/UIKitNativeSearchEnglishFinal.xcresult`；截图见 `build/uikit-native-search-attachments/`、`build/uikit-native-search-appearance-attachments/`、`build/uikit-native-search-verified-attachments/` |
| 后台扫描与缓存可用性 | 六秒模拟扫描期间，缓存书目正常可读；离开首页不会中止初始化或弹出取消错误；合并初始化/前台重复请求后，扫描结束移除提示。搜索与阅读返回回归通过。慢扫描用例没有操作真实云端文件 | `build/LibraryLoadingScanVerified.xcresult`、`build/library-loading-scan-verified.log`；搜索与返回通过项见 `build/library-loading-navigation.log` |
| 整页月亮与启动交接 | 等待页 96pt 月亮在完成/取消后原地淡出；App 首帧 144pt 月亮与底色一起淡出。相关 UI 流程、后台返回保留设置页、冷启动恢复减弱动态偏好通过，录屏已检查。系统静态启动图到 App 首帧的完整衔接仍受模拟器快照限制，未实测确认 | `build/MoonFadeOnly.xcresult`、`build/moon-fade-only.mov`、`build/moon-fade-only-frames.png`；限制 `build/launch-snapshot.log` |
| 阅读顶部恢复与原生返回手势 | 恢复普通返回图标、居中书名和原有纸色渐变，删除圆形／胶囊玻璃；这是阅读覆盖层，不是系统导航栏。iOS 27 定向 UI 回归通过：与普通设置页相同的斜向手势可返回，竖向滑动仍滚动正文；返回实际来源、取消返回后恢复临时浏览、弹层/选字/分页保护通过。正文页显示工具前后视口与锚点不变，实际顶部截图已检查。真机手感待用户试用 | 斜向手势通过项见 `build/NativeSearchActivation.xcresult` 中 `testReaderAcceptsSameDiagonalBackGestureAsSettings`；保护、返回与截图见 `build/NativeReaderSafeguardsVerified.xcresult`、`build/native-reader-safeguards-attachments/` |

当前用例使用独立目录和原创合成 TXT。模拟器通过不代表第三方文件提供方、跨提供方移动、实际分享宿主和手机交互已验收。iOS 18 原生表现及更大辅助字号仍不作为本轮已验收范围。应用自建 iCloud 容器与 CloudKit 已接入，真实云端验收受签名环境限制，见上文。

## 阅读核心与正文

连续滚动诊断：通过 iPhone 镜像，从用户指定测试书第 60 章正常续读至第 64 章，并回滑第 62～63 章；未稳定观察到整段跳回。该书 7 处分片、每处 4 个位置的原生排版检查均保持原行，等待下一次主循环后也没有延迟位移，诊断用的原文路径未保留在源码。镜像事件主要是拖动，不能替代触屏惯性验证。

iOS 27 原生快速触摸滑动另外复现了补片中断：`appendScrollContents` 对未变化的 offset 调用 `setContentOffset(_:animated: false)`，一次补片前 `isDragging/isDecelerating` 均为 true，结束时均为 false。移除这次主动定位后，相同触摸路径的两个状态在补片前后保持 true；裁片仍在交互结束后恢复可见行。证据：`build/reader-momentum-boundary-events.log` 与 `build/reader-momentum-preserved-events.log`，原行与延迟排版回归见 `build/ReaderMomentumPreserved.xcresult`。此证据确认了补片截断滚动，不将用户反馈的所有跳动都归因为同一问题；手机快速甩动的最终手感仍待继续试读。

移除临时诊断后的最终设备构建通过，签名验证后覆盖安装成功，保留原有数据（`build/reader-motion-final-device.log`、`build/reader-motion-final-install.json`）。最后启动请求被系统以 `Locked` 拒绝，镜像同时显示 iPhone 使用中，因此最终安装后的重新开书检查未完成；不能将此前诊断版的真机检查写成最终包已复测。

封面页定向验证：Rust 原有核心回归 47 项通过、1 项测量忽略，新增正文位置 0／未开始阅读／快开继承状态用例通过（书架专题共 6 项）。iOS 27 的 4 项原生回归覆盖封面不写正文/不改变 SHA、退出与续读、改字号、跨窗口、搜索上下文定位和返回视口；2 项 UI 回归覆盖滚动首次封面、只看封面退出、正文续读、目录回看、分页前后翻。实际封面、临时浏览和续读截图已检查。证据：`build/reader-cover-core.log`、`build/reader-cover-identity.log`、`build/ReaderCoverVerified.xcresult`、`build/reader-cover-verified.log`、`build/reader-cover-attachments/`。真实云端等待期间的显示、VoiceOver 实机朗读与 iOS 18 外观未在本轮手动验收。

| 范围 | 已取得的证据 | 本地结果 |
| --- | --- | --- |
| Rust 数据与阅读规则 | 42 项测试、格式与 Clippy 通过，覆盖全局设置校验/重启、Unicode 段落、卷章查询、纠错与重建、百分比边界、有界跳转历史 | `build/reader-foundation-core.log`、`build/reader-foundation-clippy.log` |
| 原生排版与稳定位置 | 21 项 TextLayoutTests 通过：三种字体、横竖尺寸、标题/长段页内覆盖、续段缩进、窗口前插/追加、仅重绘、原位恢复与设备控制释放。双模式重排、后台/重开、选区与手势保护另有 UI 回归 | `build/reader-foundation-integration.log` 中 TextLayoutTests；UI 对应通过项见 `build/reader-foundation-regression.log` |
| 渐进导入与恢复 | EOF 前可读并能保存；暂停/继续、后段编码错误、源变更、去重后的 SHA 归属、存储失败已有核心回归。iOS 27 模拟器验证大合成 TXT 完成前可读、双模式及重排 | `build/progressive-core-tests.log`、`build/Progressive-ui.xcresult`；后续导入 UI 复测见 `build/chapter-loading-final-tests.log` |
| 正文绘制边界 | 复制不包含分页后文，高亮不编辑 NSTextStorage；底部渐变下有正文、书尾解除渐隐、工具和窗口变化保持位置 | `build/Reading-final-highlight.xcresult` 原生用例；`build/Note-paint-regression.xcresult` 中 TextLayoutTests；`build/Reader-bottom-fade.xcresult` |

## 阅读工具、弹层与导航

阅读面板时序：工具 180ms、搜索连续展开 240ms、快捷区域高度 200ms；新内容立即淡入 120ms，取消原来的 80ms 等待。5 项 UI 用例的受影响断言通过：章节临时浏览展开保持按钮/视口、快捷设置保持底部入口位置、普通/减弱动态下快速反向切换、两种动态偏好下的搜索首次聚焦和药丸恢复。`build/CloudMotion.xcresult` 包含其中 4 项通过及一项旧测试导航路径失败，不能计作整包通过；修正为先从目录返回首页后，反向切换复测在 `build/CloudMotionFinal.xcresult` 通过。实际面板截图已检查：`build/cloud-motion-final-attachments/`。参考应用仅查固定版本源码，未运行或测量其设备动画；手机手感仍由用户试用。

| 范围 | 已取得的证据 | 本地结果 |
| --- | --- | --- |
| 完整目录与纠错 | Rust 核心 68 项通过、1 项已有长篇测量忽略，Clippy 禁止警告通过；覆盖一万章完整快照、预计算字数、渐进导入暂停/恢复、SHA 去重、人工修正/重建及同步修正。iOS 27 的 1 项原生回归与 2 项 UI 回归通过：完整快照内搜索/折叠、当前章定位、前面章节连续浏览、空框聚焦与清除搜索、纠错重建保留人工标题；实际截图已检查 | `build/chapter-outline-core-full.log`、`build/chapter-outline-clippy.log`、`build/ChapterOutline.xcresult`、`build/chapter-outline-screens/` |
| 搜索与首次展开 | 最终三项 UI 回归通过：普通/减弱动效下空搜索自动聚焦、已有结果恢复不弹键盘、收起后键盘消失；正则/大小写、前后命中、上拉/下拉、原点保护及确认续读后重启恢复。抽帧确认连续展开到位后弹键盘，手势展开不回弹到小档 | `build/search-opening-verified.log`；录屏 `build/search-opening-verified.mov`，截帧 `build/search-opening-focus-frames.png`、`build/search-opening-reduced-frames.png`；英文既有流程见 `build/Search-panel-interaction.xcresult` |
| 共用面板与四列工具 | 进度/前后章直接显示，快捷设置切换保持四列位置、唯一实例与正文视口；连续反向切换通过。目录/历史/批注在同一 sheet 内切换，关闭后回到沉浸正文，仅恢复必要药丸；设置/目录返回保留搜索会话 | `build/unified-reader-handoff.log`、`build/reader-accessory-motion-final.log`、`build/reader-task-sheet-final.log`；对应同名录屏及截帧留在 build |
| 跳转、返回与浮层清理 | 章节顶部、搜索上下文、同屏仅高亮、原视口精确返回；百分比/历史与分页边缘返回通过。设置预览和搜索/临时浏览药丸取消返回后恢复，确认退出不残留且保护正式进度；回调两种到达顺序有原生测试 | `build/navigation-final-tests.log`、`build/reader-foundation-final.log` 对应三项 UI；`build/navigation-presentation-final.log`，原生三项见 `build/navigation-presentation-cancel.log` 对应通过项 |
| 书签与批注 | 书签位于正文右侧，增删不改字形/视口；成功后收起工具。批注自动聚焦、点外部收键盘、带键盘下拉、删除与撤销通过；撤销倒计时在被设置遮挡时暂停 | `build/bookmark-right-tests.log`、`build/bookmark-autoclose-tests.log`、`build/Note-form-final.xcresult`；最近批注流程见 `build/reader-task-sheet-note-undo.log` 的通过项，撤销最终见 `build/reader-task-sheet-undo-verified.log` |

## 主题、设置与品牌组件

2026-09-30：空目录“导入小说”接入 `accent/onAccent` 配对，保留原生按钮样式。iOS 27 模拟器专项 UI 回归通过，浅深杏桃主题均从实际截图采样验证按钮内部对比度至少 4.5:1，并确认可点击；两张画面已检查。证据：`build/ButtonThemeFix.xcresult`、`build/button-theme-attachments/`。其他预设、自定义及系统配色未做本轮完整视觉验收。

| 范围 | 已取得的证据 | 本地结果 |
| --- | --- | --- |
| 紧凑书架管理 | iOS 27 原生导航 UI 回归通过：标准居中标题、右上角添加打开系统文件夹选择器、取消后回到管理页、进入书架和逐层返回，Tab 规则保持。浅深主题实际截图确认双行条目紧凑、图标与文字列统一、分隔线对齐名称，底部无重复添加行。大辅助字号与 iOS 18 未做本轮设备验收 | `build/CompactShelfManagement.xcresult`、`build/compact-shelf-management.log`、`build/compact-shelf-management-attachments/` |
| 书架左滑移除 | iOS 27 专项 UI 回归通过：内置书架菜单无移除、外部书架左滑出现带文字和图标的主题删除色按钮；点击后先确认，点外部取消仍保留条目，重新确认后管理页和首页同步移除入口。按钮、确认浮窗及移除后的实际截图已检查。复用既有仅移除入口的服务，未增加原文件删除调用。此次较宽的导航回归在系统文件夹选择器未呈现处中止，不将该中间测试包记为通过 | `build/ShelfSwipeRemovalFinal.xcresult`、`build/shelf-swipe-removal-final.log`、`build/shelf-swipe-removal-final-attachments/`；选择器中止记录 `build/shelf-swipe-removal.log` |
| 普通页面持续显示 Tab | iOS 27 四项 UI 回归通过：目录、全部小说、应用主题、配色、关于、书架管理持续显示 Tab；两个 Tab 各自保留导航位置；逐层返回、普通页面侧滑取消、全局/目录搜索与阅读返回实际来源正常。多选临时隐藏，完成后恢复；正文及阅读预览保持隐藏，预览半屏/窄栏取消返回恢复原档位和位置。实际截图与录屏抽帧已检查，普通导航返回期间 Tab 连续可见。iCloud 设置复用普通页面规则，本轮未单独运行云端页面；iOS 18 未复测 | `build/PersistentTabs.xcresult`、`build/persistent-tabs.log`、`build/persistent-tabs-attachments/`、`build/persistent-tabs.mp4`、`build/persistent-tabs-return.jpg` |
| 统一阅读设置与预览 | 快捷项即时作用于正文；两个入口共用排版/配色/阅读控制分类并记忆选择；窄栏、三档预览、横屏、原生返回和自定义配色已有相应用例，未在每次小修中全量重跑 | `build/unified-reader-final.log` 中设置与窄栏返回两项；`build/reading-theme-navigation-final.log`、`build/reading-preview-native-palette-service.log` |
| 配色、持久化与输入 | App/阅读独立浅深、自定义配色、槽位重启、搜索冷色/批注暖色与当前命中底色已看图；主题变化不重排正文。连续保存串行合并、旧响应不覆盖新值，错误恢复有受控测试；字号/行距改变时模式文字不闪 | `build/theme-final-tests.log`、`build/theme-live-tests.log`、`build/theme-color-final-tests.log`、`build/settings-flicker-tests.log`；框外收键盘见 `build/input-focus-final-tests.log` |
| 月亮与状态反馈 | 月相亮面对应 0/10/25/50/75/100% 的几何用例仍保留，仅用于整页月亮组件；局部导入、下载、搜索详情/药丸改用原生进度，保留 800ms 展示门槛、结束后移除。普通操作使用标准语义图标 | 月相几何 `build/chapter-loading-final-tests.log`；当前局部样式 `build/NativeInlineLoading.xcresult`、`build/NativeLoadingToolbar.xcresult`；动作图标 `build/action-icons-tests.log` |

表中明确限定到用例的结果不代表整个日志或 xcresult 包通过，部分开发中间包含有后来修复的失败项。构建、截图、视频与合成文本在被忽略的 `build/`；文档不提交用户小说。日期或相同目录不代表这些测试是在一次完整验收中执行的。

## 当前安装包与真机交付

2026-10-01，当前 Debug 包含小说详情与信息编辑、章节覆盖、统一批注菜单和合并编辑，以及搜索结果双行布局与撤销药丸对齐。schema 为 13，安装包在 `build/DeviceDerivedData/Build/Products/Debug-iphoneos/Moonread.app`。最新设备构建通过，覆盖安装到 iPhone 13 并启动成功；应用与两个内嵌 dylib 均已验证签名。`MOONREAD_CLOUD_ENABLED=NO`，不作为云功能验收版本。证据：`build/search-row-and-undo-device.log`、`build/search-row-and-undo-install.json`、`build/search-row-and-undo-launch.json`。本次覆盖安装保留测试数据；如后续需要开发重装，直接重置应用内测试数据，不备份恢复，外部小说原件仍不修改。

真机 08:59 的崩溃报告确认 dyld 因 `Moonread.debug.dylib` 缺少代码签名而在加载阶段终止，尚未执行数据库初始化；原因是无签名构建后只签了 `.app`。修复包先签 `Moonread.debug.dylib` 与 `__preview.dylib`，再签应用，每个产物单独验证签名及相同 TeamIdentifier 后成功覆盖安装，没有再次清理数据。打包流程已写入[开发环境](development.md#personal-team-本地试用包)。证据：`build/statistics-startup-crash.ips`、`build/statistics-device-local-final.log`、`build/statistics-signature-fix-install.json`。后续通过 iPhone 镜像确认应用正常启动，从最近阅读进入指定测试书、连续阅读与返回书架均可完成。

当前构建的列表使用 32×44pt 缩略图、60pt 基准行高和单行名称，选中背景覆盖整行；网格仅封面高亮。保留导出暂存回收、共享初始化与正文任务回收。双指连续滑动和边缘自动滚动手感、真实分享宿主、云端批量获取、系统启动快照、自定义主题交接及真实 iCloud/第三方提供方行为仍需真机试用。

早期 iPhone 13 / iOS 27 曾通过 9 项 Swift 单元测试（`build/Device-progressive-fixed.xcresult`），但 UI 自动化服务启用曾超时；均不能替代最新 UI 的真机验收。

## AI 产品验证（2026-10-03）

当前实现及未完成项见 [AI 进度清单](../plans/ai.md)。依赖已锁定 Swift AI SDK `df3e071ac414858a4d57e1cd48b3f686e92ab1ce` 和 SwiftStreamingMarkdown `95bb755a9b23a1aea8682b9ebc912cb72b176c95`；CLI 对锁定依赖使用 `-skipMacroValidation`，不改全局信任设置。会话、连接状态与 SDK 请求适配按 Providers / Agent / Data / UI 分层。

| 能力 | 有效证据与边界 |
| --- | --- |
| 文本与任务生命周期 | `build/ai-layers-verified.log` / `build/AI-Layers-Verified.xcresult`：26 项 AI 原生回归通过，覆盖四协议、SSE、静默取消、停止隔离、关闭重开、删除运行会话、重启中断、草稿、按 SHA 关联、默认模型继承与协议字段隔离 |
| 连接与模型状态 | 同组回归覆盖登录/模型错误区分、验证码过期、按连接取消、移除保留历史与其他账号、模型选择和运行中仅下一请求生效、目录缓存、原有配置键读取 |
| 原生 UI | 同一结果包 2 项 UI 回归通过：浅深色模型/连接路径，以及登录/API Key 分组、添加直达、取消/确认移除。截图 `build/AI-Layers-Screens/` 已查看添加页与连接页；测试使用合成目录与身份 |
| 阅读月亮与弹窗 | `build/ai-stage1-ui-verified.log`、`build/AI-StageOne-UI-Verified.xcresult` 覆盖拖动、打开/关闭重开、草稿和入口；实际截图见 `build/AI-StageOne-Shots/`、`build/AI-StageOne-UI-Shots/`。长时阅读与真机手感不由该用例证明 |
| 思考调节 | 使用原生 SwiftUI Slider；`build/ai-native-slider-verified.log` 的浅深定向 UI 覆盖六档拖动、取消/应用和保存隔离。真实触感与 iOS 18 运行未验收 |
| 品牌资源 | 当前预设均有可加载图标的回归通过；新增 8 品牌来自 LobeHub icons-static-svg 1.95.1，已查看汇总 `build/ai-provider-icons.png`，许可证在应用包内 |
| 最终构建 | `build/ai-layers-final-build.log` 模拟器构建通过，包含分层和资源；未执行真实供应商请求 |

原生网络回归使用合成凭证/URLProtocol，经过真实 SDK 和 URLSession；不能证明实际套餐权限、真实 token 刷新或全部模型行为。无签名测试宿主曾在 Keychain 清理失败，签名宿主的连接移除回归通过；生产没有凭证降级路径。分层初次测试构建中的旧成员引用已更新，最终上述回归通过。

最新手机交付为分层之前的连接管理版：`build/ai-connection-management-device.log` 真机构建成功，已覆盖安装到 iPhone 13，安装工具返回 bundle ID `dev.moonread.Moonread`，保留现有数据。本次安装未记录启动验证。之后的图标补全与分层尚未安装手机；不再用早期常驻滑杆版本描述手机当前安装状态。

正式签名应用的完整设备码授权、Keychain、刷新、账户目录及真实回答仍需验收；独立 Codex 服务实测不能替代产品端到端验收。iOS 18、VoiceOver、长历史内存与跨供应商工具/图片历史尚未验收。正式 Agent 页面使用每页50条的历史读取；对话列表未分页，主动加载的旧历史不自动回收，长会话内存仍待实测。

## 待完成的验证

| 场景 | 当前证据的边界 |
| --- | --- |
| 长时间实读 | 只有下述合成核心和短时原生窗口基线；用户最长小说的持续流畅度、内存趋势、热状态和耗电未完成受控测量 |
| 真机平台行为 | 常亮、方向、亮度的模拟器生命周期测试已做；控制中心改亮度、锁屏、方向请求被系统拒绝和长期耗电仍需实机确认 |
| 旧系统与构建环境 | iOS 18/26 实际运行、Linux/Intel Mac/iOS Release 环境尚未覆盖；部署下限与 API 可用性检查不能替代运行验收 |
| 文件提供方 | 第三方云文件下载、授权失效及恢复未走完端到端流程；提供方可能先整文件下载，不能声称云端边下载边读 |
| 语言与辅助功能 | 主要简中/英文流程已有证据；全应用长英文、较大字号、VoiceOver 和完整主题/辅助功能组合仍未验收 |
| 视觉与长时体验 | 浅深独立配色和若干主题截图已看；完整视觉矩阵、夜间长时阅读、系统启动快照与自定义配色交接仍未完全覆盖 |
| 底部书签操作后的工具位置 | 添加书签、工具收起后再展开，搜索按钮的纵坐标比首次展开偏移约 4.16pt。等面板停稳后仍存在；恢复原来的顶部渐变实现也复现同值，确认不由本次悬浮顶部改动引入。原有全量工具显隐用例因此失败，待独立定位底部面板；证据 `build/reader-floating-controls-verified.log`、`build/reader-original-controls-comparison.log` |

手机曾出现模拟器单次检查未复现的键盘/关闭抖动与偶发浮层残留。相关路径已有修正与定向回归，实际手感继续依用户试用反馈定位；不把模拟器通过写成真机缺陷已全部验收。

## 合成正文测量

本机 macOS arm64、Rust Release、新数据库与刚写入的合成 TXT；每本导入后执行 200 次往返读取，原始记录 `build/reader-long-book.log`。这是核心存储/段落语义读取，不包含系统文件选择器、云文件下载或平台首屏布局。

| 文件规模 | 导入耗时 | 读取窗口中位数 / p95 | 最大正文窗口 |
| --- | --- | --- | --- |
| 5 MiB | 165 ms | 108 / 125 μs | 36,801 字节 |
| 30 MiB | 1,003 ms | 105 / 127 μs | 36,801 字节 |
| 100 MiB | 3,149 ms | 105 / 127 μs | 36,801 字节 |

该结果说明此样本的有限窗口读取没有随全文规模增长；不代表长期手机帧率、热状态或耗电。重跑入口是 Nix 环境中的 `cargo test -p moonread-core --release --test reading_foundation long_book_window_measurements -- --ignored --nocapture`。

iPhone 18 Pro / iOS 27 模拟器、Debug 构建：约 6.5 MiB 合成书籍，每轮 48 次实际原生窗口定位与排版，三轮耗时 2.552 / 2.606 / 2.517 秒；XCTest 物理内存峰值 39,078 / 40,045 / 39,898 kB，轮内增量 82 / 393 / 360 kB。每次核对已渲染文本确实换成目标窗口，常态最多三块。记录在 `build/reader-foundation-outline-final.log` 的 `testBoundedNativeWindowTurnaroundMetrics`。这些是短时合成基线，不能据三轮测量宣称长时内存稳定或无耗电问题。

## 验证方法

按当轮受影响范围完成必要构建、关键回归和授权范围内的启动或安装，再交付试用。正文空间、翻页选字、窗口衔接、工具与键盘动画、定位返回需要查看真实画面，不能只检查数据库或按钮存在。

1. **核心连续阅读**：使用原创合成文本，约 5/30/100 MiB 各往返定位 200 次，记录窗口字节上限、读取中位数和 p95。该测量不包含文件提供方和平台首屏布局。
2. **原生窗口与排版**：连续前后替换有限窗口，核对实际渲染文本和原句位置；覆盖长段 Unicode、标题、不同字体、横竖尺寸与续段，确认页边界无重叠或遗漏，复制不含排版后文。
3. **交互与位置**：覆盖设置即时变化/重启、前后章/百分比/历史、纠错重建、返回取消/完成、搜索/目录互换；纸色、高亮或面板高度改变应只影响绘制与覆盖层。
4. **真机长时使用**：在对应授权任务中检查锁屏/控制中心亮度、热状态、内存趋势与耗电。当前仅安装手机，不自动操作或采集 trace。
5. **根据问题定位**：只有出现稳定内存增长、卡顿或实际缺陷时才进一步用 Instruments 等工具分析，按证据调整预取、布局任务或页面回收；不无依据扩大常驻正文或更换排版引擎。

修复后只复测受影响路径；完整验收按用户要求或集成范围执行。新证据更新对应能力条目，删除失效结论；构建和安装方式见[开发环境](development.md)。

## Agent 与10个读取工具

- 新增 `AIAgentCoordinator / AIAgentRuntime / AIAgentStore / AIReadingTools`；协调器组装实际连接、SDK多步循环、SwiftData存储和全部读取工具。正式 UI 现已统一使用此入口，旧文本循环和消息表已删除。
- 已实现：工具调用及结果配对保存、应用级准备确认、有界并发与取消、steering/follow-up队列、下一步切换模型、跨协议历史投影、中断不自动补发、每页50条keyset历史、中文保守预算、摘要检查点与有界压缩。
- 10个工具为 `ls/search_books/get_book/get_chapters/read/rg/get_marks/get_mark/get_reading_statistics/get_environment`。使用 ReaderService 最终业务数据与 Rust 正文查询；共享准备不登记正式阅读来源、不写位置或产生统计。书库筛选和搜索结果分页目前基于有界业务结果，不等于数据库级全书库分页。
- 定向构建及原生回归通过：`AIAgentRuntimeTests` 13项、`AIReadingToolsTests` 3项，共16项、0失败。测试宿主在 iPhone 18 Pro / iOS 27 模拟器启动成功。日志 `build/ai-agent-tests.log`；结果 `build/AIDerivedData/Logs/Test/Test-Moonread-2026.10.03_21-33-16-+0800.xcresult`。`git diff --check` 通过。
- 覆盖多步配对、队列顺序、换模型、无工具模型、重复执行限额、确认拒绝/停止、重启修复未完成调用、数据库分页、压缩成功/失败与超窗错误分类；实际工具覆盖更正章节、UTF-8分页、批注冲突、参数校验及无阅读副作用。
- 四协议回归使用合成认证及 URLProtocol SSE，通过真实 SDK/URLSession 检查 Responses、Chat Completions、Anthropic 和 Gemini 的工具调用→结果→最终文字。测试中发现 SDK 步骤通知与下一步准备存在时序竞争，已改为从 prepareStep.steps / result.steps 提交步骤；修复后的两次定向运行均通过。
- 未验证真实供应商账号调用、真实 iCloud 下载、最低 iOS 18 或长会话性能。页面接入的当前证据见下方；会话列表分页、真实长历史和真机交互仍未验收。联网、图片、写入提案、书架整理不在这次只读 Agent 后端实现中。

## 2026-10-03：对话骨架与结构化阅读附件

- 阅读入口在唤起时抓取正文身份、可见 UTF-8 范围、章节与可用进度；选文另存独立附件。普通滚动不重新生成草稿。无现成全书页码时不造页码。
- 输入框接入附件摘要、详情、移除，以及 `+` 的书籍/书签/批注选择。使用现有授权书架与最终用户数据，选择时不下载正文、不写阅读进度。冲突批注保留候选与删除状态。
- 文字与附件同一次 SwiftData 保存，消费待发送草稿；历史附件可查看。移除后关闭重开不自动补回。正式页面通过 Agent 队列发送附件，不发送固定页面提示。
- 构建通过，16项定向回归通过（13项 Agent、附件保存/移除/请求、输入框渲染、停止重开）；最终导航/本地化变更后再跑两项附件用例通过。日志 `build/ai-reading-attachments.log` 与 `build/ai-reading-attachments-final.log`。测试通过真实 SDK/URLSession 的合成响应检查移除的数据不会进入请求，不涉及真实付费服务。
- 已人工查看原生宿主截图 `build/ai-reading-attachment-composer.png`，位置摘要与选文分行，输入、添加、模型、发送均可见。该截图未覆盖键盘、多尺寸、VoiceOver或真机；不据此宣称这些已验收。`git diff --check` 通过。未安装手机、提交或推送。


## Agent 正式页面接入（2026-10-04）

对话 Tab 与阅读弹窗统一使用 AIAgentCoordinator；旧文本请求循环、AIMessageRecord 与旧消息投影已删除，不保留开发数据兼容或迁移。过程运行时展开、完成后折叠，最终回答独立；工具详情、准备确认、steering/follow-up、月亮活动和来源预览均接入真实运行状态。网络/API 失败保留内容并显示短句，用户发送普通消息继续，不增加通用重试。

- 模拟器受影响构建和测试宿主启动通过。原生回归分次累计47项通过，1项无签名宿主 Keychain 清理检查明确跳过；生产没有凭证降级路径。`build/ai-agent-ui-final.log` 覆盖运行器15项、工具3项和会话29项，其中旧换模型夹具缺少容量导致一项失败，补齐模型数据后在 `build/ai-agent-ui-verified.log` 定向复测通过，同时验证选择保存；最后新增来源与图标检查及受影响状态/截图复测3项通过，见 `build/ai-agent-ui-render.log`。
- 四协议仍使用合成认证与 URLProtocol，经真实 SDK/URLSession；验证工具配对、跨模型协议字段过滤、排队、压缩、停止、重启中断、附件、默认模型和错误后普通“继续”。工具测试调用真实本地 Rust/Swift 业务层，不代表真实供应商或云文件验收。
- 一项正式 UI 回归通过：拖动阅读月亮、打开弹窗、关闭重开保留输入、返回对话 Tab 与设置。见 `build/ai-agent-ui-verified.log`，结果包 `build/AIDerivedData/Logs/Test/Test-Moonread-2026.10.04_00-34-35-+0800.xcresult`。
- 原生挂载正式 AIChatView 的过程/工具/部分回复/网络错误截图已人工检查：`build/ai-agent-process-failure.png`。该截图用合成消息，不能当作真实联网回答。最后结果包 `build/AIDerivedData/Logs/Test/Test-Moonread-2026.10.04_00-36-42-+0800.xcresult`。
- 历史首次读取50条，按需向前分页；未声称对话列表已分页或已加载窗口会自动回收。来源预览按工具结果的 SHA、范围与引用校验读取，不调用正式开书、位置写入或统计记录。
- String Catalog JSON、`git diff --check` 通过。本轮未安装手机、未提交推送，未使用真实账户发请求。真实服务组合流程、iOS 18、VoiceOver、长历史内存和真机手感仍待对应验收。

## 开发期结构清理（2026-10-04）

已移除连接的 Codex 隐式默认与双分类、会话模型选择双写、ReaderCore 原始业务查询出口、主题整份快照套存以及闲置 AI 附件实体/重复上下文。保留实际用途的请求选择快照、输入草稿与首帧主题缓存，不增加旧开发数据迁移。

- 按请求先安装清理前的最新应用到已连接 iPhone，安装及启动成功。证据：`build/ai-agent-device.log`、`build/ai-agent-device-install.json`、`build/ai-agent-device-launch.json`。手机当前仍是这次清理之前的版本；安装/启动不代表用户已验收功能。
- 清理后 Rust 核心54项通过，1项长书性能采样按既定标记忽略；严格 Clippy 通过。日志：`build/cleanup-rust.log`（含通过的测试和随后已修正的初次 Clippy 诊断）、`build/cleanup-clippy.log`（最终通过）。
- 清理后 iOS 模拟器构建、77项原生回归和1项 UI 回归通过，无失败。覆盖显式连接编码、默认模型就绪与选择重读、四协议生命周期、Agent 队列与停止、10个读取工具、最终业务查询、单份配色与删除回落、文件移动/替换与云转存身份，以及月亮/弹窗/对话 Tab。日志：`build/cleanup-ios.log`；结果：`build/AIDerivedData/Logs/Test/Test-Moonread-2026.10.04_01-07-25-+0800.xcresult`。
- 生成的 Swift 绑定已确认：书籍/章节/搜索/统计等业务查询仅由 ReaderQuery 暴露；ReaderCore 的导入与文件索引接口返回专用类型。无真实账户请求、无真实跨设备云同步验收，未再次安装清理后版本到手机。

## Typed 工具与 SDK 接入核对（2026-10-04）

- 依据用户授权只读导出的手机对话，复现空 fileRef/bookRef、空 cursor/chapterRef 被当作实际引用，以及 rg 翻页改变 maxHits 后被拒绝的问题。测试使用合成小说与引用，导出的对话不进入仓库。最早一次只有通用“请求未完成”的记录没有底层错误，无法据此归因。
- 十个工具改为 SDK TypedTool 的 Codable 输入/输出，删除手写字段校验器与原始 JSON 分发。锁定 SDK 的 nil 可选枚举/数组 schema 推断缺口以类型派生的 schema 补充，并通过真实 SDK validator 验证；SDK 参数错误按原生 error-text 进入后续模型步骤，页面正确显示失败。
- 模拟器构建及54项受影响原生回归通过：工具6项、Agent16项、会话32项。覆盖10个工具、UTF-8/修正目录、正文准备不写阅读状态、参数省略/null/空串、枚举/数组、8→22条搜索续页、SDK 拒绝→模型修正→最终回复、队列/取消/确认/压缩、四协议合成网络、正式页面挂载及 Markdown 重新订阅。日志：`build/typed-tools-tests.log`。
- 另补一项批注分页回归通过：1024→2048字节续页，中文与 emoji 拼回原评论，无丢失/重复。日志：`build/typed-tools-note-test.log`。
- Markdown 使用库提供的 StreamedMarkdownView；仅渲染快照缓冲一份，重新订阅获取最新内容，未移动网络任务所有权。没有自行实现 Markdown 解析器。
- 核对后保留 SDK streamText 循环、prepareStep、应用确认与存储；自定义 fetch 仍仅承担字节流交付/取消。SDK 原生 approval 的消息续传语义不直接替代现有应用确认。未新增重试机制。
- 模拟器合成协议与本地业务回归不等于实际供应商验收；后续真机安装见下文。

### Typed 工具修复真机试用

已按用户要求构建签名版本、覆盖安装并启动 iPhone，启动后进程仍在运行。日志：`build/typed-tools-device.log`、`build/typed-tools-device-install.json`、`build/typed-tools-device-launch.json`。仅将 `ai-conversations.store` 及日志替换为当前 schema 的空库，清除旧开发对话；未修改书架、阅读数据、连接配置或 Keychain。真实工具调用效果留待试用，本次没有发送真实模型请求。

## 阅读导航背景与番外识别（2026-10-04）

- 阅读原生导航栏显式使用阅读纸色。iPhone 18 Pro 模拟器构建与定向 UI 回归通过，分别验证实际浅/深色、导航上下背景一致及工具展开前后阅读位置不变；已人工检查两张截图。日志：`build/reader-header-ui.log`，截图：`build/reader-header-verified-shots/`。首次运行受模拟器旧开发数据影响，设置保存弹错导致深色未生效；清空模拟器应用后重跑通过，并加入实际明暗断言。未重置手机数据。
- Rust 库15项测试通过，覆盖编号特殊章节、跨块识别及正文误判排除。另有只读目录核对；公开记录不保留原书名、私人章节统计或关联日志名。临时探针已删除。
- 既有自动目录需使用“重新识别目录”重算。已随下述真机包交付。

## 轻量对话过程（2026-10-04）

- 正式对话页面按两段回复之间的连续推理/工具分组，默认折叠；中间回复直接展示，完成后整体收起过程。推理行使用实际文本单行省略与 sparkles，展开查看全文；工具参数/结果由详情 sheet 展示，来源入口只保留在对应结果内。
- SDK reasoning-start/end 驱动真实推理活动，分组/工具/推理分别显示系统加载指示；终态及等待确认无持续加载。工具执行和确认的状态通知保留当前文本，避免中间回复短暂消失。未改变工具循环或新增重试。
- 标题与输入区域使用不透明主题底色，回到底部为圆形图标按钮；滚动几何判断是否到达底部，短内容从顶部排列。运行时空输入显示停止，有输入时发送/完成后发送/停止仍可用。
- iPhone 18 Pro、iOS 27 模拟器构建通过。最终 21 项原生回归（20 项 Agent、1 项运行/完成画面）通过：`build/ai-light-process-final.log`；覆盖分组边界与身份、推理无文本开始/结束、工具/确认/终态加载、工具期间中间回复保留，以及既有停止/循环/队列回归。
- 失败页面原生检查与阅读月亮→弹窗→关闭重开→对话 Tab 的 1 项 UI 回归通过：`build/ai-light-process-ui.log`。已人工检查运行和完成的原生截图，短内容顶部对齐、加载指示、主题底色和完成折叠正常。截图为合成对话，不代表真实服务输出验收。
- 对话消息区域支持点击收起键盘与原生交互式下拉收起，空对话也允许拖动。受影响构建及 1 项 UI 回归通过：`build/ai-keyboard-dismiss.log`；验证空对话输入后点击空白、重新聚焦后下拉均收起键盘，草稿保持。
- 已随下述真机包交付；没有改写小说原文。最低系统与真实服务验收仍独立于合成回归。

## 对话首次发送保存（2026-10-04）

- 未发送的对话、文本、阅读附件和模型选择只保留在应用内存中；历史列表不显示它们。首次发送将会话、模型选择及发送队列一起保存，失败或停止后保留已发送记录。
- 模拟器受影响构建、5 项原生回归及 1 项阅读入口 UI 回归通过：`build/ai-first-send-tests.log`。覆盖未发送不落库、重开输入、首次发送及停止后重载、模型选择/请求档位一致、附件移除与发送、正文 SHA 关联和历史列表不出现空对话。
- 真机签名构建通过：`build/ai-first-send-device.log`；已覆盖安装到 iPhone 13：`build/ai-first-send-install.json`。包含本次会话保存调整及此前键盘收起、轻量过程、标题背景与番外识别改动；未清理现有数据。
- 自动启动被手机锁屏拒绝：`build/ai-first-send-launch.json`。安装已完成，需解锁后手动打开；真机交互留待用户试用。

## 对话过程密度与详情弹层（2026-10-04）

- 过程区收紧为 32pt 紧凑行与 6pt 组内间距；分组标题使用正文色/中等字重，工具行使用较大次要文字，不重复显示成功状态。完成分组使用简短类别名及次数，推理保持真实文本预览。
- 工具参数、结果及来源入口恢复到 medium/large 详情 sheet，关闭按钮跟随主题色；推理全文仍在原位展开。
- 受影响模拟器构建及原生运行/完成画面回归通过：`build/ai-compact-process-screens.log`。人工检查紧凑行和详情弹层截图；使用合成数据验证布局，不代表真实工具结果或真机触控验收。
- 真机签名构建、iPhone 13 覆盖安装及启动成功：`build/ai-compact-process-device.log`、`build/ai-compact-process-install.json`、`build/ai-compact-process-launch.json`。未清理数据。
- 展开交互已统一为原生 `DisclosureGroup`（整轮过程、活动分组、推理全文），删除自写按钮/条件插入与箭头动画；工具详情 sheet 保持。此前只为箭头增加旋转没有覆盖内容展开。受影响构建及 1 项原生画面回归通过：`build/ai-native-disclosure.log`；已完成真机签名构建、iPhone 13 覆盖安装及启动：`build/ai-native-disclosure-device.log`、`build/ai-native-disclosure-install.json`、`build/ai-native-disclosure-launch.json`；动态展开与真机闪烁改善仍待用户试用确认。

## 2026-10-04：供应商认证扩展（部分完成）

- OpenRouter 无回调 PKCE 到 API Key 和 API Key 供应商预设保留。Copilot 与 Meta／Kimi／xAI 设备码接入现已移除；旧验证不再代表现行支持。
- 原合成回归日志 `build/ai-provider-expansion-final.log`；现行保留 OpenRouter verifier 单次使用及按尝试取消、供应商思考字段选择，移除登录的测试已删除。没有真实服务权限证据。
- 尚未完成公开 SIWC、Radius、全部逐模型思考参数适配。Anthropic 订阅不复制官方客户端身份。新增认证的真实登录、续期、账户目录和推理未验收，不能由合成回归推定可用；具体边界见 [供应商范围](ai-providers.md)。
- 本轮未提交、推送或安装手机；保留此前阅读检索工具改动。


## 2026-10-04：现有供应商适配收敛

- 保留现有入口，停止以新增 Pi 供应商为目标。目录保留思考参数类型/预算边界；请求区分 Claude 预算与 adaptive、Kimi adaptive、Gemini budget/level、Baseten 模板参数及已知 OpenCode 路由差异。无显式选择时不覆盖服务默认值。
- 补齐现有六个品牌资源及映射，使用项目已有的 LobeHub 固定版本与许可。OpenRouter/Baseten 加稳定会话标识；不新增缓存 UI、重试框架、企业云认证或独立 Agent 循环。
- 七项受影响原生回归通过，包含实际 SDK 请求体检查、四协议生命周期、协议字段隔离、目录/网关路由、全部预设品牌资源与连接保存。构建和测试宿主启动通过，日志 `build/ai-provider-polish-tests.log`。固定网关目录夹具补充验证日志 `build/ai-provider-catalog-final.log`。
- 使用合成认证及 URLProtocol，无真实供应商调用；未提交、推送或安装手机。新增服务的账户权限和真实推理仍未验收，不将本地回归等同于所有模型均可用。

## 原生搜索、生图工具与默认用途设置（2026-10-04）

- 已接入 web_search/generate_image TypedTool、独立 Provider 执行器、联网搜索/图片生成服务配置、引用链接及生成图片预览。仍复用现有 SDK 流解析、主 Agent 工具循环、错误与取消机制；没有自动重试或备用计费连接。
- 图片附件按任务/会话范围写入应用私有目录，工具历史只保存引用。参考图编辑读取同范围附件；取消清理本次未交付结果，删除对话清理会话图片。Providers 登记运行中的原生请求，退出或移除连接会取消使用该连接的请求。
- 模拟器构建通过。最终 9 项 AINativeToolsTests 与 1 项运行中删除对话回归通过，共10项、0失败，日志 `build/ai-native-delivery.log`。覆盖 Codex 搜索引用、生成/编辑、图片持久化重读与引用隔离、默认配置重读、聊天与搜索模型独立、OpenAI/xAI 图片请求格式、未配置不调用、静默连接取消和清理。此前受影响的20项 AIAgentRuntimeTests 通过，见 `build/ai-native-tests.log`。
- 此前一项正式 UI 回归覆盖旧用途选择器；现已改为服务优先设置，这项旧结果不作为新页面的验收。日志 `build/ai-native-ui.log`；截图 `build/ai-native-shots/`，已查看正式设置画面。原生设置截图最初因测试窗口未绑定 scene 为空，修正测试挂载后重新通过；不使用空截图作视觉证据。
- 首轮新增回归的两个断言失败分别来自 JSON 转义字符串检查及未等待 URLSession 异步取消回调；改为结构化请求断言和等待真实 stopLoading 后通过。未通过删除断言或放宽取消要求掩盖故障。
- 请求测试使用合成身份、URLProtocol 和真实 SDK/URLSession；本轮没有调用真实服务、读取其他应用凭证、安装手机或提交推送。既有 Codex 独立服务证据不代表这版完整产品已通过真实登录与生成验收。
- 当前为 hosted-tool 生图路径。独立 Images API 的图片专用模型、Grok OAuth 搜索/生图尚未开放，其他供应商不自动继承能力；账户权限仍需对应通道验证。模型族和正式端点限制集中在 AINativeCapabilities，不代表公开模型元数据能够证明套餐权限。业务快捷任务、封面应用和资料预览未在本轮实现，见实施计划。

### Codex 公共模型目录（2026-10-04）

已用 Pi 公共目录的内置快照、远端覆盖和持久缓存替换只读硬编码清单；启动保留已保存目录，4 小时检查、手动强制刷新、ETag/304、失败保留缓存。目录中的 thinkingLevelMap 同时控制可选档位及请求值，6.1 Sol 的 minimal 映射为 low，不允许 off，提供 xhigh/max。11 项定向回归通过（供应商协议及设备码/目录），包括远端覆盖、持久缓存恢复、ETag/304、网络失败保留缓存和 minimal 请求映射，日志 `build/codex-catalog-fix.log`。使用合成协议测试；公开目录已实际读取核对，没有新增真实账号推理调用。

### 对话列表主题、工具返回与上下文预算（2026-10-04）

- 对话列表行背景与次要文字使用当前主题，未改 Markdown 配色。浅深主题宿主截图已目视检查，`/tmp/conversation-list-light.png`、`/tmp/conversation-list-dark.png`，截图附件也在 `build/ai-context-verified.log` 对应 xcresult。
- 搜索移除重复 sources，由命中数据派生原文预览；条目页约8 KB，正文默认8 KB/最大16 KB。参数说明补齐 rg -F/-i 与 read 上下文用法；章节支持标题筛选。
- 混合文本预算替代 UTF-8 字节计token；长轮次可在完整工具组之间压缩，删除固定四次摘要限制。Responses 使用稳定会话缓存标识，持久化服务返回的缓存读写与推理用量，输出 length 单独提示并保留用量。
- 受影响构建通过；32个相关用例分批通过（Agent 22、读取工具9、列表截图1）。`build/ai-context-verified.log` 中压缩测试暴露固定四次摘要限制，修复后 `build/ai-compact-final.log` 定向通过；章节筛选及压缩失败保留历史最终10项见 `build/ai-tools-final.log`。
- 合成协议验证了缓存标识和用量持久化，不代表真实服务缓存命中率；估算仍非精确tokenizer。未安装手机，未提交或推送。

### 2026-10-04 上下文用量与读取工具精简

- 上下文预算优先复用最近一次有效步骤的实际 inputTokens + outputTokens，只估算后续消息；缓存输入不重复加算。provider/model、请求 options/system、启用工具定义和压缩检查点共同界定基准有效性，变化后使用估算。
- read 只返回文本、实际范围、来源引用及 page，移除重复 requestedRange/textComplete/sources 内容。批注列表评论与摘录各300字符；get_mark 评论继续按 UTF-8 游标分页，原文通过 read 获取。来源预览从同一结果数据生成。
- 补充书架层级/递归范围、准备正文、日期和冲突候选等参数语义。书籍搜索、目录、统计已有分页预算，环境信息按需取字段。
- 最终模拟器构建和 AIAgentRuntimeTests 24项、AIReadingToolsTests 9项全部通过：build/ai-usage-tools-final.log。涵盖实际用量避免提前压缩、配置变化使旧基准失效、缓存不重复计数、长评论摘要/UTF-8续读及来源预览。git diff --check 通过。
- 使用合成模型与本地工具，不证明真实供应商缓存命中、实际token精度或手机体验；本轮未安装、提交或推送。

本轮后续真机交付：签名构建通过并覆盖安装到 iPhone 13，保留现有数据。日志为 build/ai-usage-tools-device.log、build/ai-usage-tools-install.json。自动启动因设备锁屏被拒绝（build/ai-usage-tools-launch.json），需解锁后手动打开；未宣称真机功能验收通过。

## AI 全模块契约核对（2026-10-04）

范围、逐项处理及证据来源见 [AI 实现核对](ai-implementation-audit.md)。本轮没有真实账号请求，没有读取外部软件凭证，没有提交、推送或手机安装。

- iOS 27 / iPhone 18 Pro 模拟器，`build/ai-provider-audit.log`：受影响工程与测试宿主构建通过；AIAgentRuntime 25、AINativeTools 12、AIProviderContract 7、AIReadingTools 9、AIStageOne 42，共95项，零失败，其中1项因无签名宿主无法访问 Keychain 跳过。凭证删除仍需签名环境验证。
- 各请求使用注入的合成认证和 URLProtocol，经过锁定 SDK / URLSession；现行保留 OpenAI/Codex hosted tool、xAI API Key 精简搜索及来源／Images 单多参考图、OpenAI Images、Google Imagen/Gemini inline图片。xAI 订阅登录路径已删除。不是实际账户成功记录。
- 覆盖 OpenRouter reasoning_details 两轮回放、缓存断点、跨模型工具 ID 配对、Anthropic/Gemini 实际请求输出上限、摘要分片、usage与配置失效、队列/停止/错误及阅读工具预算。未映射的控制不会生成任意 effort 枚举。
- 查看了本轮深色对话列表截图 `/tmp/conversation-list-dark.png`：背景和行容器接入主题；这里只证明该渲染画面，不代替真机操作验收。
- `git diff --check` 通过。后续真实账户、套餐权限、签名 Keychain 与 iOS 18 实机没有由合成回归覆盖。
- 最后补充的目录修复：`build/ai-directory-contract-verified.log` 构建和测试通过，11项零失败；覆盖 Gemini/Anthropic 官方目录字段与分页、无 Codex slug 假设、失败保留当前模型及内置 Codex 目录。首次新增夹具因局部字典声明不可变编译失败，改正后复测通过。

### 工具服务优先配置与 Codex 默认检查（2026-10-04）

联网搜索、图片生成使用独立的服务优先配置页；通用模型选择器仅负责对话。支持连接与模型资格分开校验，未加载目录仍能管理连接，自定义端点不继承官方工具能力，未配置不默认 Codex。删除以 Codex 身份推断未知模型文字能力的补值，保留专用认证、目录和协议适配。

受影响构建与 22 项原生回归通过（13 项原生工具、9 项供应商协议），日志 `build/ai-service-selection.log`。最终布局/本地化调整后再构建并通过 1 项页面渲染回归，日志 `build/ai-service-layout.log`；已查看搜索、图片服务的实际渲染截图，模型改为系统菜单，Codex 绘图模型显示由服务决定。这是合成连接与模拟器证据，不是新增真实账户调用或手机验收。未提交、推送或安装手机。

Codex 目录最终复测：`build/codex-catalog-final.log` 的 11 项测试全部通过；`build/codex-catalog-device.log` 签名构建通过。已覆盖安装到配对 iPhone 13，devicectl 启动成功，保留应用数据。进入 AI 页面即应用目录缓存，网络检查由目录的 4 小时有效期控制；未进行真实账号推理验收。

### 多书准备与模型配置校验（2026-10-04）

多书查询确认汇总所有未准备书籍并按引用去重；手工添加模型要求有效上下文容量，最大输出可选且不能超过上下文；普通 API 连接的手动刷新等待公开目录再应用模型列表，期间新增的手工模型保留。Codex 独立目录不经过这条公开目录刷新路径，不能把其此前缺少 GPT-6.1 Sol 归因于此。

受影响模拟器构建及 13 项定向回归通过，日志 `build/pr4-review-fixes.log`：阅读工具 10 项、手工容量保存/校验、首次刷新立即应用新型号、目录失败与认证状态各项通过。未进行真机安装或真实供应商请求，本次表单尚未进行真机视觉验收。

### 已发现模型的手动容量（2026-10-04）

手动填写已有模型 ID 时更新其上下文和最大输出容量，保留名称与能力且不创建重复模型。最大输出留空保留已有值；目录刷新更新模型资料，同时保留手动容量。持久化读取和公开资料补全也遵循手动容量。

受影响模拟器构建及 3 项定向回归通过，日志 `build/custom-model-capacity-review.log`：无容量自定义模型补填后刷新、重新读取配置仍能解析出有效请求容量；手工容量校验与可选输出；手动刷新立即应用新目录。使用合成认证和 URLProtocol，未进行真实供应商请求或真机表单验收。

### Agent 新轮次与工具调用配对（2026-10-04）

移除按 callID 命中旧结果或报重复调用错误的额外逻辑；编号继续用于协议配对，已完成结果只保留到当前步骤持久化。初次运行与排队 follow-up 共用执行状态重置，清空计数、重复结果统计、拒绝记录、结果和上下文超限重试标记，保留对话历史。

受影响模拟器构建及 27 项 Agent 回归通过，日志 `build/agent-follow-up-final.log`。新增回归覆盖不同步骤复用调用编号仍执行，以及前一轮拒绝后 follow-up 使用同一编号重新询问、批准执行；现有停止/中断结果配对与压缩回归通过。首次新增夹具未保留 SwiftData 容器导致宿主退出，修正夹具生命周期后复测通过；前次中间回复观察断言失败，最终重跑通过。合成模型验证，未进行真实供应商请求或手机安装。

## 2026-10-04 Agent 与 Pi 执行策略对齐

删除固定模型步数/工具次数、重复结果终止、调用结果与拒绝缓存、固定并发门槛、工具/网络附加超时、通用响应拒绝与额外参数限额。读取/检索采用 Pi 单次输出预算与默认语义；检索删除底层总命中上限，游标不依赖服务内存或闲置过期。上下文用量、回退估算、压缩保留目标与摘要思考配置同步调整。完整依据与产品差异见 [ai-pi-alignment.md](ai-pi-alignment.md)。

验证：

- 受影响模拟器构建与测试宿主启动通过。Agent 28、原生工具13、阅读工具11、供应商协议10，共62项通过；日志 `build/ai-pi-alignment.log`。包含60次相同工具调用正常完成、同一轮拒绝后再次确认、callID重用、跨工具实例分页、2000行续读无缺字、实际用量与压缩回归。
- 原生工具最后调整后13项再次通过，日志 `build/ai-pi-native-final.log`。xAI五张参考图合成请求的补充定向回归1项通过，记录在 `build/ai-pi-xai-final.log`。
- Rust `library_tools` 8项通过，日志 `build/ai-pi-rust.log`；新增全书2101次命中正常返回，保留范围限定、章节投影及取消验证。现有 target软链接失效，本次使用临时 CARGO_TARGET_DIR，未改变 Nix 工具链。
- 中间回复回归继续验证已保存文本、最终回复及工具活动；不要求 SDK 工具执行和 fullStream 消费必定在同一 UI 快照发生。

以上供应商验证使用合成响应与真实 SDK/URLSession，不代表已执行真实账户请求、云小说下载或生图。此次未安装手机。


## 2026-10-13 单书投影与本地首页快照

开书的 snapshot/frame 共用一次单书投影；SwiftData 按正文 SHA/pending key 读取位置、资料和章节覆盖，查询保持不可变快照并按输入版本缓存。文件夹入口同样走单书开书路径；普通目录仅补该目录相关书籍的用户数据。返回首页只更新退出的那本书。阅读设置使用验证后的内存副本。

删除读路径的全库位置压缩、pending 恢复和全局 draft 回收；位置写入只处理该 key，CloudKit 导入只失效缓存。pending 数据在启动恢复之前仍可读。完成/释放只回收当前已转正且无 lease 的 draft，全局回收在本地首页建立后启动一次。未增加维护 actor、优先级票据、空闲压缩或同书等待机制；原有退出最终保存与 StatisticsWriter.drain 契约保持不变。

首页 shelves/top3 recents 原子发布；本地快照和主题共同控制启动遮罩，封面共用订阅预热最多 150ms，根等待最多 1s，无缓存超时呈现明确加载/错误状态。自动刷新静默，等值首页不重新发布；目录结构变化与成功文件操作仍使文件夹失效，普通阅读位置更新不触发全目录重载。

默认关闭的 ReaderOpenDiagnostics 补充 actorOpeningBegin、actorProjectionReady、actorFrameBegin/End、mainActorOpeningResumed，便于区分 actor 入队等待与 MainActor 恢复。首次 snapshotRequested→snapshotCompleted 现在包含 frame 查询，首次 frameRequested 不再单独出现；后续显式刷新 frame 仍保留该事件。正式包不启用诊断，本轮不进行真机性能采集。

本地验证：Nix `cargo test --locked -p moonread-core` 70 项通过、1 项原有 ignored；Clippy `--all-targets -- -D warnings` 通过（`build/SingleBook/rust-final-tests.log`、`clippy.log`）。完整 Swift 单测 303 项、2 项原有跳过、零失败（`local-final.log`）。覆盖单书/批量查询一致、不可变旧快照、本机写入/云通知/隐藏/偏好/统计代次失效、pending 转正前可读、设置内存副本、原子等值首页、同数量非最近文件改名。阅读位置、统计与取消现有用例通过。

受影响模拟器回归覆盖首页和完整最近列表、混排列表/网格、慢加载取消、实际目录创建/改名、文件夹按钮及手势退出后立即续读、原上下文返回与原生选择。初轮发现旧网格首行/外观设置路径假设及分页前置条件不符，按现有契约修正；SwiftUI 增量更新表达式触发编译器复杂度限制后提取为独立函数。最终受影响 9 项模拟器 UI 场景分别复测通过；隔离模拟器的正式代码后台/位置/立即续读 3 项通过，日志 `clean-background.log`；截图导出在 `build/SingleBook/screens/`。正常签名 Release 已构建及 codesign 校验通过，未启用 READER_OPEN_DIAGNOSTICS/AI_TESTING，路径 `build/SingleBookProduction/Build/Products/Release-iphoneos/Moonread.app`，最终构建日志 `production-installed.log`。

完整测试调用同时包含旧 UI 断言失败；303 项单测本身零失败。该次 Xcode 在用例结束后结果收集未退出，已中断仅该本机 xcodebuild 进程并保留日志；不把整个调用记为成功。受影响 UI 分开复测。真机体验仍由用户试用，不声称快速重开或首页视觉体验已验收。

### 后台偏好与位置保存补充

严格启动回归曾观察到 reduceMotion 在前台/后台恢复为 1、终止后重启为 0。干净 HEAD `106465c` 的独立 worktree `/private/tmp/moonread-launch-head-20261013`、独立 DerivedData 也复现同样失败；仅移植测试的外观子页导航修正，生产源码保持 HEAD（`head-baseline.log`）。因此不能归因为本轮单书投影回归。

临时 Logger 包尚未加入后台保护的另一次运行通过。该成功样本中：偏好 queued→MainActor invoke 337ms，invoke 与 saveThemes actor begin 同毫秒，读完成 9ms、写完成再 6ms、回到 MainActor 再 36ms。启动 recovery 4–7ms，早于编辑约 11 秒；没有观测到本次设置被全局回收长期堵住。日志 `save-events.log`、`save-diag-test.log`；不把成功样本当成已定位此前失败的根因。临时日志已全部还原，补丁仅在 `build/SingleBook/save-instrumentation.patch`。

旁注（本轮不优化）：queued→invoke 的约 1/3 秒属于 MainActor 调度/恢复延迟，可能与偏好或动画变化引起的大范围视图重建有关；与开书的 MainActor 恢复等待属同类候选。该样本没有 CPU 栈，未把具体重建原因当作已证实。

新增系统后台任务保护：scene 进入 background 时同步申请 assertion，等待 ThemeStore.flushPreferences；阅读页的后台位置保存也等待 ReaderSession.flush。保存结束或系统到期释放 assertion，无优先级/维护执行器改动。启动测试每次明确编辑 0→1，保留后台恢复及冷启动的持久化断言，避免已经为 1 时跳过写入。补充阅读位置后台→终止→重启回归。最终正式代码在隔离模拟器严格偏好冷启动连续 3 次通过；单书失效/偏好合并及失败回滚 9 次单测通过，`final-clean-tests.log` 以 TEST SUCCEEDED 结束。阅读后台后终止并冷启动、按钮/手势立即续读均通过（`clean-background.log`）。旧模拟器偏好域约 5.13MB，含 444 个测试 appearanceCache、合计约 3.03MB；这是环境差异，未证明它导致间歇失败，未清理该环境或为它增加生产兼容/优化。

2026-10-13 已使用正常签名 Release 覆盖安装到用户 iPhone 13 并启动；devicectl 两项均成功，日志 `device-install.log`、`device-launch.log`。没有清理数据、运行设备 XCTest、测手机性能或操作镜像/阅读 UI。codesign 校验通过，未启用诊断/夹具参数，二进制不含临时 Logger 子系统。用户快速重开、首页视觉与真实阅读数据/统计体验仍待试用验收。

## 2026-10-13 AIStageOne 测试契约校正（独立测试边界）

依据 [AIStageOne 审计](#aistageone-历史断言审计2026-10-13) 与 AI 现行设计，仅修改 AIStageOneTests，不改 AI 源码：两处未发送会话重载改为不存在；非法声明默认 effort 为 nil，保留合法 medium 的对照；显式附件比较独立 occurrence 的完整字段及持久化后相同 id。

补充发送后重载 connection/model/effort 与实际隔离请求一致、后续选择不改首条历史、附件移除不回写旧消息、两次请求均不泄漏固定 context。重载 picker 所用合成连接目录在测试内显式保存；没有使用重载实例发起真实网络请求。该测试文件、审计文档和本节记录组成可独立提交的边界。

初次增加重载 picker 检查时，夹具未保存连接目录，导致 picker 查询为 nil；已在夹具测试流程补充 saveConnections，未修改生产 AI 行为。最终完整模拟器 Swift 单测 303 项、2 项原有跳过、零失败；AIStageOne 60 项、1 项原有跳过、零失败，包含本节三项用例与新增断言。日志 `build/SingleBook/local-final.log`。该轮独立 UI 目标的前置条件失败记录在书架回归部分，不属于 AI 失败。

## 2026-10-13 真实开书等待定位与云交接修复

用户日常试用正常包仍出现准备扉页，先前单书投影的推断不足以解释真实等待。随后诊断 Release 保留数据覆盖安装，用户手动打开，Time Profiler 开启等待线程与 ReaderOpen signpost。捕获中实际有 7 个完整开书请求（用户口述 3 次，按事件保留全部，不任选其中三次）。revision 请求入队到 ReaderService 开始执行为 520.2–550.2ms；执行本身小于 0.1ms，后续单书投影/frame 约 7–14ms，MainActor 恢复通常小于 1ms。

符号化等待栈明确为 scheduleCloudLibraryUpdate → updateCloudLibrary → publishCloudHandoff → refreshLibraryShelf → coordinatedRead → NSFileCoordinator → semaphore_wait_trap。其结束与 revision actor 开始约同毫秒。记录的等待权重不能当作 CPU 耗时。证据保留在本机 `build/ReaderOpenFocused/focused-open.trace`、`device-events.jsonl`、`alignment.json`、`resolved-samples.json`，包含用户数据，不提交。

修复把交接重活移出热路径：快开/导入完成不再无条件调度；完成交接且根未变化、无待处理标记时在容器查找、receipt 读取、协调与枚举之前返回。冷启动检查和真实新本地文件仍能触发待交接恢复。真实交接的校验、文件协调、枚举、receipt 持久化及清理在后台 I/O 队列执行；源与目标协调保持到 actor 原子发布完成，顺序仍为索引提交→published receipt 落盘→原件清理。actor 只接收准备好的结果，重验账户、根和 ImportSource 快照，防止 await 期间变化导致错误发布。

按照用户最新流程，本地回归后直接安装功能相同、仅额外写 JSONL 的诊断 Release，日常试用，不安排专门点按或再次 Instruments。当时等待用户反馈；后续用户验收与正常包交付见本页“开书云交接修复验收与正式交付”。

本地完整 Swift 回归 306 项、2 项原有跳过、零失败，`build/CloudHandoffFix/native-regression.log` 以 TEST SUCCEEDED 结束；新增三项覆盖复用不调度、完成态空操作/待交接执行、后台协调等待期间 actor 读取仍可进入。最终删除重复重绑 helper 后，暂停任务重绑测试改走实际交接发布路径，另跑 TextLayout 定向回归。签名诊断 Release 构建通过（`diagnostic-delivery.log`），codesign 深度严格校验通过（`signature.log`）；编译条件为 READER_OPEN_DIAGNOSTICS，启动不带 benchmark/变体/延迟参数，默认功能与正式包一致。

最终 TextLayout 93 项零失败（`build/CloudHandoffFix/handoff-final.log`）。2026-10-13 已保留数据覆盖安装诊断 Release 到 iPhone 13 并启动成功，devicectl 记录在 `device-install.log`、`device-launch.log`。构建产物：`build/ReaderOpenFocused/DerivedData/Build/Products/Release-iphoneos/Moonread.app`。未安排专门点按、未再录 Instruments、未操作镜像、未清理设备数据、未提交或推送。用户正常日常试用；若仍闪准备扉页，直接读取现有 JSONL 分析，无需重新安装。随后已完成用户验收和正常签名 Release 安装，见本页交付条目。

## 首页启动稳定性基线（2026-10-12，修复前）

### 测量环境、方法与边界

- 独立源码快照：`/tmp/MoonreadLaunchHome-20261012`；复制时工作区 HEAD 为 `556a5bb412f6080d3390284cfd01af770f7b39b0`，含当时未提交改动，不能视作纯该提交构建。逐文件校验见 `build/LaunchHome/source-manifest.json`。后续 coordinator 修改不进入此二进制。
- 独立 DerivedData：`build/LaunchHome/DerivedData`；Rust 构建输出也在快照内独立存放。Nix 工具链，Release、`-O`，未启用 DEBUG 测试夹具或 reader benchmark 入口。`build-final.log` 确认构建成功；首轮因快照遗漏图标资产失败，补齐原资产后重建成功。
- 自建模拟器 `Moonread-LaunchHome-20261012`，iPhone 17 / iOS 27.0。这不是 iPhone 13 的性能等价环境，也不是用户已有模拟器。
- 普通应用入口、中文系统参数；未登录 iCloud，未启用云同步。先录首次安装启动，再在此模拟器的应用容器离线写入合成数据：393 个本地 TXT（含应用自带欢迎小说）、392 个合成正文索引、3 条最近阅读、787 条元数据字段、3 张 320×448 纯色 PNG。无用户小说或个人数据。**393 个文件不等于 393 条最近记录，也不模拟云端未下载文件。**
- `populated-cold` 首次生成缩略图；后续 `populated-relaunch-*` 为终止进程后重启，缩略图磁盘缓存已存在；`populated-foreground-*` 为切到 Settings 后恢复同一 PID，分别为 92056、93264。这里“冷启动”指新进程，不声称清空了操作系统页缓存或每次重启模拟器。
- `capture.py` 用 `simctl io recordVideo` 录制，`simctl launch` 启动。首组启动后观察 8s，补测组 15s。这不是桌面手指 tap 测量；命令往返及宿主负载不计入本地查询耗时。
- 用 ffprobe 的逐帧 `best_effort_timestamp_time` 标时，解码所有实际帧核对变化。录屏是变帧率，标称帧率不可作时间基准；静止尾部可能不编码，接触表末尾补白不是应用白屏。`*-frames.json`、`observed-events.json` 留下帧号和 PTS；`*-boundaries.png` / `*-toolbar.png` 是变化边界接触表。目视首帧判断约有一个采样帧误差；淡入期间的“首次可辨”还受对比度影响。
- 以下进程启动统一用 **H0：首次可辨首页导航/底栏的帧**，仍可能有启动图案覆盖。另记图案消失、封面完成、转圈消失，避免把淡入开始当作完全就绪。原视频前方的 Settings、系统切换和黑色过渡不归因于 `LibraryView` 空数据。
- 没有内部 signpost，因而没有测得 `themes.load`、SQLite/SwiftData 查询、图片解码各自的精确执行时长，也不能由转圈持续时间反推扫描耗时。此次直接测得的是**屏幕可见就绪时刻与分阶段暴露窗口**。本地工作在 H0 前已开始，其总执行时长不能由下表推得；不得把 440–468ms 宣称为完整 launch→localReady 延迟。

### 逐帧可见变化

#### 393 本、首轮生成缩略图

视频：`build/LaunchHome/populated-cold.mov`。H0 = PTS 9.230s，帧 148。时间均相对 H0，括号为原始帧号。

| 时间 | 画面变化 | 原因及源码证据 | 数据性质 |
| --- | --- | --- | --- |
| 0 起 | 启动图案与背景渐退，首页导航、底栏开始透出，列表尚空 | `App/MoonreadApp.swift:94,160–193`，遮罩只看 `themes.loaded || themes.error != nil`；正常淡出设置为 0.25s | 主题已有同步缓存，随后本地主题读取；动画不能代表书架已就绪 |
| +117ms（156） | “我的书架 / 393 本·本机”行出现，位于页面上方；无最近阅读 | `Library/LibraryModel.swift:149–152` 在等待 recents 前已经赋值 shelves；`LibraryView.swift:55–64` 立即显示 | 本地 SQLite 保存的书架与计数 |
| +370ms（169） | “继续阅读”及首本标题/章节/6.4% 进度、“最近阅读”两本、“查看全部”及“书架与文件夹”标题插入；原书架行整体下移 | `LibraryModel.reload` 第二次赋值；`LibraryView.swift:34–61` 的条件 Section 和条件 header | 本地阅读位置、元数据、索引投影；本轮不依赖云端 |
| +377ms（170，约） | 中心启动图案不可见；此时仍是文字封面 | 遮罩与系统窗口过渡结束时刻以实际帧为准，不能机械地将 0.25s 加到某个查询结束点 | 过渡显示 |
| +450ms（176） | 最近阅读中蓝色封面先替换文字封面 | `Books/BookMetadata.swift:97–119,226–230`，挂载后的订阅读取/生成本地缩略图 | 本地资源 |
| +468ms（177） | 首本红色与另一本绿色封面也已显示，三个封面全部完成；行边界未移动 | 相同加载路径；`LibraryView.swift:119,145` 固定 60×84、44×62 | 本地首屏完整可见 |
| +515ms（180）至 +1750ms（211） | 导航栏出现小转圈、旋转、消失；标题、计数、排序、章节和封面保持一致 | `PageLoadingOverlay` 有内容时延迟 300ms 显示；`LibraryModel.load/refresh` 的后续扫描及 reload | 后台本地文件系统一致性检查；未观测到云端数据变化 |

进度条在最近阅读首次可辨时已是 6.4%，此样本没有发现其随后从 0 动画增长。状态栏前景色在系统窗口/主题过渡中也发生白→深色变化；不属于书架数据刷新。导航转圈增加了可见活动，但本轮没有观察到其挤动“+”按钮或列表内容，不把“可能改变 toolbar 布局”写成已发生事实。

#### 缓存缩略图的两次进程重启

行为顺序相同，具体帧如下；数值为相对各自 H0 的毫秒。

| 视频 | H0（PTS / 帧） | 书架行 | 最近阅读/标题插入 | 启动图案消失约 | 首本及全部封面 | 转圈开始 → 消失 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `populated-relaunch-1.mov` | 7.265 / 151 | 78（156） | 318（171） | 323（172） | 450（181） | 450 → 1752（203） |
| `populated-relaunch-2.mov` | 5.388 / 124 | 127（134） | 330（147） | 395（152） | 440（156） | 703（157）→1617（176） |

首次最近阅读显示到首本封面显示分别约 98、132、110ms（三次样本）。这是订阅建立、服务等待、读盘/缩略图工作和呈现的合计窗口，不能单独归因于图片解码。不同轮次图案透明度并不严格按一个理想曲线变化，系统过渡与主线程调度均可能影响呈现；无 trace，未进一步归因。

#### 首次安装、没有既有用户数据

视频：`fresh-install.mov`，H0 = PTS 8.663s / 帧 206。

| H0 后时间 | 可见变化 | 对应原因 |
| --- | --- | --- |
| 0 起 | 图案开始退场，显露空首页与导航/底栏 | 主题先就绪，library 尚在准备 |
| 约 +93ms（217） | 中心大转圈透出 | `LibraryView:29–30` + `MoonView:119–129`：无 shelves 时立即显示 loading |
| 约 +227ms（232） | 启动图案消失，只剩空列表与转圈 | 启动遮罩未等 library |
| +373ms（242） | 中心转圈消失，“我的书架 0 本·本机”出现；导航转圈短暂出现 | `prepareLibrary:101–127` 建目录、复制欢迎小说、注册书架；初次 reload 尚未完成文件扫描 |
| +397ms（244） | 导航转圈消失 | loading request 完成或更换；不等于全链扫描已经结束 |
| +515ms（252） | 计数 0→1 | 后台扫描将已复制的欢迎小说纳入索引，再 reload |

后续帧未见应用内容变化；系统底部 home indicator 后续淡出不算 library 更新。首次安装的“0→1”是真实索引更新，但原文件是本次自己复制的已知本地文件，产品上没有必要先对用户展示一个暂时的 0。

#### 同进程热恢复，两次

视频 `populated-foreground-1.mov` / `populated-foreground-2.mov`。恢复没有重新展示 MoonLaunchCover；进入系统 app 切换画面时，已有标题、阅读位置、三张封面和 393 计数均在（接触表不晚于 PTS 0.833 / 0.807s 已能看见）。切换窗口扩大到全屏属于系统过渡，未见应用内部 Section 插入、计数变化或封面回退。

| 轮次 | 唯一新增应用活动 | 消失 | 持续 | 其他变化 |
| --- | --- | --- | ---: | --- |
| 1 | PTS 1.542s / 帧 75，导航转圈出现 | 2.005s / 帧 92 | 463ms | 系统窗口与状态栏完成过渡，home indicator 后续淡出 |
| 2 | PTS 1.427s / 帧 82，导航转圈出现 | 1.803s / 帧 101 | 377ms | 同上 |

代码入口是 `MoonreadApp.swift:44–45` 的 scene active：恢复 import、`library.refresh()`、`cloud.refresh()`。观察期间没有新增文件或阅读位置；不能从“画面没变化”推出没有查询、解码或重新发布。


### 本地证据索引

产物均在忽略目录 `build/LaunchHome/`，未提交录屏/合成数据：

- `build-final.log`、`source-manifest.json`、`fixture.json`：构建与样本来源。
- 六个 `.mov`：`fresh-install`、`populated-cold`、`populated-relaunch-1/2`、`populated-foreground-1/2`。
- 同名前缀 `*-host.json`（命令时钟/PID）、`*-frames.json`（逐帧 PTS）、`*-frames/`（解码帧）、`*-boundaries.png` / `*-toolbar.png`（边界接触表）；`observed-events.json` 为人工核对事件。
- `capture.py`、`seed.py`、`analyze_frames.py` 为本轮独立测量脚本，不进入应用构建。模拟器保留用于复核，无后续后台测量任务。


这些是旧版本的视觉暴露窗口，不是当前启动耗时。没有内部 signpost，主题、书架、最近和首图各自耗时及 rootTask→localReady 仍未单独量得；三次样本不报告 P95。现行规则见[首页](../design/library.md#本地首屏与后台刷新)。

## SHA 旧首屏代理指标的分段复核（2026-10-12）

### 测量口径

iPhone 13 / iOS 27.0.1 / Release，已下载、预建快开缓存、隔离用户存储、关闭后台云书架更新。每本每组 6 个有效打开，ABBA 顺序，共 24 个；不剔除首个较慢样本。A 为旧快开，B 为额外原始 SHA 后仍走旧快开查找，并非正在实施的新索引的完整验收。

补丁 `SHABenchmark.run` 在 `SHAProbe.begin` 后设置 `source`，`SHABenchmarkView` 新建根阅读页。ReadingView 的 `onAppear` 强制设置 `showingCover = false`，然后启动 display-link，第二回调记 `presentedFrame`。这个额外封面状态变化可能触发布局；指标既不是完整动画结束，也没有证明文字已经上屏。

由 `run-cancel-active.json` 的每个样本先相减、再取中位数（jaq 只读汇总），单位 ms：

| 埋点区间 | 大书 A | 大书 B | 小书 A | 小书 B | 可以支持的解释 |
| --- | ---: | ---: | ---: | ---: | --- |
| begin→readerTask | 22.2 | 22.6 | 23.3 | 22.9 | 测试宿主创建、SwiftUI 调度；不是 tap/push 时长 |
| readerTask→readerOpened | 47.2 | 46.0 | 45.0 | 47.4 | settings、创建任务/lease、统计启动、actor 往返的总和；不是 ReaderSession 构造函数时间 |
| readerTask→sourceLookup（上项子段） | 39.5 | 37.8 | 36.2 | 39.0 | settings 与 actor/任务调度待拆，不能直接归为字体或 SwiftData |
| sourceLookup→sourceLocated | 5.0 | 5.0 | 4.8 | 4.9 | 源行、书架、bookmark 元数据读取 |
| sourceLocated→accessor | 11.0 | 10.9 | 10.9 | 11.1 | 创建 import、队列等待、解析授权和协调访问的混合区间 |
| accessor→cacheHit | 3.3 | 21.3 | 3.1 | 14.4 | B 包含 SHA；cacheHit 在 reuseImport **之前** |
| cacheHit→viewAppeared | 174.1 | 145.7 | 173.9 | 155.1 | reuse、下一次快照、用户投影、window 发布与 UI 调度，不能全算轮询 |
| viewAppeared→presentedFrame | 85.2 | 75.1 | 78.5 | 72.2 | 封面切换、布局、主线程/显示调度；不能直接称为正常两个刷新周期 |
| begin→presentedFrame | 340.6 | 318.1 | 329.9 | 319.9 | 原始首屏代理指标 |

区间有包含与并行关系，各列中位数不能相加还原总中位数。B 的 SHA 中位数分别 17.917/11.496ms；B 总时间更短不代表 SHA 加速。`readerOpened` 只表示 `open()` 返回，监测 Task 刚启动，正文此时不保证可读。



来源：`build/LibrarySHA/results.md`、`run-cancel-active.json`、`instrumentation-final.patch`。此宿主绕过书架文件准备与真实 push，不能把结果解释为系统导航固定耗时。

## 快速重开早期事件与非复现 trace 的边界（2026-10-13）

依据：[单书投影](performance.md#单书投影与保存)、[开书关键路径](performance.md#开书关键路径)、[慢开书展示](../reader/import.md#慢开书展示与会话契约)，以及 `build/ReaderOpenRealDiag/` 的原始事件与已导出的采样。复核了 `events-after.jsonl` 的最近七次 attempt、`new-events.json`、`time-samples.json` 和两份分析，没有重新录制 trace。

| 证据 | 实际观察 | 不能据此得出的结论 |
| --- | --- | --- |
| 真实快速重开六次，B75BDBEA、A03A163B、BD02857B、71E95F97、A8C497E0、AC8FCF3F | 三次 `frameRequested→windowPublished` 为 551–561ms；另三次 `activityStart→activityStarted` 为 530–535ms。reuse 在 tap 后 45–98ms，正文 display 机会在 675–747ms | 这些是 await/调度/恢复的跨度，不是已证明的 CPU 执行时长；不能断言一次全库投影实测就是半秒 |
| 同六次显示状态 | push 完成约 547–577ms，扉页展示后 15–49ms 就出现 `readingFade`；window 到布局完成仍有约 57–68ms | 推迟扉页门槛可以藏掉闪烁，但不会解决等待。不可把取消 200ms fade 当作必省 200ms：现有 display/opaque 代理事件没有独立证明完整光学淡入时长 |
| trace 对应的新 attempt 9761B43D：首页继续阅读，非原小说目录快速开关入口 | 文件可用 67.6ms，sessionOpen 172.6ms，settings await 96.2ms；frame→window 12.8ms；window 310.2ms、布局完成 448.7ms、正文机会 592.9ms、push 完成 731.8ms；未展示准备扉页 | 不能用这一次“没有停顿”的首页样本否定原六次问题，也不能将 138.6ms 的 window→layout 间隔全算为排版 CPU |
| `real-open-ui.trace` / `profile-analysis.md` | 126.4s Time Profiler，含等待线程；无 >250ms potential-hangs。候选 56.65–57.70s 窗口中 `ReadingController.rebuild` 有 20 个 inclusive 样本，`effectiveQuery` 有 4 个。ReaderService/SwiftData 投影可见于后台线程 | trace 缺 ReaderOpen 类别的精确 signpost 对齐；不能用 inclusive 权重当阶段时长，也不能把“后台线程”理解为不影响 actor 上的新读取 |

因此，旧方案中的“393 本一次投影约半秒”是**当时未证实的推断**。当时基线 `106465c` 的 snapshot/frame/recent 全库投影是合理优化对象；这些样本不足以把整段 530–560ms 唯一归因给它。事件的 `variant=both` 也不独立证明统计串行开关或二进制版本，比较时必须记录包的提交和参数。

本轮的预期收益应表述为：若全库投影/收尾竞争是主因，可消掉异常样本中数百毫秒的排队，恢复到正常快开轨迹；不是保证每次都减 550ms。SHA、会话、排版、push 相互重叠，下面的收益不能相加。



后续 focused trace 已定位云交接协调读取，见本页“真实开书等待定位与云交接修复”。本节保留早期证据限制，不再将全库投影当作已证实的半秒根因。

## AIStageOne 历史断言审计（2026-10-13）

以下为修正前的独立审计，行号和“当前”均指基线 `106465c`；随后测试修正及通过结果见本页“AIStageOne 测试契约校正”，不将历史失败写为仍未修复。

2026-10-13。审阅基线 `106465c`；相关 AI 源码和测试在审阅时无工作区差异。只读 git 历史、代码、现行契约及验证记录；未构建、未使用任何 DerivedData、未访问手机、未修改源码或测试。

### 结论

支持按现行契约修正测试，不需要为这些断言恢复旧 AI 行为。但原因需分清：

1. 两处未发送会话重载的 `XCTAssertNotNil` 是**测试在异步改造中改错**。首次发送前不创建历史的契约在最初 `db46f01` 已存在，当时这两处本来就是 `XCTAssertNil`。
2. 显式添加附件后仍与调用方附件完全相等，是 `c2bcac5` 引入独立出现项后**遗漏更新的旧断言**。应比较实际草稿 occurrence，而不是恢复调用方 id。
3. `testUnifiedSelectionDraftValidationAndSaveTargets` 还有一处：无效 `defaultThinking` 期望回退 `medium`，与从最初提交起就存在的 `defaultThinking` 实现不符。它不属于草稿生命周期问题，应单独修正并保留合法默认/非法显式选择的覆盖。

这三项共对应四处静态不一致。没有发现这些失败所指向的 AI 源码回归。**不能只删断言或把附件比较降为 count；需要保留发送后持久化、请求参数一致性和隐含上下文不泄漏的验证。**

证据限制：`docs/dev/engineering/verification.md:401` 记录了 3 个用例、4 处失败，但指向的 `build/search-refresh-native.log` 已不在当前工作区。本轮没有重跑，因此以下四处定位来自当前及历史源码逐步推导；没有声称从原失败日志确认全部行号。

### Git 时间线与意图

以下时间为仓库提交时间（UTC+8）；历史是合并提交粒度，不能由它还原提交内部每次编辑的先后。

| 提交 | 已核实的变化 | 对本次失败的意义 |
| --- | --- | --- |
| `db46f018ea7afd609b460822c941f74dc86743f2`，2026-10-04 22:45，suxiaoshao，`feat: 接入 AI 阅读助手、多供应商与原生工具服务 (#4)` | 三个测试及 `AIModelSelection.defaultThinking/select` 已存在。提交说明写“首次发送才保存对话”；当时 `design/ai.md:53` 已明确首次发送前输入和模型选择仅内存保留。`create` 放入 pendingConversations；未保存会话不会进入持久 records | 两个 picker 测试此时都是 `reloaded.load(); XCTAssertNil(...)`。不能说后来产品从“持久化未发送对话”改成内存才令它们失败 |
| 同一 `db46f01` | 当时显式附件按 kind/bookRef/fileRef/objectRef/range 去重，append 原附件，保留调用方 id；`ai.md` 写同一对象避免重复 | `saved.last?.readingAttachments == [attachment]` 对旧添加逻辑合理 |
| 同一 `db46f01` | `defaultThinking` 只接受模型支持列表里的声明默认值，否则 nil；切到不同 modelID 会使用该默认。测试已写无效默认时期待 `medium` | 测试与实现的矛盾从仓库可追溯的首次引入即存在，没有找到后来移除“取第一档”回退的提交。提交整体通过报告不能证明这一具体分支当时确实通过 |
| `c2bcac55018d396e721c1bb905171e45f85912f2`，2026-10-07 00:02，suxiaoshao，`完善 AI 模型管理与阅读业务任务 (#6)` | 统一 repository/runtime，`create` 构造 `persisted=false` 内存对象；首次 send 才 `repository.create`。提交说明明确“所有未发送文字与附件只留内存”。文档第 84 行扩展了本次阅读选择、已发送会话的后续草稿等边界 | 两处测试随同步→async API 改造从 `Nil` 改成了 `NotNil`，与同提交意图冲突，是测试回归；现行 `testUnsentConversationsStayInMemoryIncludingSelectionAndAttachments` 反而明确保护正确行为 |
| 同一 `c2bcac5` | `addReadingAttachment` 为每次显式添加生成 UUID；文档新增第 82 行“独立出现项”，第 63 行取消去重语义；增加显式 occurrence 测试 | 有意改变附件身份契约。旧 saved-array 比较未更新，并非保存阶段意外篡改 id |
| `c53f41b9cbee7732c7ff5584571ad62906e03db5`，2026-10-07 20:16，`Improve search, refresh, and reader navigation` | 验证记录第 401 行记录失败；该提交版本的 Unified 测试仍保留上述矛盾 | 此轮搜索/刷新不是这些静态不一致的引入点。后续至当前 HEAD 这些关键断言仍未修正 |

复核依据：`git blame` 的测试 869/965 行指向 `c2bcac5`；1211 行附件全等、886 行 invalidDefault 期望及选择器核心 7–13 行指向 `db46f01`。用 `git show db46f01:<path>` 与 `git show c2bcac5 -- <path>`核对了修改前后，未仅凭最后一次文件提交时间归因。

### 逐个断言与建议

路径均相对 `ios/MoonreadTests/AI/AIStageOneTests.swift`；行号以审阅基线为准。

| 用例 / 行号 | 当前断言及前置状态 | 契约对照 | 决定 |
| --- | --- | --- | --- |
| `testPickerEffortDisplaySaveAndRequestAgree:965` | create→选择 low→另建 AIService/load，期待未发送 conversation 非 nil | `design/ai.md:84`：首次发送前没有历史；`AIService.create:267–275`、`selectRuntime:485–490` 只改内存 head | **改测试为 nil**，原 service 的 low 选择仍须保留。不能改 create 或 selectRuntime 使它提前持久化 |
| `testUnifiedSelectionDraftValidationAndSaveTargets:869` | create→应用第二连接 medium→reload，期待会话存在 | 同上；会话配置与全局默认是不同保存目标，`ai.md:395` 要求两者独立 | **改测试为 nil**；保留内存选择、默认未变化及 defaults 明确保存后的重载断言 |
| 同用例 `:886` | 新 modelID `invalid-default`，支持 `[medium]`，声明默认为 `invalid`；期待 medium | `AIModelSelection.swift:7–13` 明确返回 nil。`ai.md:395,423` 支持“按真实资料、不猜测补值”的方向，但没有逐字规定非法 default 的回退算法；不能称第 82/84 行规定了这个 nil | **改测试为 nil**，以已有默认选择算法为依据。追加合法 default=medium 的对应断言，保留显式 unsupported 被拒绝的断言。不为了修测试凭空增加“第一档即默认”的产品规则 |
| `testReadingAttachmentsPersistRemovalAndDoNotLeakFixedContext:1211` | 显式 add 后发送，期待保存数组完全等于传入 `[attachment]` | `ai.md:82` 每次显式添加是独立出现项；`AIService.swift:429–434` 在 add 时生成新 id，其余字段复制 | **改测试比较 add 后捕获的 occurrence**。应验证它 id 不同于调用方、持久化后 id 不再变化、其余字段完整，不只比较数量或忽略所有 id |

附件测试的 `:1199 XCTAssertNil(restored.conversation(...))` **已经正确，不应反转**。它证明未发送会话不存在，不证明“跨进程保留未发送附件的移除状态”。跨进程本来就应清空草稿；同一内存会话的手动移除由 `seedReadingDraft→remove→seed` 及空数组断言保护。

### 更新测试时必须保留的风险覆盖

##### A. 思考档位：显示、保存、请求三者一致

`testPickerEffortDisplaySaveAndRequestAgree` 应保留现有 `conversation.thinking == low`、picker selection low、请求 JSON `reasoning.effort == low`、turn.thinking low，以及无可调档位时三处都 nil/不发送 effort 的断言。

仅将 reload-before-send 改 nil，仍缺少“保存”半边的明确断言。建议在首次发送提交并完成后，再创建读取服务 load，验证会话存在、head selection/thinking 为 low，和之前捕获的实际请求一致；在改为无思考档位并发送第二条后，再验证持久 head 的 thinking 清除。比较历史 turn 的配置仍为该次请求配置，不能被后续选择覆盖。

无需用新建 `AIService(repository:defaults:)` 发送真实请求：该构造未注入 fixture 的 URLProtocol/auth。可以继续由原隔离 service 发送和捕获请求，只让 reloaded service 验证持久化；如果确需从重载实例发请求，应注入相同离线 transport 与凭证 fixture，禁止测试意外联网。

等待发送实际结束/持久化可读后再重载；不要用固定 sleep 代替提交完成。现有 completed 条件和 repository/head 读取可配合，不把新服务查不到正在提交的记录误判为错误。

##### B. 两个保存目标与非法值

`testUnifiedSelectionDraftValidationAndSaveTargets` 继续覆盖：编辑 draft/取消不影响原选择；会话选择不改全局；defaults 显式提交后可重载；非法显式 effort 返回 false 且不污染旧值；无思考能力没有档位。

增加或借用同组发送后持久化检查，核对 connectionID、modelID、thinking 三项而非仅 `conversation != nil`。新会话不持久化的断言不能代替已发送会话选择应持久化的断言。

对 invalidDefault 可用两个紧邻情形防止过度放松：非法默认→nil，合法 medium 默认→medium；这样即使未来有人让所有默认都变 nil，测试仍会失败。已有 `testRunningModelSelectionAppliesOnlyToNextRequest` 继续保护运行中改模型只影响下一请求，不因本轮改断言删掉。

##### C. 附件：发生项、移除、持久消息与系统上下文

推荐保留并增强现有流程：

1. 入口 seed 原附件→按该 id 移除→同一会话再次 seed；仍为空，防止入口注入复活用户已移除项。重载未发送会话应不存在。
2. 发送普通文本；捕获真实请求，不含旧固定 context 的独有标题，也不含已移除附件的独有标题；持久化第一条 user 的 attachments 为空。
3. 显式添加原 attachment；立即捕获实际 `readingDraft` occurrence。断言 id 与输入不同；把输入的 id 替换成 occurrence.id 后做完整 Equatable 比较，或逐字段比较 kind/origin/capturedAt/bookRef/title/range/excerpt 等，验证只有 occurrence 身份变化。
4. 发送后从 repository 读取 user 消息，完整比较保存数组与步骤 3 的 occurrence；通过另一个 AIService load 或同 repository 新读取接口确认已发附件可恢复；草稿已清空。保留首条空附件，证明后一次 add 没回写旧历史。
5. 保留请求含显式附件标题与 projection 含精确 range 的检查，补充第二次请求仍不含旧固定 context 标题；不要只检查首条请求。`AIAgentRuntime.swift:206–207` 会把 input.readingAttachments 投影到 user 消息并保存原数组，此处需要完整契约覆盖。
6. 同一对象显式 add 两次时，两个 occurrence 的 id 不同、内容相同且顺序保留；移除其中一个只删除该项。已有 `AIFollowUpTests.testCurrentCoverDraftOwnsStagedValueAndExplicitOccurrences:585` 覆盖内存中的图片 occurrence，可复用；如给本阅读附件用例增加第二项，发送后再核对剩余 occurrence 即可，不必重复大套 UI 测试。

“移除附件持久化”准确含义是：**同一草稿内移除不会被重新 seed 覆盖，发送时移除结果进入持久 user 消息，之后历史不能被草稿修改**。不要求把未发送草稿或它的移除动作另存成数据库记录。

现有 `testUnsentConversationsStayInMemoryIncludingSelectionAndAttachments:238`、首次提交失败保留草稿 `:284`、提交中不可编辑和已发送会话的新草稿重启清空 `:303` 附近也应保留。它们覆盖有意契约，不能为了旧断言转绿恢复草稿落盘。

### 是否需要修改 AI 源码

本次四处静态不一致均可由预期错误解释；相关路径所见实现与现行契约一致，**没有定位到必须修 AI 源码的回归**。这不等于全 AI 模块无缺陷，也不代表更新测试已运行通过。

协调者可以只更新相关测试，但应按上文保留实质断言：未发送为空、已发送可恢复、occurrence 精确保存、请求 effort 与选择一致、移除项和固定页面 context 不偷偷发送。若更新后这些保留/新增断言仍失败，再按具体源码路径定位；不能继续删弱断言以通过。

本轮未产生测试运行结果；原日志缺失和四处静态定位的边界应在交付说明中保留。无需改第 82/84 行契约，也无需为旧开发版持久草稿增加兼容分支。

## 开书云交接修复验收与正式交付（2026-10-13）

- 用户在 iPhone 13 日常试用云交接修复后的诊断包，反馈“现在快了很多很多，几乎是秒进，是速度提升最快的版本”，本轮开书体验验收通过。这是用户体验结论，不换算成统一毫秒 SLA。
- 正常签名 Release 构建成功，`SWIFT_ACTIVE_COMPILATION_CONDITIONS` 清空、关闭 `READER_OPEN_DIAGNOSTICS`；`codesign --deep --strict` 通过，二进制无诊断字符串。保留数据覆盖安装 iPhone 13 并启动成功。证据目录：`build/AcceptedReaderRelease/`。本条由协调方补充交付事实，文档整理未重新构建或操作手机。
- 根因：focused trace 中 revision 请求入队→actor 开始约 520–550ms；等待栈为 `scheduleCloudLibraryUpdate → updateCloudLibrary → publishCloudHandoff → refreshLibraryShelf → NSFileCoordinator` 协调读，由每次 `importFinished`（包含快开 reuse）触发。同步协调 I/O 占住共享 actor；执行 revision 本身很短，等待权重不能当 CPU。
- 协调方补充修复后单书 projection+frame 约 7–14ms，formal fetch 中位 1.4ms、queryBuild 中位 2.9ms。与此前“393 本全库投影约半秒”的未证实推断分开；各阶段中位数不相加代表总耗时。
- 云交接路径在 testSession、模拟器和基准中关闭，因此此前自动化与模拟器未能复现这条真实竞争链。以后先核对实际构建开关、入口和云状态，再用短 trace 对齐排队、执行及呈现。
- 开书体验通过不自动覆盖真实双设备 CloudKit、所有提供方、长时阅读或首页全部超时/附件迟到场景，原有验证缺口继续有效。

## 月亮角色验证（2026-10-10）

- 构建：iPhone 18 Pro 模拟器（iOS 27.0）`build` 通过。
- 状态与显隐：`AIReadingMoonTests` 7 项通过，覆盖开书基线不重播、完成 2 秒后不保留、完成·待查看与未完成保留到打开对话、等你确认 6 秒后隐藏且操作层再次显示、停止与对话打开期间无提示、关闭对话时提示当前工作、工具族映射与并行优先级；`AIStageOneTests.testCompletedConversationDraftAndRestartInterruption` 改为断言任务结果本身。
- 画面：`MoonCharacterRenderingTests` 用生产视图在模拟器渲染全部 11 个姿态，浅/深阅读主题 × 40pt 月面与 120pt 放大 × 静止关键帧与 0.5s/1.0s 动画帧；人工检查 40pt 下各姿态可区分。`testAIReadingMoonCloseReopenAndConversationTab` 通过，截图确认阅读页 40pt 静止月亮、拖动后位置与对话列表空态月亮。
- 图标：`ictool` 导出 Design Generation 26、27 的 Default、Dark、ClearLight、ClearDark、TintedLight、TintedDark 共 12 种组合，书在月亮图层之上；另检查 180/120/87/58px 缩小效果。
- 未验证：真实服务下的连续工具事件与通知节奏、真机、应用内减弱动态开关下的实机画面（静止帧由渲染测试覆盖）、阅读深色主题的实机截图（UI 测试会话的阅读主题未跟随模拟器外观）、长时运行功耗。

## 封面页面提取的检查口径

以下是检查项和证据分层，不是追加运行结果；已有结果见本页“查找封面页面图片”。

### 封面页面提取回归清单

**Rust 单元测试**：fixture HTML 写在测试里，不使用真实网站页面全文。

- og:image 的绝对和相对 URL。
- `<base href>`，以及重定向后以最终响应 URL 解析相对图片地址。
- twitter:image 与 og:image 重复时去重。
- 查询参数原样保留。
- JSON-LD：
  - 字符串、数组和顶层数组
  - `@graph`
  - `ImageObject.contentUrl`
  - 深层嵌套触发深度保护
- `src` 为 `data:` 或占位图、带 lazy 属性时，选用 lazy URL，计数正确。
- 空白或 nil 书名不触发 alt 匹配；GB18030 页面中按书名匹配 alt。
- 声明位于 2 MiB 截断点之后的图片不会被提取。
- 多个 `<base href>` 时采用第一个有效项；相对 base 按 response_url 解析。
- 相对 lazy 地址（`/covers/a.jpg`、`//cdn.example/a.jpg`）被采用。
- 无候选、HTML 畸形、`data:` URL。

**Swift 测试**：扩展 `CoverFetchURLProtocol` fixture。

- 页面 → og:image → 候选，`origin` 为原始搜索 source。
- 页面重定向后，相对图片地址按最终 URL 解析，sourceRef 不变。
- 派生资源是 HTML 时不再递归提取。
- 图片 404 或无法解码时没有候选，也不报错。
- 直链图片路径保持原行为，并经过尺寸筛选。
- 尺寸边界：
  - 短边 99/100px
  - w/h 为 1.2 与略大于 1.2
  - 方形图片能通过
- 候选：
  - 同一次调用内按 URL 去重，保留查询参数和首次来源。
  - 达到 8 个合格候选后停止。
  - 不合格的不计入 8 个。
- Referer：初始请求的同源、跨源和 HTTPS→HTTP 三种情况。
- 暂存清理：
  - 取消发生在 save 之后、进入 candidates 之前时，该资产被清理。
  - 已有候选后取消或调用失败时，本次调用的全部暂存资产（含已在 candidates 中的）被清理，其他调用和已提交的资产不受影响。
  - 正常成功时，返回结果中的资产保留，未选入的被清理。
- Referer 重定向：
  - 同源图片重定向到跨源 CDN 时，那一跳只带页面 origin。
  - 图片从 HTTPS 重定向到 HTTP 时，那一跳不带 Referer。
- 未被页面声明的 URL 不会被请求。

### 封面页面提取证据分层

按 AGENTS.md，以真实场景验收，不以测试通过宣告完成：

本次按用户确认的三层方式验证：

1. Rust fixture 与 Swift `CoverFetchURLProtocol` 验证解析、获取、筛选、取消和暂存。
2. 历史公开网页来源回放用于验证获取流程可行性，不等于 App 内真实搜索。当前公开回归改用原创离线页面与程序生成图片；不分发第三方封面或私人证据。
3. App 内端到端搜索及用户应用封面由用户之后用自己的账号验收。
- 记录每本书的信息：
  - 搜索来源数，以及其中直链图片与网页各几个
  - 提取出的图片 URL 数
  - 最终候选数
- 回放保存候选图片证据并逐张目视检查；App 内审阅页截图待用户端到端验收。
- 用户端到端验收时应用其中一个候选，确认书架和详情页的封面已更新。
- 结果写入 verification.md，未覆盖的站点和失败情况如实记录。

## 统计剩余验证的检查口径

以下为场景清单，不代表本轮已执行。跨设备独立事实累加，重复传输同 ID 去重，不做时间重叠扣除。

### 统计专项检查场景

| 范围 | 必须覆盖 |
| --- | --- |
| 静止与闲置 | 静止 90 秒正常计时；静止 10 分钟最多计 120 秒；交互恢复不补空闲；落盘/重绘不重置闲置 |
| 生命周期 | 锁屏、自动熄屏、控制中心、后台零累计；返回页面仍闲置时不误恢复；有可读正文的后台准备正常计时 |
| 阅读模式 | 滚动、分页、选字、重排、旋转、窗口交接同口径；工具/编辑器和设置预览不混入正文 |
| 临时查阅 | 搜索/书签跳到正文后按相同规则累计时间与覆盖，不更新续读和最近阅读；点击继续阅读不重算此前时长；仅查阅的书在统计中可见 |
| 页面与数据 | 顶部今日/本周、期间图表与书目筛选一致；两种排序准确；月历到当天到单书可追溯；零数据/慢查询/失败/暂停可区分 |
| 覆盖与回看 | 跳章不虚报中间；重复暴露不重复覆盖；离开后有效回看增加次数；局部交叠不把整屏算成又读一遍；章节修正与渐进完成可重算 |
| 保存与身份 | 强退不会续计整夜；重试幂等；同 SHA 多来源归一；新正文不继承旧覆盖；记录开始前的历史不伪造 |
| 日期与同步 | 午夜、时区、系统时间改变、跨设备重复/重叠、离线与删除传播；单机通过不能代替真实云端验收 |
| 产品体验 | 统计不拖慢长篇滚动；大数据列表有界；图表有可读数值、VoiceOver 和大字号布局；正文不常驻统计提示 |

自动化使用隔离测试库中的合成片段检查图表和查询，真实开书测试验证采集/重启持久化；正式应用不生成样例统计。后续真实阅读试用验证长时间行为和覆盖规则。若需要改变已定产品规则，先提出实际问题再讨论；测试通过不等于注意力测量准确。

## SwiftData 云端未完成验证范围

正式替换已完成，iOS 18 运行、真实双设备、账户切换/旧容器在途操作、附件迟到、长时后台导入仍以本页结果为准。以下检查清单不代表已验收。

### 云数据专项检查样例

按受影响范围完成构建和关键回归，交付试用；真实云验证未完成时明确标注，不以此阻止其他可验证工作，也不把新增小组件等规划混入本轮。

- 同一空评论高亮在两端扩展不同范围；不同评论；完全相同修改；多条合并同时另一端改旧条目。
- 删除与离线编辑、删除后撤销、收到远端修改后撤销；重复操作和进程中断不丢数据。
- 阅读事实分批保存、午夜、暂停/恢复、清理与旧设备重连；重复导入同 SHA 不多算。
- 同一模型涉及多条记录时，远端部分到达仍可打开页面，之后能够补齐。
- 本地/云开启关闭、重启、账户变化、来源不可用、封面尚未下载；不覆盖或删除外部小说原件。
- 长篇阅读期间后台保存/导入远端数据不移动正文、不阻塞主线程；测量实际开销后决定批量大小。

## 早期性能评审补充数据与范围（2026-10-12）

- SHA 升级前本机 M 系列对 23.5MB 输入比较：sha2 0.10 默认约48–68ms、0.11约9–13ms，摘要一致；这不是 iPhone 13 升级后的实测，首次导入还受解码/写库影响，不承诺同比加速。旧真机长书约77ms来自升级前记录。
- 旧真实入口六次 routeRequested→leaseCreated 约33–53ms，包含当时设置等候；另一个首页 trace 的约209ms含约96ms settings await。旧主线程布局约25–51ms，真实 window→layout 跨度含调度/挂载，不能全部当可迁到后台的 CPU。小书 raw SHA 约0.1ms不外推长书。暂缓收益估计见性能专题，均非新包实测。
- 早期 AI 流式身份迁移使 contentSize 1681→777、offset 到−146，约100ms恢复；非 lazy VStack 的 Release 主线程阻塞约1.3–1.6s、RSS650–880MiB，方案已否决；Lazy 估高范围1538–3731。后续稳定块、UITableView与Markdown测量见本页对应条目，不将这些旧数值当当前表现。
- 核心窗口 macOS 5/30/100MiB 输入的中位读取约105–108μs、P95约125–127μs；模拟器 Debug 原生48次窗口定位约2.52–2.61s/轮、峰值约39–40MB，仅短时基线，不能换算真机每次翻页保证。已复用滚动 coordinates，不能声称每帧重建。
- 规模评审没有测到100/500会话启动、10万facts统计、高频搜索结果总内存、393本冷封面解码或长时翻页的专项性能；这些保留为候选，不因未找到专项记录就断言从未优化。

以上迁自当时评审及阶段材料，整理本身未重新运行测量；原始数值的环境和限制保留，不追加新通过结论。

## AI 业务链路仍需覆盖的环境

会话列表分页和外部图片输入是未实现项，列在 roadmap；下列属于已有实现的验证边界，不要求重新全量审计：

- 正式签名应用的各实际账户/套餐：登录、Keychain、续期、模型目录、请求；合成协议成功、独立服务调用、手机安装不能互相替代。
- iOS 18、大字号与 VoiceOver 的实际朗读顺序/自动滚动、长对话缓存增长、长时阅读中的月亮与弹窗。
- 多书资料独立结果的 UI 使用、快捷任务运行中转入的真实供应商流程、统计分析生成后独立画面；已通过的定向场景按本页原记录保留。
- 真实跨提供方/跨卷整理；保留原件、字节校验、不覆盖、失败分阶段报告；不因本地 fixture 通过声称所有文件提供方成功。
- 原生搜索/生图/编辑按具体认证通道验证；封面本地来源回放与用户真机已通过的范围见对应条目，不由单一路径外推所有供应商。

### 第二轮用户反馈与后续边界

SHA 硬件后端及统计异步启动交付后，用户日常试用确认开书明显变快，但快速退出立即重开仍闪准备扉页；随后单书投影优化的本地测试通过也没有消除所有真实等待。后续 focused trace 定位云交接共享 actor 协调阻塞，最终用户验收见“开书云交接修复验收与正式交付”。保留这个顺序，不能把最后的通过倒写为各中间版本已经解决。

## 2026-10-13 PR #8 评审修复

文件已选解码策略改存 `library_files.decoding`（schema 18，无开发期迁移），任务回收不再丢失；新开与显式重新准备写入策略，快开继续使用原始 SHA＋策略。扫描及应用内移动、重命名保留该列。正常缓存启动先恢复持久化云根再早退；Debug/Release 共用正常路径，隔离书架/UI 夹具仍完整准备。首页增量最近阅读同时按文件 id 和 bookId 移除旧行。

Nix 核心 71 项通过、1 项原有 ignored，Clippy `--all-targets -- -D warnings` 通过；模拟器 TextLayout 96 项与 UserData 23 项共 119 项零失败，调用以 TEST SUCCEEDED 结束。新增无 BOM UTF-16 明确选择→回收→重开及位置保持、扫描/移动/改名/数据库重开、已存云根缓存早退不枚举、真实替换 TXT 后最近行唯一回归。证据 `build/PR8ReviewFix/{rust-tests,clippy,swift-regression-final}.log`。Release 单测目标依赖现有仅 Debug 的 AI 夹具接口，未把失败调用记为通过；实际正常早退分支已在上述模拟器单测覆盖。本轮没有操作手机。

## 2026-10-13 PR #8 下载与解码硬上限

封面来源和声明图片改用 URLSessionDataDelegate 在响应头及每个数据块到达时检查：声明长度超过 10 MiB 时拒绝响应，累计超限时不保留该块并立即取消任务，failure 原因为 too_large。未知长度仍受累计上限限制，受限取消不会误记为用户取消。ImageIO 先读取尺寸元数据，任一边超过 4096 像素即拒绝，不创建解码图像；尺寸不合格也在解码前过滤。Referer 每跳规则和调用取消/暂存清理契约保持。

模拟器 AIFollowUp 36 项＋AINativeTools 15 项共 51 项，1 项原有真实来源回放跳过、零失败，TEST SUCCEEDED。覆盖超大声明长度、无声明长度分块累计超限，以及小 PNG 头声明巨大宽度的解码前拒绝。日志 `build/PR8Limits/download-tests.log`。本轮未操作手机。

## 2026-10-13 PR #8 过程展开显式回调

删除 toggleAIProcessItem 的 EnvironmentKey/EnvironmentValues 闭包。列表控制器生成与行 id 绑定的 MainActor/Sendable 回调，显式经行渲染、AIMessageRowView 传到过程组及 reasoning 行，仍调用原 toggleProcessItem；展开状态、动画、锚定、辅助功能和工具详情行为不变。

模拟器原生 4 项（过程逐帧展开/收起锚定、运行/完成画面、失败显示、历史插入与 inset 保持）及 UI 整行点击/滚出回来状态保留 1 项均通过，调用以 TEST SUCCEEDED 结束。更新既有渲染和静态截图夹具以显式接收回调，无环境默认空闭包。日志 `build/PR8Limits/process-regression.log`；本轮未操作手机。

## 2026-10-13 Linux 轻量 CI

按所有者授权将 Actions 允许范围设为 all；回读确认 enabled=true、sha_pinning_required=true，默认 token 仍为 read 且 can_approve_pull_request_reviews=false。未修改分支保护、套餐或其他设置。工作流仅保留 Ubuntu 24.04 的 Linux checks，所有改动（含文档）运行 gitleaks、Rust/Nix 格式、actionlint、Clippy 和 Rust 工作区测试；iOS 构建、测试、签名和真机按本地改动范围验证。

本机 macOS arm64 的锁定 Nix 环境中：rustfmt、nixfmt、actionlint、全 target/feature Clippy（-D warnings）和 Rust 工作区测试通过；71 项通过、1 项原有 ignored。gitleaks 8.30.1 扫描 HEAD 可达的已提交历史，未发现泄漏，输出遮盖密钥。已有 nixpkgs 锁提供该工具，未更新 flake.lock。证据 `build/CILinux/` 下 checks、rust-tests、clippy、gitleaks 日志。本地通过不代替 GitHub Linux runner 的实际结果；本轮未运行 iOS 或操作手机。

## 2026-10-14 默认网格与首页最近阅读横排

iPhone 18 Pro 模拟器（iOS 27.0）运行受影响用例并通过：单元 `testLibraryLayoutDefaultsToGridAndKeepsAStoredChoice`（无存储时为网格，已存列表不被覆盖）、`testHomeSnapshotPublishesAtomicallyAndIgnoresInvisibleReloadChanges`；UI 首页常规与 AX-L 字号、网格跨目录与重启保持（新会话默认网格）、原生导航、选择删除、列表与网格下载进度、混排列表/网格。列表下载用例此前按首页 44×62 行断言，实际命中导航栈下层的首页行；现在首页为封面横排，改为断言目录列表 32×44 缩略图。首页截图核对封面横排、标题内边距与书架入口。日志 `build/grid-default-tests.log`、`grid-default-download-test.log`、`grid-default-home-test.log`。未跑全量 UI 测试；首页最近阅读查询由 3 条增至 10 条，大规模书架的冷揭幕耗时需真机确认。

真机反馈长按最近阅读的一本时整行一起高亮：List 把行内 `.contextMenu` 提升到整行。改为每个封面用 `Menu(primaryAction:)`，点按打开、长按只弹出该封面的菜单；下载进度覆盖层放在 label 外。`testHomeResumesFirstAndKeepsRecentsAndShelves`、`testHomeResumeFirstAccessibilityType` 通过（含“从最近移除”）。

## 2026-10-14 AI 结果卡片高度与选择封面

真机反馈两处：应用资料后结果卡片上下被裁；“选择封面”打开为空且无法应用。卡片：结果卡片随 `AIProposalRegistry` 状态变高，但行版本不变，高度缓存仍是旧值。`AIMessageList` 用 `onGeometryChange` 在高度变化时更新缓存并 `performBatchUpdates`，只作用于 `.result` 行，受保护更新与过程展开动画期间保留最新测量，收尾时补用；放宽到所有行时过程展开标题跳动约 48pt，已收窄。`testAIReviewChipTextAndRenameApplication` 新增应用后卡片不超出所在行的断言，修复前失败（卡片 minY 318 < 行 minY 373），修复后通过；`testProcessHeadersAreEntirelyTappableAndRetainExpansion`、`testOfflineMetadataTaskReviewAndApply` 通过。选择封面：与资料审阅一致，sheet 自行 `openResult` 加载审阅，加载中显示进度而非空白。模拟器 `testOfflineCoverTaskCandidatesSourcesAndApply` 修复前后都通过，真机空白的根因未在模拟器复现，需真机确认候选显示与应用。

PR #10 补测：结果卡片在 diffable 更新期间连续报告高度的最小用例修复前失败（最新 240pt，行仍为 76pt），修复后通过；指定的卡片应用、过程整行点击与展开保留、离线资料审阅应用三项回归均通过。只补用 `.result` 行测量，过程展开的高度、锚点与 CA 动画路径保持不变。日志：`build/AIResultResize/before.log`、`build/AIResultResize/after.log`。两次运行的用例均已输出结果，但 xcodebuild 随后卡在结果打包阶段，已结束本次测试进程；修复后四个用例控制台报告零失败，未取得完整 xcresult 或正常退出状态。


## 2026-10-14 最近删除阶段 0 试验

iPhone 13，iOS 27.0.1（24A446），签名 DEBUG 应用内临时探针；保留真实 entitlement、目录与安全作用域，不使用 testSession、不重定向应用目录、不清理设备数据。只创建并操作 `MoonreadTrashProbe/run-UUID/` 内的试验文件，不操作已有小说、不永久删除或清空“最近删除”。接口返回、Files 可见性和恢复结果分开记录。

| 本地 Documents 变体 | 接口结果 | Files 最近删除与恢复 |
| --- | --- | --- |
| TXT / direct / 空闲，`2D1F9770…` | 成功，trashItem 约 68.4ms；源消失，目标为 `Documents/.Trash/fixture-…txt` | 协调者经 iPhone 镜像看到可见；恢复报“无法完成此操作 / Nothing to process”；只读核对文件仍在 `.Trash`，原路径不存在 |
| 全新 TXT / direct / 空闲，`14365177…`，仅复测一次 | 成功，trashItem 约 66.1ms；源消失，目标仍为 `Documents/.Trash/fixture-…txt` | 用户手动看到可见；恢复再次报同一错误；只读核对文件仍在 `.Trash`，原路径不存在 |
| TXT / forDeleting 内嵌 trashItem / 空闲，`E2BD7CC4…` | 已进入外层协调 accessor 和 `trash.enter`，没有返回；10 秒看门狗触发，立即停止所有后续试验 | 未验证，不据此判为不支持，也不永久删除兜底 |

复测使用独立合成 TXT。`resultingItemURL.absoluteString` 是 file-reference URL，日志中的实际路径为应用数据容器 `Documents/.Trash/`；不能只按 absoluteString 推断废纸篓目录。本地 TXT 的结论是“接口成功且可见，系统 Files 恢复失败可复现”，不是可恢复性验收通过。

超时后尝试只附加当前进程取栈，未重启试验：xctrace 因设备就绪超时失败；LLDB 初次列为 disconnected，用户确认连接并解锁后能列进程，但原 Moonread PID 95414 已不在可见列表，未取得该次实际等待线程栈，也未查到 Moonread 崩溃报告。不能把看门狗栈、进程消失原因或死锁机制当成已证实。设计师随后确认正常启动后仅继续 direct，不再测嵌套协调；阶段 1 调用方式由设计师定为直接 trashItem，正式实现尚未开始。

真机中途试验已停止，剩余项目改为专用模拟器系统集成测试；阶段 2 再集中真机试用。未下载占位与扫描/导入并发已移到阶段 2 验收，本轮不做。iCloud 恢复失败或任何试验 IO 超过 10 秒时停止汇报。此前镜像导航及探针坐标点击被自动审批拦截，未绕过；真机复测由用户手动操作，日志与存在性由协调者只读核对。

证据在 `build/LibraryTrashProbe/`（不提交）：首轮 `local-first-events.jsonl`、`first-trash-presence.log`、`first-source-presence.log`；复测 `manual-local-repeat-events.jsonl`、`manual-repeat-trash-presence.log`、`manual-repeat-source-presence.log`；人工观察 `files-observations.jsonl`；超时 `timeout-events.jsonl`、`final-events.jsonl`、`timeout-lldb.log`、`lldb-connected-list.txt`、`processes-final.json`、`timeout-trace.log`、`moonread-crash-list.log`。阶段 0 临时探针、启动入口、导入 hook 与系统集成测试已丢弃；build 下证据保留，不提交临时代码。


B 线：专用 `Moonread Trash B - Dedicated`，iOS 27.0（24A434），无 iCloud 登录；真实 App Documents，不带 `--ui-test-session`，不重定向目录。串行系统集成 UI 测试 2/2 通过：TXT/direct 约 108ms、两 TXT 文件夹/direct 约 182ms，均进入 `Documents/.Trash/`、在 Files 最近删除可见；通过“更多 → 选择 → 仅选本次 fixture → 恢复”后，原路径存在。文件夹根书签删除后解析到 `.Trash/fixture-…`，恢复后解析回原路径，两次 `stale=false` 且目标存在。未触发 IO 看门狗。此前模拟器文件夹长按菜单的 Recover 曾报 Nothing to process，保留为另一操作路径的差异证据；未证明原因。模拟器通过不推翻真机恢复失败，也不代表产品验收。B 在实际测量前因安装异常按授权 erase 一次，测量开始后未重置。

B 线证据：`build/LibraryTrashSimulator/B-measured-results.json`、`attempt-6.xcresult`（2/2）、`evidence-index.json`、`probe-logs/final/`，此前长按失败记录在 `probe-logs/attempt-4/`。临时 DEBUG launch-argument 自动探针、JSONL 与无障碍完成值及系统集成用例已从源码移除，补丁与副本保留在 build 下，不提交。

C 线专用 `Moonread-LibraryTrash-C-iCloud`（iOS 27.0）与 B 分开；用户已完成 Apple 账户登录并确认开启 iCloud Drive。协调者未输入、读取或记录凭据；先以账户 token 存在布尔值、应用自身 ubiquity container URL 和 Documents 可用性作只读预检，通过后才创建云端 fixture。首次只读预检未通过：`ubiquityIdentityTokenPresent=false`、`containerAvailable=false`、`containerURL=nil`，约 56ms 返回，无 IO 超时；未创建云端 fixture。`codesign` 返回空字典，但构建已使用 `CODE_SIGNING_ALLOWED=YES`，生成的 `Simulated.xcent` 含预期云容器 ID；模拟器 entitlement 有单独嵌入路径，不能按 codesign 字典断定权限缺失。进一步检查可执行文件确认已嵌入预期 application ID、CloudDocuments、CloudKit 与自身 ubiquity 容器 ID。尝试按现有签名配置重建时停在 Nix 依赖下载，已停止该次重建，未安装替换版本；使用已安装探针再次有界只读预检，结果仍为 token 不存在、容器 URL 为 nil、Documents 不可用。当前仅证明应用侧云能力不可用，不否定用户已经登录，也未定位该环境缺口的具体原因。C 线因预检未通过停止：未创建云端 fixture，未执行 trash/恢复及外部选择器用例；不改用真机、不读取账户内部数据库或凭据、不改登录设置。证据 `build/LibraryTrashSimulator/C/preflight-events.jsonl`、`preflight-retry-events.jsonl`、`preflight-retry-result.json`、`B-embedded-entitlements.json`、`signing-audit.json`、`build-existing-signing.log`。


阶段 0 已结束，C 线按环境缺口收尾，不再排查。调用方式定为直接 `trashItem`，书架根按 `.Trash` 路径段判断。B 线长按 Recover 失败、单项“选择 → 恢复”成功的差异可能与真机失败有关，但尚未证实同因，留到阶段 2 集中确认。

## 2026-10-14 最近删除阶段 1

按定稿实现 actor 外独立队列直接 `trashItem`，用户明确选择后才永久删除；安全作用域保持到 IO 结束。文件系统成功与刷新失败分开返回，旧扫描在删除前及成功后失效。同名替换和不支持最近删除统一为待决定状态，UIKit 关闭弹窗后继续；每项先尝试 trash，不支持选择仅在本批沿用，结束清空。取消开书仅限同书架路径及后代，不解析跨书架重叠根；书架根含 `.Trash` 路径段时沿用重新连接错误，不扫描或刷新书签。确认文案及英文资源同步；不加 iCloud 闪回过滤。

新增定向 A 线测试涵盖错误映射、批次选择与清空、删除成功后刷新失败、废纸篓书架根、开书取消、弹窗关闭顺序、云交接与删除等待并行、旧扫描失效及恢复后 SHA/进度/书签/笔记接回；多选 UI 使用显式 DEBUG/testSession 限定的确定性删除注入，不作为系统 Files 可恢复性验证。

同一 B 专用模拟器（iPhone 17 Pro、iOS 27.0、Debug、串行）：11 项 `LibraryTrashTests` 和 2 项相关 `TextLayoutTests` 通过；`testBookshelfSelectionDeletesOnlySelectedFiles` 通过，覆盖共享确认框标题、说明、按钮及仅移除选中项。最小批量复制队列 UI `testBookshelfBatchCopyDecisionQueuePreservesSkippedSelectionAndSources` 通过，验证取消第一项同名冲突、接受第二项以及源文件和跳过选区保留；最终按路径分段比较的取消边界单测再次通过。另一个会删除预置测试文件的既有用例 `testEmptyFolderImportButtonContrastInLightAndDarkThemes` 同样切为注入删除，单项复测通过，覆盖删除后空目录和浅深色流程。正常项目测试构建与这些运行均有完整 xcresult；未跑全量，不操作真机，本轮不重复 B/C 系统集成，阶段 2 真机验收仍待完成。

构建最初受 Nix 缓存下载影响，网络恢复后按原项目命令正常重试通过，未改配置、锁文件、代理或绕过工具链。日志及结果在 `build/LibraryTrashImplementation/`：`build-network-retry.log`、`build-final-queue-ui.log`、`targeted-tests.log`/`targeted.xcresult`、`queue-ui.log`/`queue-ui.xcresult`、`empty-folder-adaptation.log`/`empty-folder-adaptation.xcresult`；语法解析与 `git diff --check` 通过。

### 既有待修复项：批量复制工具栏间距

原完整 UI 用例 `testBookshelfBatchCopyKeepsSourcesAndSkippedSelection` 在点击复制之前的紧凑工具栏间距断言失败（68.67pt，要求 <24pt），当前实现初跑和复测相同。按要求在未修改的 `ef2e881` detached worktree、同一模拟器、同一 Debug 配置、独立 DerivedData 上仅运行该用例一次，得到相同失败数值，证实为实现前已存在的问题。本次保留原断言和工具栏代码，不修此项；受影响的冲突队列由上述最小 UI 用例验证。不能把完整旧用例记为通过。

基线证据：`Baseline-build.log`、`Baseline-tests.log`、`Baseline.xcresult`、`baseline-configuration-proof.json`；当前复测 `copy-retry.log`/`copy-retry.xcresult`。Rust/flake 源码一致，缓存复用已记录，当前 App/测试产物哈希前后未改变；临时 worktree 已删除，build 证据保留。

## 2026-10-15 书架拖动：第 0 步模拟器试验

仅在现有 B Dedicated（iPhone 17 Pro、iOS 27.0）运行临时探针，不操作真机或已有小说。无托管菜单的 App 对照中，悬停系统返回按钮发生原生返回，源页消失时 `activeDrag=true`；原生文件夹 spring loading 触发一次进入，子页面收到同一条目 ID 的放置事件，探针未实际移动文件。静止长按的托管 SwiftUI 菜单可见；菜单动画后的 XCUITest 等待空闲超时使共存观察不完整，不能据此判定 API 冲突。

同一模拟器的“文件”App 对照确认返回按钮悬停能原生返回，之后夹具 cell 定位断言失败；文件夹悬停、长按与拖动共存、空目录放置没有得到完整观察，不记为不支持。此项不追加系统调查。按 designer 更正，原生返回与会话仍在已满足可行条件，保留应用私有 Transferable 和首页目标。

证据在 `build/LibraryDrag/`：`step0-observations.json`、`step0-temporary.patch`、`app-tests.log`、`app.xcresult`、`app-attachments/`、`app-observations.mp4`、`files-tests.log`、`files.xcresult`、`files-observations.mp4`。四个临时探针文件已逐字恢复，临时探针不提交。

### 正式实现与定向回归

列表／网格使用原生拖放委托，文件夹悬停与边缘滚动交给系统；放下按 ID 重取条目，复用真实移动及替换队列。首页书架行保留私有 Transferable 接收；外部只收 TXT 文件表示、目标仅限我的书架。文件在提供者回调内复制，导入成功、替换取消或失败结果关闭时清理，重试期间保留，拖入完成不跳转。

初次网格用例长时间停留连续 spring 进入“奇幻／东方”，文件已移动，断言误查中间目录；后续将直接放置与单层进入拆开，不修改生产时机。空目录在兄弟 SwiftUI 空状态覆盖层布局下未收到放下，单独保留空 section 和扩大命中区域仍失败；最终将原空状态托管为集合视图 backgroundView，保留空 section、原显示条件和导入按钮，移除兄弟放置接收器后通过。

同一 B 模拟器、Debug、串行：6 项 `LibraryDropTests` 与 3 项相关 `TextLayoutTests` 通过，覆盖路径分段／同父目录／可用性、拒绝纯文本片段及其他书架、真实 NSItemProvider 暂存、成功／取消／重试／关闭清理、改名后的 ID 重取，以及私有 Transferable 解码后移到首页书架根。最终空状态托管调整后，3 项 UI 用例通过：列表与网格直接放置、单层 spring 进入后放到当前页、空目录放置与选择模式禁拖；空目录导入按钮可点击，源条目消失、目标条目出现。单元回归在最终空状态托管调整前通过，该调整由最终 UI 回归覆盖。正常项目 Nix 测试构建和 `git diff --check` 通过，未跑全量，未操作真机或新建模拟器。

首页只做过一次有限连续手势观察：原生返回到首页，但公开 XCTest 的终点停留手势在返回按钮处释放，无法继续拖到书架行，未证明首页实际收到放下。按用户决定不删首页功能；规则和执行由上述单元覆盖，连续跨页拖动留待用户最后试用。跨 App 的 Files 拖入未做 UI 冒烟，以真实提供者的单元／集成覆盖为本轮依据，手感仍待试用。旧诊断附件中的回退建议已被最新决定取代，仅保留原始证据，不代表最终范围。

最终证据：`build/LibraryDrag/implementation-results.json`、`native-empty-build-retry.log`、`native-empty-tests.log`／`native-empty-targeted.xcresult`、`native-empty-attachments/`；单元及原失败记录为 `final-functional-tests.log`／`final-functional-targeted.xcresult`、`implementation-tests.log`／`implementation-targeted.xcresult`。一次性首页观察测试已删除，探针补丁、录像、用户或夹具文件均不提交。

## 2026-10-15 书架行在 provider 放下时准入

核对当前代码确认：原首页／管理页的 `dropDestination` 会先导入 Transferable 再调用 action，未覆盖这段解码期间的模型所有权；“我的书架”还叠加外部 onDrop。现统一为一个 provider 级 DropDelegate，在 performDrop 同步调用模型准入。悬停只读可用状态与类型／名称元数据，提示 move、copy 或 forbidden；私有负载加载／解码、按 ID 查询及移动关系校验均在已占用任务内完成，失败可见报错并释放。删除 Transferable 导入／导出一致性，只保留私有 provider 导出与模型侧解码；集合视图保留 localObject ID，同一模型入口与准备校验。

新增可控负载挂起测试验证放下即占用、其他文件操作被拒、系统 onOpenURL 文件排到原任务之后；解码失败和条目消失都报错并释放。元数据政策覆盖 move／copy／forbidden、混合批次及失效目标，不用 sleep 制造竞争。此前按改名后稳定 ID 移到首页根的测试也改走书架行 delegate，不再先在测试中解码。

受影响 17 项 `LibraryDropTests` 通过，3 项既有拖动 UI 回归均取得通过结果：列表／网格移动、单层悬停进入在首轮通过；空目录首轮未触发预期的悬停进入，保持生产代码与 UI 断言不变单项复跑通过，不把首轮整批记为成功。元数据单测首轮因误登记不应触发的 XCTest expectation 报未等待，修正夹具登记后 17 项复跑通过。证据：`build/LibraryDrag/shelf-provider-build.log`、`shelf-provider-tests.{log,xcresult}`、`shelf-provider-test-build-retry.log`、`shelf-provider-retry.{log,xcresult}`。没有现成稳定的首页跨页连续手势 UI 用例；单测覆盖其 delegate 准入及模型执行，真实手势留待用户复测。

正常签名 Release 构建、验签通过并覆盖安装、启动 iPhone 13，保留数据，无测试／诊断参数；日志为 `build/LibraryDrag/Device/shelf-provider-build.log`、`shelf-provider-install.{log,json}`、`shelf-provider-launch.{log,json}`。合并复测清单为同目录 `书架行与Files合并复测.md`，包括 Files 新建议名规则与跨页拖到首页书架行两项。Files 的真实 suggestedName 及这版跨页手感仍待用户确认，不由安装或单测推断通过。

## 2026-10-15 拖放准入与外部 TXT 表示修正

文件任务由 `LibraryModel` 单一所有权管理，同步准入即占用，覆盖 provider／条目查询、执行、替换及最近删除确认；菜单、表单、导入、重试、书架接入与拖放共用入口，`perform` 私有化。确认恢复原任务，失败或取消释放未转交资源；系统已交来的 URL 持有访问权限并串行追加，批次导航策略不互相覆盖。删除视图层静态执行方法与额外的私有类型解码。

外部入口只接收 plainText 类型且具有合法 `.txt` 建议名的项目，不要求 open-in-place 或 file-url。准入固定名称，文件表示回调内验证常规 TXT 并按固定名称复制原始字节。明确边界：无名真实文件会被保守拒绝；有名的数据表示可文件化接收，不能据此保证原始来源是文件。

正常模拟器构建通过；14 项 `LibraryDropTests`、7 项相关 `TextLayoutTests`、3 项拖动 UI 回归全部通过（`build/LibraryDrag/review-clean-build.log`、`review-targeted.log`、`review-targeted.xcresult`）。准备竞争用可控 completion／查询挂起，未用 sleep 制造竞争；覆盖第二次请求拒绝、菜单准入、系统 URL 追加、替换确认／跳过、失败重试、取消与迟到回调、部分暂存清理及来源／目标变化。首轮 13/14 的失败来自错误测试假设：Foundation 可按建议名改名回调临时文件；改为直接控制回调 URL 来覆盖错误扩展名及目录，最终通过，不放宽生产校验。

另补跑 5 项 `LibraryTrashTests`，覆盖批次只问一次、替换暂停／继续、跳过、文件系统成功后的刷新失败不重试及删除取消同书架后代打开，全部通过（`build/LibraryDrag/review-queue.log`、`review-queue.xcresult`）。本轮实际定向回归合计 29 项，未跑全量。

真实 Files 元数据仍待确认：仅用一台已有 iPad 模拟器尝试分屏跨 App 拖入，找到合成 `SuggestedName-Probe.txt`，但两个窗口仍重叠全屏，未发生放下，也未获得真实 provider 的 suggestedName。日志和结果包为 `build/LibraryDrag/Review/files-probe-final.log`、`files-probe-final.xcresult`；临时探针与 UI 用例已丢弃，模拟器已关闭，未新建模拟器。合成 provider 测试不替代 Files 验收；需要用户用正常 Release 从 Files 拖入合成 TXT 再确认新规则，成功并留在当前文件夹才能确认真实建议名满足条件。

正常签名 Release 构建及 `codesign --verify --deep --strict` 通过，已覆盖安装并启动 iPhone 13，保留数据，无测试／诊断参数。证据为 `build/LibraryDrag/Device/review-build.log`、`review-install.{log,json}`、`review-launch.{log,json}`；一分钟 Files 复测清单为同目录 `评审修正复测.md`。安装成功不代表 Files 新建议名规则已获用户验收。

## 2026-10-15 拖动预览仅保留封面

按真机反馈，集合视图通过 `dragPreviewParametersForItemAt` 返回圆角封面区域的 `visiblePath`：网格取宽度／0.7 的封面区域，列表复用 32×44 封面尺寸并按行高居中；书和文件夹保留各自圆角。只使用公开 cell 几何与布局常量，不探查 SwiftUI 托管层级。系统遮罩同时用于 lift 和持续拖动，不另设 previewProvider，目标文件夹高亮与拖放执行不变。

现有 B Dedicated 模拟器的 3 项拖动 UI 用例通过，覆盖列表／网格直接移动、单层悬停进入后放下、空目录及选择模式禁拖。正常 Debug 测试构建与签名 Release 构建通过。录屏人工核对持续拖动预览只有封面，外围书名、进度、操作按钮未被带入。首次命令的用例断言均通过，但 xcodebuild 长期滞留在结果收尾，保留日志后停止；关闭测试诊断采集重跑相同用例与断言，命令正常成功结束。最终回归依据为 `build/LibraryDrag/preview-retry-tests.log`、`preview-retry-targeted.xcresult`；截图和原录像为 `preview-grid-drag.png`、`preview-list-drag.png`、`preview-drag.mp4`，构建日志为 `preview-build.log`、`Device/preview-build.log`。合成夹具截图、录像和临时证据未提交。

## 2026-10-14 最近删除阶段 2 单文件反馈与失败策略

用户在 iPhone 13 的正常签名 Release（514d7d7，保留现有数据）试用后确认：内置 iCloud 和 iCloud Drive 外部书架的单个测试 TXT 都能移到最近删除并在 Files 可见；长按菜单没有“恢复”，通过“⋯ → 选择 → 恢复”可手动恢复。用户接受这一入口差异，不在应用层处理。

“我的 iPhone”外部书架调用 trashItem 失败，显示通用错误“未能将…移到废纸篓”；此前只处理 3328 的策略没有进入本批确认。按用户决定，非永久删除时 trashItem 返回的任何失败都转为 `LibraryFileError.trashUnsupported`，复用本批一次“永久删除这些项目 / 跳过”；仍逐项先尝试 trash，不自动永久删除。永久删除失败原样报告，删除成功后的扫描或索引刷新错误不触发永久删除重试。不区分错误码、不加日志探针、不继续现场调查。

本地内置根及尚未删除的文件夹没有在这次真机试用中验证，仍是缺口，用户接受；不能把未操作的文件夹记为失败或通过，也不将单文件恢复扩大为这些场景的验收。

只运行 4 项受影响的模拟器单测，全部通过：任意 trash 错误映射与永久删除错误保留、非 3328 错误进入待决定并在本批复用／结束清空、跳过仍逐项尝试 trash、删除成功后刷新失败不重试。正常增量测试构建通过。日志与完整结果在 `build/LibraryTrashImplementation/policy-build.log`、`policy-tests.log`、`policy-tests.xcresult`；未跑全量或真机 XCTest。
