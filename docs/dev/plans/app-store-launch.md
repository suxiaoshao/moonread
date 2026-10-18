# App Store 上架准备

状态：第一阶段，只读核查与材料草案；未创建 App、注册标识、设置价格、上传构建或提交审核。核查日期：2026-10-16。打赏产品决定见[打赏方案](tip-jar.md)，本文不重新决定产品范围。

**已确认的发布范围：中国大陆暂不发布，首发排除中国大陆。**未来可考虑大陆无 AI 版本，但尚未批准实施，也不能预设它免于 APP 备案；见第 7 节。英文名称 Moonread: TXT Reader，版权 © 2026 suxiaoshao，公开邮箱 suxiaoshao@gmail.com；首发含欧盟，DSA 商家声明已提交审核中。

2026-10-16 用户将公开联系邮箱改为 Gmail：`suxiaoshao@gmail.com`，应用与政策／支持站同步采用该地址。欧盟 DSA 商家邮箱的修改另行处理；本次应用及网站更新不代表 DSA 资料已经更新。

本轮只维护本文，不修改应用代码、不执行 Git 操作、不提交。下文“代理可做”表示职责可由代理承担；网站写入、构建上传、公开站点发布等仍须取得对应阶段授权。正式 App 记录、SKU、Bundle ID、商品 ID、价格、CloudKit production schema 等先交协调者确认。

## 1. 当前账号与工程状态

### 网站只读核查

使用 Dia 的 **self enjoy** 空间。用户自行完成登录及协议接受；代理不输入、读取、保存密码、验证码或银行税务信息。只提取账号类型、协议状态及应用标识，不保留个人资料页面截图。

| 项目 | 当前结论 | 证据与下一步 | 责任 |
| --- | --- | --- | --- |
| App Store Connect 登录 | **已登录** | self 中 `appstoreconnect.apple.com/apps` 显示已登录 Apps 页面 | 代理可做：只读；重新登录/双重认证需用户本人 |
| Developer 登录与会员类型 | **已登录；Apple Developer Program，Individual** | `developer.apple.com/account` 的 Membership details；续期日显示 2027-10-02 | 代理可做：只读；续费/身份变更需用户本人 |
| 已有 App 记录 | **当前所选团队显示 No Apps** | Apps 页面显示尚未添加应用；未点击 New App。仅代表当前团队可见范围 | 代理可做：拟定字段；创建前需协调者确认 |
| `dev.moonread.Moonread` 注册 | **已存在** | Developer → Identifiers → App IDs 列表显示 `XC dev moonread Moonread`，完整标识 `dev.moonread.Moonread`；无需重复注册。能力关联及分发包另行核对 | 代理可做：只读；能力变更前需协调者确认 |
| Paid Apps Agreement | **最近一次核查为 New，未确认签署/生效** | Business → Agreements 要求先更新 legal entity information。按用户要求已导航至 **Edit Legal Entity** 并交接；代理未读取输入字段值、填写、保存或提交，未进入银行/税务表单。用户操作后的协议状态待复核 | 需用户本人：主体资料、签署、银行及税务；代理仅复核协议状态 |
| Apple Developer Program License Agreement / Free Apps Agreement | **用户已接受更新；Free Apps 行为 Active** | 用户回复“我同意协议了”；Business 刷新后更新协议警告消失，Free Apps 从 Active (New Agreement Available) 变为 Active | 已由用户本人处理；不代表 Paid Apps 同时生效 |
| EU trader 声明 | 待核实 | 首次 Apps 页面有 DSA trader 提醒；提示本身不能证明具体声明状态 | 需用户本人判断身份并完成核验 |

本轮五项核查已完成。后续仅在用户处理待办后复核：App Store Connect → Business → Agreements，**只读 Paid Apps 行**；分发前再核对既有 App ID 的 iCloud 能力关联。不进入 Banking、Tax、财务报表或身份材料详情。若无法在不接触这些信息的情况下取得状态，由用户仅告知协议状态文字，不索取截图、账号或表格。

Paid Apps 的 `New`、`Pending User Info`、`Processing`、`Active` 含义不同；签署完成不等于已生效。以实际行状态及是否仍有待办为准。[Apple 协议状态说明](https://developer.apple.com/help/app-store-connect/manage-agreements/view-agreements-status)

### 代码中已核对的事实

- [工程设置](../../../ios/Moonread.xcodeproj/project.pbxproj)：Bundle ID `dev.moonread.Moonread`，最低 iOS 18，设备族 `1,2`（iPhone/iPad）；首次正式版本为 `1.0.0`，当前 build `3`。后续上传使用单调递增整数 build，规则见[开发环境](../engineering/development.md#发布版本与构建号)。
- [Entitlements](../../../ios/Moonread/Moonread.entitlements)：固定容器 `iCloud.dev.moonread.Moonread`，CloudDocuments、CloudKit、推送；源码中的 `aps-environment` 为 development，**最终分发包实际授权须单独检查**。
- [iCloud 接入](../data/icloud-implementation.md)仍要求发布前确认 production schema；开发签名/开发容器测试不能替代 TestFlight 的生产环境验证。
- 当前 `ios/` 文件及工程引用中未找到 `PrivacyInfo.xcprivacy`；[Theme](../../../ios/Moonread/Shared/Theme/Theme.swift)、[ReadingStatistics](../../../ios/Moonread/Statistics/ReadingStatistics.swift)、[LibraryService](../../../ios/Moonread/Library/LibraryService.swift)分别涉及 UserDefaults、系统运行时长、文件修改时间。须按实际使用补隐私清单并检查最终 archive，不能只填写商店隐私标签。
- [SettingsView 的 AboutView](../../../ios/Moonread/Settings/SettingsView.swift)有数据说明，当前未见隐私政策/支持网页链接。[AI 使用帮助](../../../ios/Moonread/AI/UI/AISettingsView.swift)和[引导](../../../ios/Moonread/Settings/Onboarding.swift)已有发送上下文的说明，但尚未完成“向第三方 AI 分享个人数据前明确许可”的逐路径核验。
- [AITransport](../../../ios/Moonread/AI/Providers/AITransport.swift)、[AIAuth](../../../ios/Moonread/AI/Providers/AIAuth.swift)、[AIModelCatalog](../../../ios/Moonread/AI/Providers/AIModelCatalog.swift)、[AICoverImageFetcher](../../../ios/Moonread/AI/Providers/AICoverImageFetcher.swift)存在外部请求；凭据经 Keychain 保存，模型目录会访问 `models.dev`。不能宣称整个应用完全不联网或一概“无数据收集”。

上述是源代码检查，未做最终包构建、流量采样、沙盒购买或 App Store 审核验证。

## 2. 上架清单与分工

| 项目 | 完成条件 | 分工与当前状态 |
| --- | --- | --- |
| 账号与协议 | 正式开发者会员有效，开发者许可协议无阻断，Paid Apps 生效 | 代理可做：状态核查；**需用户本人**：登录、验证码、协议、银行、税务 |
| App 身份 | 明确团队、名称、主语言、SKU、Bundle ID；复用已存在标识 | 代理可做：草稿/核对；创建及能力变更等协调者确认 |
| 名称、副标题、分类 | 字数合规、如实反映 TXT 阅读，无冒用/可用性冲突 | 代理可做：检索/文案；用户确认公开名称；见第 3 节 |
| 年龄分级 | 按最终包能力完成现行问卷，包括 AI、网页访问与内容情况 | 代理可做：逐项证据及填表草稿；需用户本人确认内容责任；见第 4 节 |
| 版权与内容权利 | 内置故事、截图文字、封面、字体及第三方服务有使用依据 | 代理可做：资产清单/许可证核查；需用户本人确认权利，缺失材料阻断提交 |
| 隐私政策/支持站 | 公开 HTTPS 页面、稳定可访问、有真实联系渠道；App 内可访问政策 | 代理可做：起草与检查，发布须另授权；需用户本人提供公开联系信息 |
| App Privacy | 数据类型、用途、身份关联、追踪与实际网络行为一致 | 代理可做：证据表及草稿；需用户本人确认最终声明；见第 5 节 |
| Privacy manifest | App 与所用 SDK 的清单随 archive 打包；required-reason API 理由正确 | 代理可做：检查/提出缺口；本轮不改代码，交实现负责人补齐 |
| 加密/出口合规 | 列出实际加密用途，按最终 archive 回答问卷 | 代理可做：技术清单；需用户本人确认法律声明/上传所需文件；见第 6 节 |
| 中国大陆 | **暂不发布（用户已决定）**；首发 App 和 IAP 地区配置均排除中国大陆 | 代理可做：后续获授权时核对地区；未来大陆版本的备案/资质另行确认，不阻断其他地区首发；见第 7 节 |
| 其他分发地区 | 明确首发国家/地区、EU trader、自动扩展地区及 Mac/Vision 可用性 | 代理可做：建议与核对；需用户本人确认地区/身份；不默认全球上架 |
| 免费本体与打赏 | App 价格免费；四项消耗型 IAP ID、地区、价格、本地化与实现一致 | 代理可做：拟定/核对；按现有打赏方案由用户本人创建商品及设置价格；见第 9 节 |
| 图标与截图 | 分发包图标有效；真实 iPhone/iPad 页面，尺寸/内容/语言符合要求 | 代理可做：模拟器拍摄与素材制作，待后续授权；见第 8 节 |
| 商店文案 | 描述、关键词、版权、支持地址及中英本地化齐全 | 代理可做：草稿/字数检查；需用户本人确认版权署名和公开信息 |
| 审核访问 | 阅读无需账号；AI 可被完整复核；说明 iCloud、导入与打赏路径 | 代理可做：审核备注/演示材料；需用户本人安全配置专用审核访问，不能给个人凭据 |
| 分发构建 | 对应发布源码、有效签名/描述文件、正式 Bundle/版本、无诊断开关及本地 StoreKit 模拟配置 | 代理可做：独立构建/检查/上传，**本轮未授权执行**；不干扰 worker 的构建目录 |
| CloudKit 生产环境 | production schema 与最终 SwiftData 模型匹配，分发授权/权限正确 | 代理可做：只读差异报告；部署等难撤销操作先由协调者确认，见第 10 节 |
| TestFlight | 少量内部测试通过；有需要才外测，无真实收费测试 | 代理可做：测试计划及材料；用户本人完成账号操作，发送邀请另行授权 |
| 最终提交与上线 | App + 首批 IAP 同一审核提交；用户核对发布地区/价格/声明 | **需用户本人**点击提交审核；建议手动发布，获批后由用户本人决定上线 |

## 3. 商店身份与文案定稿

三语名称与商店文案已在 App Store Connect（ASC）保存定稿。名称与副标题以该 App 的“App 信息”各语言本地化为准；描述、关键词与推广文本以当前 iOS 版本页面的简体中文／繁体中文／英文已保存内容为准。本计划不另维护待回填的文案草稿或名称备选。

| 字段 | 定稿／现状 | 说明 |
| --- | --- | --- |
| 简中名称 | `月读：TXT 小说阅读器` | 已在 ASC 保存 |
| 繁体名称 | `月讀：TXT 小說閱讀器` | 已在 ASC 保存 |
| 英文名称 | `Moonread: TXT Reader` | 已在 ASC 保存 |
| 副标题、描述、关键词与推广文本 | 三语定稿位于 ASC | 后续修改在 ASC 核对，避免回填过时草稿 |
| 主语言与本地化 | 简体中文，另提供繁体中文与英文 | 应用与商店页面按语言核对 |
| 主类别 | Books / 图书 | 按阅读主功能选择；次类别可先不填，不为绕开中国区资质改分类 |
| Bundle ID / SKU | `dev.moonread.Moonread` / 以 ASC 已保存值为准 | Bundle ID 上传构建后不可改；SKU 创建后不可改 |
| 价格／发布 | 本体免费；发布方式以 ASC 设置为准 | 中国大陆暂不发布已确认 |

名称 2–30 字符、副标题最多 30 字符；正式名称以 ASC 已保存记录为准，公开检索不能代替后台校验或商标核查。[Apple App information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

描述上限 4000 字符、关键词上限 100 bytes；以后调整文案仍须按最终包能力与后台计数器复核，不堆竞品名称、不加入未验收承诺。[版本元数据说明](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)

## 4. 年龄分级、内容与审核访问

**代理可做：**生成问卷答案及证据；**需用户本人：**确认内容权利、发布声明和必要审核访问。

- 不预设 4+，不勾 Kids。问卷按最终功能回答：私人导入/批注不等于公开 UGC；AI 对话不自动等于用户间聊天；固定授权页面也不自动等于无限制网页浏览。逐项核实是否能在 App 内任意浏览网页、AI 可能呈现的内容及实际安全控制，不能因 BYOK 可选而忽略。
- 新问卷包含社交能力等字段；最终数字由 Apple 依据答案和地区计算。不得沿用旧四档印象或为了较低评级虚填。[年龄分级定义](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)
- 截图使用作者自有且适宜公开的样例；不拍用户书架/私有小说/AI 对话。不凭“网上可下载”判断版权。核对内置 `WelcomeStory.txt`、使用指南、封面、字体和开源许可证。
- 审核员无需月读账号即可阅读；提供合法样例及实际导入路径。AI 需审核可访问：由用户安排有权限、可撤销、限额的专用测试连接或与 Apple 确认可接受演示方式；不要只写“请审核员自备 Key”，也不隐藏 AI 功能。本文不收集任何真实凭据。
- 现有第三方订阅授权连接的可用性和服务条款须核对；“技术上能登录”不证明有权在第三方客户端使用。提示审核员这是可选服务连接，不是月读主账号登录。是否触发额外登录要求由实际功能核实。

审核备注英文草案：

> Moonread is a TXT reader for files provided by the user. Reading does not require a Moonread account. Please use the bundled sample and the Files import action to test reading, search, bookmarks and annotations. iCloud file storage and optional reading-data sync use the user's Apple services. AI features connect to the provider selected by the user; review access and exact test steps will be supplied separately. The three consumable purchases under Settings → Support Moonread are optional tips. They do not unlock any content, feature or entitlement and may be purchased repeatedly. There is no subscription or external payment flow.

最终替换为实际菜单名/样例入口，并补审查联系人、AI 访问说明和所需附件。不能把尚未提供的测试访问写成已就绪。完整性、第三方权利、元数据与 AI 告知依据 [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。

## 5. 隐私政策、支持网址与 App Privacy

### 公开页面

**代理可做：**起草、生成静态页面并在后续获授权时发布；**需用户本人：**提供希望公开的联系渠道、确认政策及域名/托管归属。

最简建议：一个公开 HTTPS 静态站，分别有 `/privacy/` 与 `/support/`；可复用已有个人站，或另授权 GitHub Pages 等静态托管。当前尚未确认站点、域名或上线 URL，**不把占位 URL 填进 Connect**。政策和支持页应无需登录、无地区跳转、手机可读；覆盖并实际测试首发语言及地区，不能只验证本机能打开。大陆连通性留待未来大陆版本评估，不作为本次首发前置条件。

隐私政策至少写明：开发者/联系方式、生效日期；本地原件和阅读记录；iCloud Documents 与可选 CloudKit 的区别；AI 服务、发送范围/时机、凭据存放和供应商规则；模型目录/图片下载等联网；Apple 处理付款；留存、关闭同步、删除本地及云端数据的实际途径；第三方已接收数据如何申请删除。卸载应用不等于删除 iCloud 或第三方数据。正文按实际能力写，不承诺未经实现的“彻底删除所有云端副本”。

支持页提供导入 TXT、iCloud 未下载/断网、阅读恢复、AI 配置、打赏失败的简短帮助及真实联系邮箱。GitHub Issues 可作为补充，不能只有空白页面或要求所有用户注册 GitHub 才能联系。App 内设置应有易找到的政策和支持入口；当前 AboutView 的本地说明还不能替代公开政策。

### 隐私标签工作表（待确认，不能直接作为最终勾选）

| 数据流 | 已有证据/用途 | 标签判断与剩余核查 | 责任 |
| --- | --- | --- | --- |
| 本地小说、位置、批注、统计、AI 本地会话 | 本机存储及计算 | 仅设备内处理不构成 Apple 定义的收集；本地统计不是开发者遥测 | 代理可做：核对最终包 |
| iCloud Documents / CloudKit 私有库 | 用户选择的云文件及可选阅读数据同步；`UserDataService` 使用 `.private` | 区分 Apple 自行处理与开发者/伙伴实际可取得的数据；不能仅因使用 CloudKit 就一律勾“收集”或一律免报 | 代理可做：列数据与访问边界；需用户本人确认 |
| AI 提问、页面/选区、工具返回、笔记/书目、图片 | 发送到用户所选供应商，用于功能 | 若供应商保留超过实时处理期限，候选含 Other User Content、实际发送的 Photos or Videos；按账户关联判断 Linked to You，不能因为无自建服务器填“未关联” | 代理可做：逐供应商/路径核对；需用户本人确认政策 |
| AI 认证与服务账户标识 | Keychain 与服务端认证 | 不读取真实 Key/token；核对是否有被留存的 User ID/其他标识及用途；不能把一般认证自动当追踪 | 代理可做：源码/公开条款核对 |
| 联网搜索、模型目录、封面/图片请求 | 搜索服务、`models.dev`、下载站点收到请求 | 核对查询/URL、IP/日志的留存及分类，覆盖未配置 AI 时的目录刷新；本地书内搜索与联网搜索分开 | 代理可做：清单及必要的脱敏测试，待另授权 |
| 打赏 | StoreKit 本机验证/finish，计划不存金额或历史 | 若最终实现无开发者/伙伴收集购买记录，不因 Apple 收款自动新增 Purchase History 或 Payment Info；仍需检查最终实现和日志 | 代理可做：最终复核；本轮未验收购买 |
| 支持联系/诊断 | 取决于最终支持方式及是否上传日志 | 自愿反馈不自动免报，按可选披露全部条件判断；不得预先承诺“不收集诊断” | 代理可做：确认收集路径；需用户本人定留存 |

Apple 的“收集”关注离开设备并被开发者/伙伴保留超过实时处理所需的情况；可选功能也可能必须披露。最终还须填写用途、身份关联及是否追踪，不能只勾数据名称。当前未发现广告/跨 App 追踪设计，是否“不追踪”仍需最终依赖与网络清单确认；不要为普通 AI 请求添加无意义的 ATT 弹窗。[App Privacy definitions and examples](https://developer.apple.com/app-store/app-privacy-details/)

提交前有两项具体检查：

1. **第三方 AI 明确许可**：已有帮助文案说明上下文发送，但需确认真实发送前用户能明确知道接收服务及数据范围并同意；涵盖阅读问答、统计分析、封面/资料任务，拒绝不影响本地阅读。BYOK 和点击发送本身不自动证明告知充分。[审核指南 5.1.2(i)](https://developer.apple.com/app-store/review/guidelines/#data-use-and-sharing)
2. **隐私清单随包提供**：由实现负责人检查 UserDefaults、SystemBootTime、FileTimestamp 及依赖调用，选择符合实际用途的 approved reasons；不要照搬别人的 reason codes。App Privacy 网页、`PrivacyInfo.xcprivacy`、隐私政策互相不能替代。[Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)

打赏页的“不收集你的阅读数据”应与全应用 AI/云端说明一致；建议明确描述开发者不经营阅读数据收集，并单独说明用户主动发送到 AI 的情况。此处是上架文案核查项，不改变已批准的免费/自愿打赏决定。

## 6. 加密与出口合规

**代理可做：**技术清单和问卷草稿；**需用户本人：**确认最终出口声明、必要法律文件。

已见用途：URLSession 的 HTTPS/TLS、Keychain、CryptoKit 的 SHA-256/PKCE、Rust `sha2` 用于正文身份。SHA 摘要不是对小说做可逆加密；有第三方 hash crate 也不能直接推断为“自行实现加密通信”。仍需核对最终依赖、二进制及是否还有自带 TLS/数据库加密，当前 `Info.plist` 未见 `ITSAppUsesNonExemptEncryption`。

若确认仅有系统加密及适用豁免用途，建议由实现负责人据实设置非豁免加密标记，避免每次上传重复问卷；不要把该标记理解为“完全没用加密”。Apple 对仅使用操作系统加密的应用不要求在 Connect 提交加密文件；其他情况按算法与销售地区判断，法国要求不能遗漏。[加密文件要求](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)、[填写流程](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation)

## 7. 中国大陆及地区合规

### 首发决定与依据

**中国大陆：暂不发布。**用户已决定首发排除中国大陆；后续配置 App 和打赏商品的销售地区时落实此项，不默认选择所有地区。其他地区仍按用户确认范围发布，不再把大陆资质作为其他地区首发的前置条件。本轮仅更新计划，未修改 App Store Connect 的地区配置。

决策依据是协调者转达的审核要求：Apple 要求提供 APP 备案号，只有完全离线应用可主张免备案；生成式 AI 功能在大陆另有许可要求。月读当前包含 iCloud、AI 及其他联网路径，不能按完全离线应用准备首发。**证据边界**：Apple 公开帮助使用“部分 App”须具备有效 ICP 备案号的表述，本次未取得 Apple 对月读或“仅使用 Apple 系统联网能力”的个案豁免确认。本文记录发布决定及其依据，不把“仅完全离线”扩写为已获官方确认的完整豁免规则。[Apple 中国大陆字段要求](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)

生成式 AI 的具体义务须按服务形态确认：《生成式人工智能服务管理暂行办法》第 17 条对具有舆论属性或社会动员能力的服务规定安全评估及算法备案，第 23 条要求在法律、行政法规规定的情况下取得相关行政许可。不能把用户自备 Key、接入海外服务或无需月读账号视为免除这些要求的依据。[网信办暂行办法](https://www.cac.gov.cn/2023-07/13/c_1690898327029107.htm)

免费不构成通用豁免；“阅读器”也不自动等于需要游戏版号。未来若重新考虑大陆发布，须区分以下事项：

| 项目 | 对月读的判断 | 分工 |
| --- | --- | --- |
| APP ICP 备案 | 工信部要求在境内从事互联网信息服务的 APP 主办者履行备案。无 AI 版本仍有 iCloud 等联网能力，是否可免备案不确定；免费、有无自建服务器不是充分判断标准 | 代理可做：整理最终版本联网清单；需用户本人届时向 Apple 开发者支持确认，并按答复办理适用手续 |
| 游戏版号/审批号 | 当前是 TXT 阅读工具，无游戏业务，未发现适用游戏审批号的依据；打赏不会把它变成游戏 | 代理可做：说明实际业务；不申请或填写无关版号 |
| 网络出版服务许可 | Apple 对提供书籍/杂志内容的 App 有要求；法规关注经网络向公众提供出版物。用户自带本地文件、私人同步与公开书库业务不同，但内置示例故事及 AI/联网内容也应如实说明，不能直接保证无需许可 | 代理可做：列明无在线书城、样例及联网能力；需用户本人向 Apple/当地出版主管部门确认 |
| APP 名称/标识一致 | 若需备案，简中名称等元数据须与备案一致；网站备案号不自动替代对应 APP 备案 | 代理可做：字段比对；需用户本人提供可公开的已核准备案结果 |
| AI 及第三方服务地区适用性 | 大陆生成式 AI 的许可、备案等要求独立于 APP 备案；未来若做无 AI 版本，应核对全部 AI 入口及请求链实际移除，不能只隐藏聊天入口 | 代理可做：按另行批准的范围核查；需用户本人确认适用要求 |

依据：[工信部 APP 备案通知](https://www.gov.cn/zhengce/zhengceku/202308/content_6897341.htm?type=mobile-internet)、[省级通信管理局备案办事说明](https://hnca.miit.gov.cn/bsfw/bszn/art/2020/art_95dd38fddd944b35ba5c81b5bb242040.html)、[网络出版服务管理规定第 2、7 条](https://www.nppa.gov.cn/xxgk/fdzdgknr/zcfg_210/bmgz_213/202112/t20211209_442163.html)、[Apple 中国大陆字段要求](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information/)。

### 后续候选：大陆无 AI 版本

这是后续考虑项，尚未确定实现、发行方式或发布时间。**去掉 AI 不等于完全离线；是否可免 APP 备案不确定，必须届时向 Apple 开发者支持确认，不能预设免备案。**咨询应提交最终功能与联网清单，明确 iCloud Documents、CloudKit、系统文件/照片提供者、StoreKit、封面获取和外部链接分别是否保留，取得针对该版本的答复后再决定大陆分发。

以下为 2026-10-16 当前工作区的源码核查，区分直接 HTTP、Apple/文件提供者代管的联网及外部浏览器跳转；不是实际流量测量，也不以系统代管为由认定备案豁免。

| 联网路径 | 当前代码证据与触发方式 | 对未来无 AI 版本的含义 |
| --- | --- | --- |
| 自身 iCloud 书架与云文件 | [CloudLibrary](../../../ios/Moonread/Library/CloudLibrary.swift) 使用 ubiquity 容器、`NSMetadataQuery`、`setUbiquitous`；[ReaderService](../../../ios/Moonread/Data/ReaderService.swift) 跟踪云文件下载。系统负责文件同步/下载，应用访问真实云目录 | 保留 iCloud 书架即仍有联网能力；关闭 AI 不影响此路径 |
| 阅读数据与设置同步、账号状态及推送 | [CloudSync](../../../ios/Moonread/Data/CloudSync.swift) 查询 `CKContainer` 账号与用户记录；[UserDataService](../../../ios/Moonread/Data/UserDataService.swift) 使用 SwiftData 私有 CloudKit 数据库；[MoonreadDelegate](../../../ios/Moonread/App/MoonreadDelegate.swift) 在支持云的构建中注册远程通知 | 独立于 AI；同步可选不等于发行包完全离线，需分别向 Apple 说明 |
| 外部书架、导入/拖入、导出与分享 | [LibraryActions](../../../ios/Moonread/Library/LibraryActions.swift) 的文件夹/文件选择、文档导出和分享；[LibraryDrop](../../../ios/Moonread/Library/LibraryDrop.swift) 的 `loadFileRepresentation`。用户选择 iCloud Drive 或其他云文件提供者时，系统可取回或上传文件 | 非 AI 功能；这是系统/提供者联网能力，不能把所有文件操作笼统记为纯本地 |
| 手动封面选图 | [BookInformation](../../../ios/Moonread/Books/BookInformation.swift) 支持照片选择、`loadTransferable` 及图片文件导入；照片或所选文件可能由系统从云端取回 | 与 AI 搜封面分开。本地图片编辑本身不发起网页搜索，但云照片/云文件路径可能联网 |
| 打赏 | [TipJar](../../../ios/Moonread/Settings/TipJar.swift) 在打赏页加载 `Product.products`，经 StoreKit 购买、处理交易及 `finish`；根场景监听交易 | 保留打赏即保留 Apple 商品/购买服务；不能因没有自建收款服务器就宣称完全离线 |
| 开源链接及未来政策/支持页 | [SettingsView](../../../ios/Moonread/Settings/SettingsView.swift) 的开源致谢 `Link` 会打开 GitHub；政策/支持页入口尚待实现 | 当前为用户主动打开的外部网页，区别于后台请求；未来页面也应列入咨询材料 |
| 联网获取封面 | [AIProposalTools](../../../ios/Moonread/AI/Tools/AIProposalTools.swift) 的 `find_cover` 先调用已配置的搜索服务；[AICoverImageFetcher](../../../ios/Moonread/AI/Providers/AICoverImageFetcher.swift) 再下载返回的来源页面/图片，并可提取页面内一层图片链接 | **当前属于 AI 工具链，并非普通封面显示自动联网。**若无 AI 版本仍保留或独立提供封面获取，该功能仍联网；若完整移除该链则不保留。不能只删除生成式聊天就认为它消失 |
| AI 请求、搜索/生成图、认证与账户模型列表 | [AITransport](../../../ios/Moonread/AI/Providers/AITransport.swift)、[AINativeExecutor](../../../ios/Moonread/AI/Providers/AINativeExecutor.swift)、[AIAuth](../../../ios/Moonread/AI/Providers/AIAuth.swift)、[AIConnection](../../../ios/Moonread/AI/Providers/AIConnection.swift) 访问供应商/自定义端点，执行授权、token 刷新、模型发现、内容请求与图片下载；AI 界面另有来源网页跳转 | 无 AI 版本须明确移除这些完整功能链；本次没有批准代码裁剪或替换方案 |
| 公共模型目录及后续刷新 | [AIModelCatalog](../../../ios/Moonread/AI/Providers/AIModelCatalog.swift) 请求 `models.dev/api.json`；[AIConnectionService](../../../ios/Moonread/AI/Providers/AIConnectionService.swift) 的 `refreshCatalogsIfNeeded` 在 AI 设置/会话界面触发，激活后 [MoonreadApp](../../../ios/Moonread/App/MoonreadApp.swift) 回到前台也会检查刷新 | 无需先配置 AI 连接即可触发目录请求；不能只停用发送按钮，遗漏目录加载及已激活的生命周期刷新 |

核查范围覆盖当前应用源码中的直接 HTTP 请求、云服务、StoreKit、系统文件/照片传输及外部网页入口；未把测试 fixture URL 当作生产联网功能。未来版本仍须按最终代码和依赖复核，不能把这份清单当作“无任何其他网络流量”的证明。

### 欧盟

用户已决定首发包含欧盟，DSA 商家声明已提交审核中；尚未视为审核通过。若为 trader，联系方式会公开且需要核验；不在本文记录住址、证件、银行信息。即使不分发 EU，Apple 当前流程仍要求声明 trader 状态。[DSA 说明](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements)

## 8. 截图与素材计划

**代理可做：**用最终候选版本的模拟器、虚构且有权使用的数据制作；本轮仅给方案，不构建或占用手机。

Apple 当前规格页要求 iPhone Dynamic Island 中等显示尺寸及支持 iPad 时的 13 英寸截图；页面同时保留其他尺寸和缩放规则。为减少后台尺寸兼容问题，建议准备下列原生截图组，并以实际上传槽位为准，不沿用“只交 6.5 英寸”旧清单。[截图规格](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

| 截图组 | 建议竖屏像素 | 内容 |
| --- | --- | --- |
| iPhone 中等 Dynamic Island | 1206 × 2622（亦接受 1179 × 2556） | 必备主组，4–6 张 |
| iPhone 大屏 Dynamic Island | 1320 × 2868 | 主组完成后补同场景，若后台可正确缩放可减少重复制作 |
| iPad 13 英寸 | 2064 × 2752（亦接受 2048 × 2732） | 使用真实 iPad 布局，不能放大 iPhone 冒充 |

每尺寸 1–10 张，PNG/JPEG、无透明通道；横屏为对应宽高互换。首轮建议：正文浅色/深色、书架与真实文件管理、目录/搜索/批注、阅读统计、可选 AI（如最终审核访问已准备好）。首张突出正文空间；不以启动页或打赏页替代产品体验。中英分别检查界面和文案，不硬写价格，不显示真实姓名、小说库、Key、聊天或账户数据。App Preview 可不做。

IAP 审核截图另备一张真实“支持月读”页面，显示四档商品及不解锁说明；它是审核材料，不等于商店宣传截图，也不需要为了上传审核截图制作 IAP 推广图。

## 9. 打赏商品与付费协议

沿用[已批准方案](tip-jar.md)，四个均为 **Consumable**。商品创建本轮不执行；现有计划指定用户本人创建，代理提供字段表和创建后的只读一致性检查。

| Product ID | 中文名称 / English 草案 | 本地化描述草案 | 基准价（USD） |
| --- | --- | --- | --- |
| `dev.moonread.tip.star` | 一颗星 / A Star | 一点小小的心意 / A small token of appreciation | USD 0.29 |
| `dev.moonread.tip.tea` | 一杯茶 / A Cup of Tea | 谢谢你读到这里 / Thank you for reading with Moonread. | USD 0.99 |
| `dev.moonread.tip.snack` | 一份夜宵 / A Late-Night Snack | 陪作者熬一个晚上 / Support another late night of development. | USD 2.99 |
| `dev.moonread.tip.book` | 一本书 / A Book | 让月读继续写下去 / Help Moonread keep growing. | USD 6.99 |

四档基准美元价已由用户确认；首发排除中国大陆、包含欧盟（DSA 商家声明审核中）。尚未核实后台是否有精确档位，不得静默选近似价格。每项设置独立内部 reference name、显示名、描述、销售地区、价格和审核截图/说明；名称最多 30 字符、描述最多 45 字符。Product ID 保存后不能改，删除也不能复用，所以先与 worker 的常量逐字比对。[IAP 字段规则](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information)

- **需用户本人**：Paid Apps Agreement 接受、银行税务和商品税务类别确认。协议需 Active 才能进行真实 Apple sandbox IAP 测试；本地 StoreKit 配置成功不能证明后台已可用。[IAP 配置前置条件](https://developer.apple.com/help/app-store-connect/configure-in-app-purchase-settings/overview-for-configuring-in-app-purchases)
- **代理可做**：检查商品 ID、类型、地区、本地化、价格显示与购买状态；生产包不使用本地 StoreKit 数据模拟商品。四项无需订阅、会员权益、恢复按钮、账户系统或另建收款后台。应用不增加外部付款入口。
- **需用户本人**：Small Business Program 的资格申报。15% 仅在符合资格、获批并到生效时间后适用，不能把“申请后”写成已经生效；它不是创建应用或完成代码的前置条件。[小型企业计划](https://developer.apple.com/app-store/small-business-program/)
- **代理可做**：准备同一 draft submission 的 App 版本与三项 IAP；**需用户本人**最终提交。首个消耗型 IAP 必须随新 App 版本审核。[提交 IAP](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)

IAP review note 草案：`This consumable purchase is a voluntary tip to the developer. It does not unlock any content, features or entitlements. It can be purchased repeatedly from Settings → Support Moonread.`

## 10. 构建、TestFlight 与最小发布验证

**代理可做（后续授权）**：沿用 Nix/Xcode 工具链，在独立 derivedDataPath 构建、检查 archive、制作截图和测试报告；不借上架准备干扰 worker。**需用户本人**：账号认证、必要声明、最终审核提交及上线决定。

1. 冻结发布候选：核对版本/build、图标、简中/英文、最终能力、隐私链接与 manifests、许可证。移除诊断编译条件、探针入口及本地 StoreKit scheme 对正式运行的影响。当前 Apple 上传门槛为 Xcode 26+ / 对应 iOS 26+ SDK；部署下限 iOS 18 可继续保持，实际 archive 须复核。[当前上传要求](https://developer.apple.com/news/upcoming-requirements/)
2. 检查分发签名：App ID、iCloud 容器、生产推送授权、描述文件与 Release 配置；不是看到源 entitlements 就宣称分发授权正确。不自动重建/吊销证书。
3. **CloudKit 单独关口**：先只读核对 development/production schema 差异、record types/索引/权限及当前模型。正式部署先交协调者确认；不自动发布 schema，不因个人开发阶段允许重置而删除 production 数据。TestFlight 使用生产云环境，至少确认不会因 schema 缺失丢失/阻断用户数据；既有双设备未验收项保留在[验证记录](../engineering/verification.md)，不写“云同步已完整验收”。
4. 先少量内部 TestFlight：先满足上传、加密声明和协议；无必要不邀请大量外部测试者、不创建公开链接。内部最多 100 名有权限的 Connect 用户；外部最多 10,000 名且首个外测构建需 Beta Review；构建可测试 90 天。[TestFlight 概览](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
5. 模拟器自动化承担首次引导、本地导入/阅读、恢复/批注、浅深色/iPad布局、断网及 StoreKit 成功/取消/等待/失败回归。**用户最后自愿试用一次真实 TestFlight**：开书与恢复、从 Files 导入、按自己需要核对 iCloud、打一笔 sandbox tip 并取消一笔。TestFlight IAP 自动处于 sandbox，不为此自动退出用户的媒体购买账号；特殊状态继续用本地 StoreKit，确需专用沙盒账户时由用户自行操作。[TestFlight IAP 环境](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight)
6. 外部网站/App Review 访问、隐私及实际首发地区的合规事项未定时，可以继续准备素材，但不能宣称“可提交”。中国大陆已排除，其备案/AI 许可确认不阻断其他地区首发；提交前核对 App 和 IAP 的地区配置确实排除中国大陆。完成后把具体版本、销售地区、四项商品和声明交给用户本人核对并点提交；建议获批后手动发布，避免审核通过即意外上线。

无障碍营养标签只声明实际验证过的能力；最低系统、iPad、大字号和 VoiceOver 的必要关键路径由测试负责人确认，不凭现代 API 或模拟器启动成功推定支持。[Apple 无障碍标签说明](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels)

## 11. 交给协调者的下一步

1. **当前结果**：Dia self 已登录；Individual 会员；当前团队 No Apps；Bundle ID 已注册；Free Apps Active；Paid Apps New。代理未创建或修改网站配置。
2. **需用户本人**：Dia 已停在 Business → **Edit Legal Entity**；用户自行核对/补全并点击 **Save**，再进入 Paid Apps Agreement 查看及签署，并自行完成所需银行/税务与身份核验。代理不读取输入字段值或操作保存/提交；仅在用户完成后复核协议状态，本文和代理会话不接收凭据、验证码、银行或税务材料。
3. **需用户本人确认**：中文公开名称可用性、后台商品／协议及 DSA 审核结果；英文名、署名、邮箱和含欧盟的首发范围已确认；**中国大陆暂不发布已确认，不再列为待决定项**。代理据此完善可直接填入后台的材料。
4. **代理可做**：将隐私清单、政策入口、AI 许可/服务授权、CloudKit production、分发包检查列给实现/发布负责人；不在本轮直接改代码。
5. **代理可做**：先准备全部可审阅材料，再请求创建正式 App/商品、设置价格、发布站点、上传构建等对应授权。**需用户本人**最终提交审核，未到这一步前不要求用户长时间占用手机。

## 12. 上架前代码改动

更新：2026-10-16。A–C 已实现并完成受影响本地回归，D 的 DEBUG 初始化和只读检查材料已实现；未写入真实 CloudKit 开发库或部署生产。网站已获用户审阅授权并发布，四页与简单首页均可公开访问，四页 HTTP 200 和正文已核对。最低 iOS 18 运行、真实沙盒付款、生产云同步及 App Store Connect 最终提交仍为发布前验收。第 5 节的 App Privacy 工作表仍是草稿，须与本节最终实现使用同一份数据流清单，不能分别作出相反声明。

| 任务 | 修改范围 | 完成条件 |
| --- | --- | --- |
| A. 隐私清单与依赖处理 | 新增 `ios/Moonread/PrivacyInfo.xcprivacy`；工程 Resources；缺清单的 SDK 资源及必要的 Rust iOS 依赖配置 | App 与 SDK 均有准确理由、打包可见的 manifest；解决下述 SQLite `fstatfs` 缺口，不能只让 plist 校验通过 |
| B. AI 数据共享同意 | AI Service/Coordinator、独立原生服务入口、统一同意状态与页面、本地化和定向测试 | 所有内容发送路径经过同一授权规则；未同意时零内容请求；拒绝保留草稿和阅读功能 |
| C. 政策与支持入口 | `SettingsView.AboutView`、集中 URL 配置、本地化；后续获授权时制作独立静态站产物 | 中英页面与最终行为一致；正式 URL 可访问、无占位符；关于页与同意页面可打开隐私政策 |
| D. CloudKit 发布准备 | 开发 schema 初始化/核对所需的 DEBUG 测试入口（若当前 schema 不完整）、发布检查材料 | 六类正式用户模型及系统生成字段齐全；用户部署后以 production/TestFlight 验证；不是生产代码自动部署 |

### 用户决定（2026-10-16）

- iOS 改用系统 SQLite。
- swift-ai-sdk 与 Litext 上游无隐私清单时，维护只添加 PrivacyInfo 的最小 fork。
- 政策／支持页最初放在独立公开仓库 `suxiaoshao/moonread-site`（现迁入主仓库 `docs/site/`）；署名和邮箱已确认，四页内容已获审阅批准。
- AI 数据共享确认页按第 12.2 节方案直接实施。

以上为本轮已批准的实施范围；实现、验证与发布边界见 verification.md。

### 12.1 PrivacyInfo.xcprivacy：已核对的 API、理由及依赖

当前 App target 和本次锁定的 Swift 包中未找到 `PrivacyInfo.xcprivacy`。Swift 版本依据 `ios/Moonread.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`；本机 `build/DerivedData/SourcePackages/workspace-state.json` 中对应 checkout revision 一致。旧 checkout 中另有不再锁定的 SwiftStreamingMarkdown、swift-syntax 等，不能算成本次 App 的依赖。Rust 依据 `Cargo.lock` 及对应本机 registry 源码；没有执行依赖更新或构建。

#### 应用与 Rust 调用

| 类别 / manifest 值 | 代码证据及实际用途 | 应选理由与边界 |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategoryUserDefaults` | `Shared/Theme/Theme.swift:130,151` 的主题缓存；`Settings/Onboarding.swift:56–81` 的一次性提示；`Library/LibraryModel.swift:43,201` 的布局；`Data/ReaderService.swift:220,475,799` 的阅读偏好/文件来源书签；`AI/Providers/AIConnectionService.swift:41–43,105–107` 的连接配置；`Settings/ReaderPreferences.swift:78` 的 `@AppStorage` | **`CA92.1`**。都是应用自己的配置，测试 suite 也不是 App Group。不要添加 App Group、MDM 或 SDK wrapper 的理由。新增同意记录若使用本机 UserDefaults，也在此范围 |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `Library/LibraryService.swift:385–402` 在授权书架扫描中读取 `.contentModificationDateKey`；`crates/moonread-core/src/progressive.rs:419` 的 `File::metadata().len()`；Rust/SQLite 文件读写内部的 `stat/fstat/lstat` 也应覆盖，不能因只取大小而漏掉 | **`C617.1` + `3B52.1`**：前者覆盖应用私有数据库、缓存及容器文件元数据，后者覆盖用户经 Files 明确授权的外部文件/目录。自身 iCloud Documents 的系统容器访问须随最终包确认；不要把 CloudKit 的措辞扩成任意云盘授权。当前用途是读取/索引原件，不为指纹识别；无需额外添加仅显示时间戳的 `DDA9.1` |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `Statistics/ReadingStatistics.swift:171,198` 读 `systemUptime`；`Reader/Session/ReaderOpening.swift:10,38`、`Library/LibraryModel.swift:453` 计算准备/点按耗时；`crates/moonread-core/src/progressive.rs:590–641`、`library_tools.rs:347–353` 的 `Instant` 用于提交节流/时间预算 | **`35F9.1`**，应用内时间间隔和计时。Rust `Instant` 在目标标准库的具体实现需最终符号核对，不凭类型名新增另一理由。`statistics.rs:77–88` 使用单调时间差；正式同步/AI 统计只允许发送应用内阅读时长及本来来自 `Date` 的事件日期，不发送原始 uptime/开机时刻 |
| `NSPrivacyAccessedAPICategoryDiskSpace` | 应用 Swift 未发现剩余容量查询，但 **`libsqlite3-sys 0.38.2/sqlite3/sqlite3.c:46945–46958` 在 `__APPLE__` 分支调用 `fstatfs`**，读取 `f_fstypename` 判断 msdos/exfat；QNX 的 `fstatvfs` 分支不属于 iOS | **当前没有可以诚实选择的理由**。此代码没有向用户显示容量，也没有根据容量决定写入/清理，不能随手填 `85F4.1` 或 `E174.1`。按下述依赖任务处理后再决定 manifest，不能发布一份掩盖该缺口的清单 |
| `NSPrivacyAccessedAPICategoryActiveKeyboards` | 应用与锁定依赖的生产 Sources 未找到 `activeInputModes`；普通文本输入、键盘展示不等于枚举所有输入法 | 当前不声明；若最终包出现该调用，回到具体用途选理由，不能预填 |

`ReaderOpenDiagnostics.swift` 在诊断条件内记录原始 uptime；正式 Release 必须关闭 `READER_OPEN_DIAGNOSTICS`，确认没有自动上传该诊断输出。`AIMessageList`、MarkdownView 的 `CACurrentMediaTime` 用于流式动画/刷新；它不在 Apple 当前列出的两个 SystemBootTime API 名称之中，不把每个时钟函数都另算一项。应用本身已有 `systemUptime`，计时类别仍必须声明。

理由来源：[Apple required-reason API 列表](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)、[理由定义](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons)。上述是用途匹配，不是“某个库通常填什么”。

#### 第三方依赖的归属和具体处理

| 锁定依赖 | 已核对的生产代码 | worker 任务 |
| --- | --- | --- |
| swift-ai-sdk `c82deb28…` | `Sources/SwiftAISDK/Util/Now.swift:18` 读 `systemUptime`，流式实现只计算首 chunk/完成耗时；`Telemetry/GetTracer.swift:39–52` 默认关闭且使用 noop tracer；App 未配置遥测导出 | 计时用途为 `35F9.1`；保持不导出原始 uptime、不启用 SDK 遥测。**SDK 应提供自己的 manifest**，由 SwiftAISDK target 的资源随包分发；不能把静态链接当作只填 App manifest 的豁免 |
| Litext 3.6.4；MarkdownView 4.8.3；DisplayLink 3.0.1 | Litext `Sources/Litext/TextLabelView/Interaction/TextLabelView+Touches.swift:536` 使用 `systemUptime` 处理菜单时序；MarkdownView `MarkdownStreamView.swift:139,162,164` 及 LitextAnimation 使用动画时钟；DisplayLink 传递 display-link 帧时间 | Litext 的用途为 `35F9.1`，应补该 SDK 自己随 Litext target 打包的 manifest；其余时钟不盲目扩充理由。最终按实际 target 链接结果检查，不为 catalog/benchmark 示例打包清单 |
| SwiftMath 1.7.3、LRUCache 1.3.0、swift-collections 1.7.2、swift-cmark 0.9.0、swift-argument-parser 1.8.2 | 本次 Sources 检索未发现新增上述 required-reason 调用；argument-parser 的 CLI target 不等于 App 运行时依赖 | 维持锁定版本，最终检查实际被链接的产品；这不是对未来版本或所有依赖代码的永久豁免 |
| rusqlite 0.40.2 / libsqlite3-sys 0.38.2（`bundled`） | SQLite `osStat/osFstat` 对 App 数据库/WAL 操作，适用文件元数据理由；Apple 分支另有上述 `fstatfs` 用途缺口 | **建议 iOS target 改用系统 SQLite**，其他构建目标可保留 bundled；检查 Cargo feature 是否仍被统一启用，确认最终 iOS 链接系统 `libsqlite3`、App 中没有嵌入这份 SQLite 的 `fstatfs` 调用。不要修改 Cargo cache 或删 SQLite 系统兼容代码。此方案交协调者确认后由 worker 实施 |
| 其他 Rust 依赖与 std | 锁文件对应源码均在本机可读。元数据 wrapper 出现在 camino/fs-err/glob，计时出现在 html5ever 宏；fastrand 的非系统随机回退、tempfile、UniFFI bindgen/CLI 等需按 target/feature 区分。libc/linux-raw-sys 的函数/结构声明不是 App 的运行证据 | 最终以 iOS normal/build/dev 依赖和符号区分：应用文件元数据与计时纳入前表，构建工具、测试、Linux/QNX 分支排除；若出现随机种子利用开机时间的实际 iOS 调用，不能套用“计时”理由，须改用系统随机路径。不要把锁文件中每个 API 名字都填进清单 |

SQLite 的问题有上游同类说明，并建议使用系统 SQLite；该讨论不是 Apple 对某个 reason code 的认可。[SQLite 上游讨论](https://sqlite.org/forum/info/d404fb0a8b3d9e74)。若 coordinator 不采用系统 SQLite，则此项保持未解决，须取得适用的官方理由或上游修正；**不能靠新增一个无关的容量检查来为原调用“凑理由”**。系统 SQLite 方案需在最低 iOS 18 和当前系统核对实际 SQLite 版本/编译选项，并针对现用 SQL、WAL、外键、并发读取、单书投影及导入运行已有关键回归；不把模拟器新系统通过当成最低系统验证。

manifest 实施要求：

1. 新建 `ios/Moonread/PrivacyInfo.xcprivacy` 并加入 **Moonread App target 的 Copy Bundle Resources**；当前工程使用显式 `PBXResourcesBuildPhase`，只把文件放进目录不够。不要加入小说、用户数据或凭据。
2. `NSPrivacyTracking = false`，`NSPrivacyTrackingDomains = []`。当前无广告/跨 App 追踪设计；AI 服务域名、models.dev 和图片 CDN 不能因有网络访问就放进 tracking domains。不得新增 ATT 来代替 AI 数据共享同意。
3. `NSPrivacyAccessedAPITypes` 至少写入三项：UserDefaults → `[CA92.1]`，FileTimestamp → `[C617.1, 3B52.1]`，SystemBootTime → `[35F9.1]`。DiskSpace 按上述缺口解决后的实际产物处理，不能把这三项当成当前代码已合规的结论。
4. **补 swift-ai-sdk 与 Litext 自有清单**：先查上游是否有仅补 manifest 的可用版本/提交；若没有，交协调者批准维护最小固定 fork，给实际使用 `systemUptime` 的 target 加 `PrivacyInfo.xcprivacy` 和 `Package.swift` 资源声明，计时理由为 `35F9.1`。SDK 无自己的数据收集/追踪时据实写 false/空数组，不能据此把 App 的 AI 数据流写成空。不要直接改 `SourcePackages/checkouts`，也不要无关升级 UI/AI API。Apple 明确 SDK 不能依赖宿主 App 或其他 SDK 的 manifest 申报自身 required-reason 使用；每个实际 executable/dynamic library 所在 bundle 也须有适当清单。App 总表与 SDK 资源逐一核对；若涉及 Apple 指定 SDK 清单，另核对供应链签名要求。[Apple 隐私清单要求](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
5. 本地 `plutil -lint` 检查格式，独立 Release archive 后核对 `.app/PrivacyInfo.xcprivacy`、嵌入资源、最终依赖和 required-reason 符号，并用 Organizer 生成 Privacy Report。报告与 App Privacy 字段逐项核对；不运行在用户手机上，也不因报告没有警告就跳过用途核对。

#### 收集数据声明：与 App Privacy 共用的实施草稿

不能用 `NSPrivacyCollectedDataTypes = []` 来表达“开发者没有服务器”：可选 AI 仍把内容交给第三方。**首发草稿按供应商可能保留内容、且请求关联用户所用供应商账户来声明**，不承诺零保留或匿名。对于下表实际存在的 App 数据流，每个条目使用 `NSPrivacyCollectedDataTypeTracking = false`、`NSPrivacyCollectedDataTypeLinked = true`、`NSPrivacyCollectedDataTypePurposes = [NSPrivacyCollectedDataTypePurposeAppFunctionality]`；这是基于当前功能的数据声明草稿，最终供应商政策和公开页面核对完成后才能作为提交声明。

| App Privacy 类型 / manifest 的 `NSPrivacyCollectedDataType` | 对应数据流；纳入条件 |
| --- | --- |
| Other User Content / `NSPrivacyCollectedDataTypeOtherUserContent` | 发送给 AI 的问题、会话历史/摘要、选区/正文、书目、批注及工具结果。自由文本可能包含个人信息；不把任意聊天文字强行分类成收集所有健康/财务数据 |
| Photos or Videos / `NSPrivacyCollectedDataTypePhotosorVideos` | 参考图、已有图片附件在后续模型/编辑请求中发送。仅从系统照片选择封面并在本机处理不属于此第三方收集路径 |
| Search History / `NSPrivacyCollectedDataTypeSearchHistory` | 联网搜索、找封面的查询发给所选服务；本地书内搜索不上传，不能把二者合并描述 |
| Product Interaction / `NSPrivacyCollectedDataTypeProductInteraction` | 用户要求统计分析时交给 AI 的阅读时段、时长和相关活动；本机阅读计时不是开发者遥测，也不是全量自动上传 |
| User ID / `NSPrivacyCollectedDataTypeUserID` | 第三方账户认证、账户关联标识及服务请求关联；代码中存在供应商账户身份，不能因无“月读账户”就声称所有请求未关联身份。API key/token 本身不写进公开材料或诊断 |

以上五项在 manifest 与 Connect 草稿中保持一致。若最终核实某条数据仅设备内处理，或第三方严格只实时处理且满足 Apple 的不构成“收集”条件，再同时从两处调整并记录证据；不能仅凭 BYOK、自建端点或用户可选就删掉声明。[Apple 数据类型键](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype)、[App Privacy 判断规则](https://developer.apple.com/app-store/app-privacy-details/)

以下单独处理，避免虚增或漏报：

- CloudKit 私有库/iCloud Documents：由 Apple 为用户提供同步；确认开发者和所用伙伴是否实际取得数据，再判定收集，不将全部同步自动算成开发者 Analytics。AI 本地库明确使用 `.none`，不通过月读 CloudKit 同步。
- StoreKit：现实现只在设备校验/finish，去重集合仅会话内；不收集银行卡或账单资料、不新增开发者购买历史库。不因此勾 Payment Info 或 Purchase History；若实现发生变化重新判断。
- 支持邮件：政策披露邮箱和用户主动发送的正文/附件；若使用外部邮件客户端，区别于 App 内上传表单。若后来在 App 内收集联系信息/诊断，要核对 Email Address、Customer Support 及相关诊断类型；只有满足 Apple 全部可选披露条件才可省略，不能写“反馈一律免报”。
- 公共模型目录、网页和图片站点可能保存 IP/请求日志：发布负责人应核对首发配置/供应商保留规则，不把 IP 自动当 Device ID，也不预先断言这些请求无收集。当前没有读取 IDFA、精确定位、联系人或向自有分析后台发事件的证据；不为猜测添加这些类型。

### 12.2 AI 首次共享：缺口与统一接入边界

**现状不足。**`AISettingsView.swift:75` 是可错过的静态帮助；`Onboarding.swift:15` 只说明主动使用会发送上下文。`AIService.send:444` 和 `startTask:283` 可直接入队并启动，`AIAgentCoordinator:40–56` 取得凭据后创建模型，`AIAgentRuntime:238–252,735–747` 发正文或历史摘要；`AINativeExecutor:27–43` 独立选择搜索/生图供应商。没有按接收方记录明确同意的统一入口。现有 `AIReadingReferences.confirmBook/confirmText` 与 Runtime 工具确认，只回答是否下载/准备正文，不能替代个人数据共享许可。

Apple 2025-11-13 更新明确把第三方 AI 纳入发送前告知和明确许可；隐私政策链接仍须在 App 内易于找到。[更新说明](https://developer.apple.com/news/?id=ey6d8onl)、[审核指南 5.1.1/5.1.2](https://developer.apple.com/app-store/review/guidelines/#privacy)

#### worker 的具体改法

1. **新增一份应用拥有的 `AIDataSharingConsent` 状态/服务**，由 `AIService` 持有并注入 Coordinator 与独立原生服务；不要在各 View、Transport 内各存一个布尔值。授权记录只在本机保存，不写 SwiftData 云模型，不存正文、密钥或 token。建议授权键包含连接 ID、实际供应商/协议身份、规范化 endpoint（含影响目的地的 base path）、账户授权代次、告知版本和已同意的数据范围。界面显示可识别的供应商名和真实 host；自定义连接名不能代替目的地。URL 用户信息/query 中的秘密不展示、不记录。
2. **发送按钮/快捷任务提交前先取得同意**：根据不可变的发送意图生成说明，覆盖本次问题、已有历史/自动摘要、阅读附件及本轮可用读取工具返回的数据范围。取消不创建新运行、不清空草稿、不隐藏原有附件。对已在运行的追加输入保留现有队列规则。配置、账户、内容范围在弹层期间变化时重新校验，不能把对 A 的批准用于 B。
3. **执行边界再次校验同一授权记录**：Coordinator 的配置解析/发请求前覆盖恢复、换供应商和自动摘要；`AINativeExecutor` 在搜索/生图实际供应商解析后、内容请求前使用同一服务。不要仅在 `AITransport.fetch` 中猜 JSON 内容，也不要靠 View 是否展示过帮助页授权。第一次允许聊天供应商 A，不等于同意搜索供应商 B 或生图供应商 C；网关需明确网关及其可能转发给模型服务的事实，不能只显示模型名。
4. **范围明确、按需扩展**：基本范围为问题与会话历史/摘要；增加阅读附件/书目与批注、阅读统计、图片等未获批准的数据类别时，补一次具体说明。工具可读取哪些用户数据应在首次任务说明中列明；不能只写“当前选区”却在随后发送全书检索结果/其他书目。已批准的同一接收方与范围无需每条消息重复弹窗；新增接收方或范围才询问。仅切换同一服务的模型、且目的地和范围未变，不无故重问。
5. **复用已有运行生命周期处理等待**：在 Runtime 状态中表达“等待数据共享确认”，UI 用同一 pending request 渲染 `.sheet(item:)`/明确按钮；请求带 owner 和 generation。不要给各任务再加失联的 `hasShownAlert`。停止、删除会话、拒绝或撤销时唤醒并取消等待；同一接收方并发请求可以合并展示但分别校验 owner，不得悬挂 continuation。原有“准备正文”和“应用写入提案”确认继续独立存在。
6. **提供撤销入口**：AI 设置的连接详情增加“数据共享许可”及“撤销许可”。撤销立即阻止新内容请求，取消该连接正在等待/执行的内容任务；已发给服务的数据无法追回，应明确说明。删除连接、退出/更换账户、改 endpoint 时使旧许可失效。首次安装和既有开发数据均默认无许可，不从“有 API key”或“有旧会话”推定同意。
7. **非内容网络单列告知**：连接认证、模型发现和 `models.dev` 刷新不发送小说/聊天，不应混成“已同意 AI 内容”。设置页说明其目的地与用途；不要在无操作时预热带正文请求。`find_cover` 会把书名/查询发给搜索服务，并请求结果网页/图片，首次找封面说明还须披露第三方来源站点会收到 URL/IP；来源列表展示真实域名。下载器不得把聊天正文/凭据附到这些站点或跨域重定向。若未来向额外站点发送个人内容，必须再经上述接收方和范围校验。

首个确认页面的文案模板（按实际范围删减，不能机械显示所有类别）：

> **允许将这些内容发送给「{服务名称}」？**
> 接收方：{实际域名}（自定义网关时说明可能转发给其模型服务）。
> 用途：{阅读问答 / 阅读统计分析 / 联网搜索 / 图片生成}。
> 本次及本连接后续同范围请求可能发送：你的问题、相关会话历史及自动摘要；{实际阅读附件与允许工具读取的书目/正文/批注}；{统计范围}；{图片}。服务可能按其政策保存和处理这些内容，并使用该账户的额度。
> 可查看月读隐私政策和服务商政策，并随时在 AI 设置中撤销。拒绝不会影响阅读。
> 按钮：**暂不发送** / **同意并发送**。

英文对应标题和操作：**Allow sharing this content with {service}?** / **Not now** / **Allow and send**。正文使用同一实际数据范围：`Recipient: {host}. Purpose: {purpose}. Requests may include your message, relevant conversation history and summaries, and the reading content, statistics or images listed here. The service may retain and process this data under its own policy and use your account quota. You can withdraw permission in AI settings. Declining does not affect reading.` 不使用预选同意、不以“继续”掩盖发送、不在未同意时发出试探内容请求。

改动文件建议：新增 `AI/Data/AIDataSharingConsent.swift` 与 `AI/UI/AIDataSharingConsentView.swift`；调整 `AIService.swift`、`AIAgentCoordinator.swift`、`AIAgentRuntime.swift` 的授权/等待边界、`AINativeExecutor.swift`、`AIConnectionService.swift` 的失效规则、`AISettingsView.swift`/`AIConnectionView.swift` 和字符串目录。采用一个模型与一个呈现组件，由实际持有会话/快捷任务的 sheet 承载；不要在根窗口强行叠加第二层不可见 sheet。

定向自动化验收使用注入 transport/内存 defaults 与现有 `MoonreadTests`、`MoonreadUITests`，不需真实账号/手机：首次同意前请求数为 0；取消保持草稿；同意后只向选中 endpoint 发一次；同范围重发不重问；换 endpoint/账户/供应商必问；历史压缩与恢复不能绕过；A 聊天触发 B 搜索/生图时 B 单独确认；新图片/统计范围补确认；等待期间停止/删除/并发/切换选择不会发到过期目的地。另核对中英、大字号、VoiceOver 和已有 sheet 中的按钮可达性。不要为了测试默认给 Release 注入已批准许可。

### 12.3 隐私政策、支持页及 App 入口

#### 文件与托管方案

政策与支持页源码现位于主仓库 `docs/site/`，通过 Zola 与 GitHub Pages 工作流发布至 `/moonread/`；仅发布网站构建产物，不发布开发文档。旧独立站 moonread-site 已迁移，仓库已于 2026-10-17 删除。站点中英页面无统计 SDK、第三方字体、广告、评论或登录。

App 中集中配置正式 URL：`https://suxiaoshao.github.io/moonread/privacy/`、`https://suxiaoshao.github.io/moonread/support/`、`https://suxiaoshao.github.io/moonread/en/privacy/`、`https://suxiaoshao.github.io/moonread/en/support/`。旧站四页曾逐页核对 HTTPS 200、中英互链与正文，无需账号；上述新 URL 待仓库公开后启用 Pages 并重新逐页核验；首发地区网络可达性与真实手机阅读仍需最终发布验收，HTTP 检查不等于可提交审核。生效日期为实际发布日 2026-10-16；App 联系入口显示公开邮箱 suxiaoshao@gmail.com。

`SettingsView.swift` 的 `AboutView`：在现有“数据与隐私”说明下加入 **隐私政策 / Privacy Policy**，紧邻新增 **帮助与支持 / Help & Support** 和 **联系开发者 / Contact the developer**。两份 URL 在一个小的 App links 配置中维护，按语言选择页面；使用 SwiftUI `Link`，邮箱采用 `mailto:`，不默认附加日志、书架或设备标识。AI 同意页复用政策 URL，并按服务提供方提供其政策链接；关于页入口与打赏无购买条件。网站不可达时仍可阅读，不能把接受整份政策作为开书前置条件。

以下四篇为用户审阅授权后的发布正文，B 项同意／撤销功能已实现并通过本地定向回归。它们说明实际功能，不代替服务商政策或 App Privacy 标签。

#### 隐私政策（简体中文正文草稿）

**月读隐私政策**
提供者：suxiaoshao
联系邮箱：suxiaoshao@gmail.com
生效日期：2026-10-16。

月读是一款阅读您自有 TXT 文件的应用，无需注册月读账户，也没有广告或自有服务器。我们使用数据来提供阅读、文件管理、您选择的同步及可选 AI 功能，不出售您的个人数据，不在应用中投放广告或进行跨应用广告追踪。

**您的文件和阅读数据。**小说保存在应用书架或您通过系统明确选择的目录。阅读位置、书签、批注、书目信息、封面、配色和阅读统计用于保存您的阅读体验。未开启相应云功能时，这些数据在设备上处理；月读不运行自有服务器。主动使用 AI 并授权时，相关内容会发送给您选择的第三方服务，详见下文。本地书内搜索不向搜索网站发送查询。

**Apple 同步和系统服务。**“我的书架”可使用应用的 iCloud 文件目录，外部书架也可能位于 iCloud Drive 或其他文件提供者。阅读数据 iCloud 同步是独立选项；开启后，相关记录和封面通过 Apple CloudKit 私有数据库同步。关闭阅读数据同步不会删除已有云数据，也不会关闭小说文件的 iCloud 同步。系统文件/照片选择器可能从云端取回您选择的文件或照片。Apple 和其他文件提供者按各自政策处理这些服务；系统设备备份亦受您的系统设置控制。

**可选 AI。**只有您主动启动相应任务并允许数据共享后，月读才向所选 AI 服务发送任务内容。发送前页面显示接收服务、实际域名、用途及数据范围，可能包括问题、相关聊天历史和自动摘要、阅读附件、工具返回的书目/正文/批注、统计或参考图片。聊天、搜索和生图可能使用不同服务。自定义网关可能继续转发给其模型服务。供应商可按自己的政策保存、使用或跨地区处理请求，服务也可能使用您的账户额度；月读无法替您保证其零保留或不用于训练。请勿发送您无权分享的内容或不愿交给该服务的敏感信息。

AI 会话和图片在设备上保存，不通过月读的 CloudKit 阅读数据同步。连接凭据保存在本机 Keychain，并用于您配置的服务认证。您可以取消任务、删除会话、退出或删除连接，以及撤销后续数据共享许可；这些操作不能收回已经发送给供应商的数据。供应商持有数据的查询、删除或保留期限请联系相应供应商。

**目录、搜索和封面。**进入 AI 设置/会话可检查公共模型目录 `models.dev` 和服务账户的可用模型；这些目录请求不附带小说和聊天正文。联网搜索会发送查询。找封面还会访问搜索结果的网页及图片站点，这些站点可能收到所请求的 URL、IP 和常规网络信息，并按各自政策保留日志。手动选择已有封面图片与联网找封面是不同操作。打开外部链接后适用目的站点的政策。

**打赏。**打赏自愿，不解锁功能。付款由 Apple StoreKit 处理，月读在设备上处理购买结果，不接触您的银行卡或银行账户资料。退款及 Apple 购买记录由 Apple 管理。

**支持与保存期限。**主动发邮件求助时，我们会收到您的邮箱及您选择提供的正文、附件，用于回应问题；请先移除密码、验证码、API key、token 和无关私人内容。支持材料仅保留处理问题和履行适用义务所需的时间；无需继续保留时删除。本地内容保留到您使用对应删除功能或系统清理；云服务、备份及供应商副本遵循相应服务的规则，卸载应用不等于删除所有云端或第三方副本。

**您的选择和联系。**您可以不使用 AI，关闭阅读数据同步，在统计设置中暂停或清除统计，并管理文件、书签、批注和会话。文件删除会作用于真实文件，涉及云目录时可能同步到其他设备；请按系统提示区分最近删除与永久删除。有关开发者实际持有的支持数据，或适用法律下的访问、更正、删除等请求，请联系 suxiaoshao@gmail.com。我们不能代为访问或删除您的 Apple/其他服务账户内数据。政策有重要变化时会更新本页；涉及新的共享目的地或范围时，应用会再次请求许可。

本政策页面托管于 GitHub Pages；访问页面时 GitHub 可能处理 IP 等请求信息，其处理遵循 [GitHub 隐私声明](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)。本网站不加入分析或广告脚本。

#### Privacy Policy（English draft）

**Moonread Privacy Policy**
Provider: suxiaoshao
Contact: suxiaoshao@gmail.com
Effective date: October 16, 2026.

Moonread reads TXT files that you provide. No Moonread account is required. The app has no ads or servers of its own. Data is used for reading, file management, the sync options you choose, and optional AI features. We do not sell your personal data, display advertising in the app, or track you across apps for advertising.

**Files and reading data.** Books remain in the app's bookshelf or folders you explicitly select through the system. Reading positions, bookmarks, annotations, book information, covers, color schemes, and reading statistics support your reading experience. Without the corresponding cloud features, this data is processed on your device. Moonread does not operate its own servers. When you choose AI and grant permission, relevant content goes to your selected third-party service, as described below. Searches within a book are local.

**Apple and file-provider services.** The built-in bookshelf can use the app's iCloud Documents folder. External folders may use iCloud Drive or another file provider. Reading-data sync is a separate option that uses Apple's private CloudKit database, including relevant records and covers. Turning it off does not delete existing cloud data or turn off iCloud file sync. System file and photo pickers may download the items you select. Apple and other providers process these services under their own policies; system backups also depend on your device settings.

**Optional AI.** Moonread sends task content only when you initiate the relevant task and permit sharing. Before sharing, the app identifies the recipient service and domain, purpose, and data scope. Requests may include your message, relevant conversation history and automatic summaries, reading attachments, book information or passages and annotations returned by tools, statistics, or reference images. Chat, search, and image generation may use different providers. A custom gateway may forward requests to its model providers. Providers may retain, use, or process data in other regions under their own policies and may charge your account. Moonread cannot guarantee their retention or training practices. Do not send content you are not entitled to share or sensitive information you do not want that service to receive.

AI conversations and images are stored on your device and are not included in Moonread's CloudKit reading-data sync. Connection credentials are stored in the device's Keychain and used to authenticate with your configured service. You can stop tasks, delete conversations, sign out or remove connections, and withdraw permission for future sharing. These actions cannot recall data already sent. Contact the provider about access, deletion, and retention of its copies.

**Catalogs, search, and covers.** AI settings and conversation screens may refresh the public model catalog at `models.dev` and available models for your service account. These catalog requests do not include book text or conversation content. Web search sends the query to your chosen service. Cover search also accesses result pages and image hosts, which may receive the requested URL, IP address, and ordinary request information and retain logs under their policies. Selecting an existing cover image is separate from online cover search. External websites have their own policies.

**Tips.** Tips are voluntary and unlock no features. Apple StoreKit processes payments. Moonread handles purchase results on the device and does not receive your card or bank-account details. Apple manages its purchase records and refund process.

**Support and retention.** If you email us, we receive your address and the message or attachments you choose to send, for responding to your request. Remove passwords, verification codes, API keys, tokens, and unrelated private information first. Support information is kept only as needed to resolve the request and meet applicable obligations, then deleted when no longer needed. Local content remains until removed through the relevant controls or system cleanup. Cloud services, backups, and AI providers have separate retention rules. Uninstalling Moonread does not delete all cloud or third-party copies.

**Your choices.** You can read without AI, turn off reading-data sync, pause or clear statistics, and manage files, bookmarks, annotations, and conversations. File actions affect real files and may propagate to other devices through cloud storage. Follow system prompts distinguishing Recently Deleted from permanent deletion. Contact suxiaoshao@gmail.com about support data held by the developer or applicable rights of access, correction, or deletion. We cannot access or delete data in your Apple or other service accounts on your behalf. Material policy changes will appear here; new sharing destinations or scopes will require permission in the app.

This website uses GitHub Pages. GitHub may process IP addresses and other request information under its [Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement). We add no analytics or advertising scripts to this site.

#### 帮助与支持（简体中文正文草稿）

**月读帮助与支持**
由 suxiaoshao 提供。联系：suxiaoshao@gmail.com。

**开始阅读。**月读阅读您自己提供的 TXT，不提供在线书城。在书架使用导入操作，从“文件”中选择 TXT；也可以添加已授权的文件夹作为书架。进入正文后轻点页面显示阅读控制，在目录、搜索、书签和批注中定位。文件名、移动及删除操作会影响实际文件。

**iCloud 或文件暂时打不开。**先在系统“文件”中确认来源仍可访问、文件已下载，并检查网络、iCloud 状态和可用空间。外部书架失去授权时使用重新连接。阅读数据同步位于设置中，它与小说文件同步独立；开启后由系统自动调度，并非即时同步。不要为排查问题先卸载应用或删除云文件。

**阅读位置、批注与统计。**重新打开同一正文会尝试续读；修改原文可能产生新的内容身份。删除书架原件与删除阅读数据是不同操作。统计设置可暂停记录或清除统计；清除统计不会删除小说正文。请在确认前阅读删除范围。

**AI 可选。**在 AI 设置中选择服务、连接和模型。首次共享会说明目的地和数据范围；不同搜索/生图服务可能分别询问。拒绝不影响阅读。服务不可用时检查连接、网络、权限和额度；不要在邮件中发送 API key 或 token。AI 输出可能有误，请自行核对；可在连接设置中撤销后续共享许可。

**支持月读。**设置中的打赏完全自愿，可以重复购买，不解锁内容或功能。若商品暂不可用可稍后重试；取消付款不产生打赏。等待批准或网络处理中不代表付款失败，请以 Apple 状态为准。消耗型打赏不是可恢复的权益。退款请使用 [Apple 的退款入口](https://reportaproblem.apple.com/)。

**反馈问题。**请发送应用版本、iOS 版本、设备型号、操作步骤、预期结果和实际结果；如需截图，请遮盖个人书名、正文、对话和账户信息。无需主动发送整本小说、数据库或系统日志；我们也不会索要密码、验证码、支付信息或密钥。隐私问题请查看[隐私政策](https://suxiaoshao.github.io/moonread/privacy/)或写信至 suxiaoshao@gmail.com。

#### Help & Support（English draft）

**Moonread Help & Support**
Provided by suxiaoshao. Contact: suxiaoshao@gmail.com.

**Start reading.** Moonread reads TXT files you provide; it does not offer an online bookstore. Use Import on the bookshelf to choose TXT files from Files, or add a folder you authorize. Tap the reading page to show controls, then use chapters, search, bookmarks, and annotations to navigate. Renaming, moving, and deleting affect real files.

**iCloud or unavailable files.** Check in the system Files app that the source is accessible and the file is downloaded. Check your connection, iCloud status, and available storage. Reconnect an external bookshelf if its permission has expired. Reading-data sync is a separate setting from file sync and is scheduled by the system, not instantaneous. Do not start troubleshooting by uninstalling the app or deleting cloud files.

**Positions, notes, and statistics.** Reopening the same book content attempts to resume your position. Editing the source text may create a new content identity. Removing a source file and deleting reading data are separate operations. You can pause or clear reading statistics in their settings; clearing statistics does not delete the book text. Read the stated scope before confirming deletion.

**Optional AI.** Select a service, connection, and model in AI settings. The app explains the destination and data scope before initial sharing; separate search or image services may require separate permission. Declining does not affect reading. For connection problems, check the network, provider access, and quota. Never email API keys or tokens. AI output can be inaccurate, so check important information. You can withdraw permission for future sharing in connection settings.

**Support Moonread.** Tips in Settings are optional, repeatable purchases that unlock no content or features. Retry later if products are unavailable. Cancelling a purchase does not make a tip. A pending approval or network operation is not proof of payment failure; follow Apple's purchase status. Consumable tips do not create a restorable entitlement. Request refunds through [Apple](https://reportaproblem.apple.com/).

**Report a problem.** Email the app version, iOS version, device model, steps, expected result, and actual result. Redact private book titles, passages, conversations, and account information in screenshots. Do not send entire books, databases, or system logs unless a specific, limited diagnostic request has been agreed. We do not ask for passwords, verification codes, payment details, or keys. See the [Privacy Policy](https://suxiaoshao.github.io/moonread/en/privacy/) or contact suxiaoshao@gmail.com for privacy questions.

### 12.4 CloudKit 生产 schema：步骤、责任与不可逆点

**当前只确认代码目标，未核查线上 schema 是否已部署。**容器固定为 `iCloud.dev.moonread.Moonread`；`UserDataService.swift:23–25` 在启用同步时使用私有库。`Data/UserData.swift:118` 的 schema 有 `UserPosition`、`UserValue`、`AnnotationOperation`、`ReadingFact`、`StatisticsClear`、`UserCover` 六类；封面 `bytes` 使用 external storage。AI 的四类会话模型明确 `.none`，不应为它们建云 schema；Rust 正文/缓存也不部署到 CloudKit。

| 顺序 | 实施内容 | 谁执行 / 边界 |
| --- | --- | --- |
| 1 | 冻结这次候选模型及签名配置，列六类模型的字段/类型、系统元数据及 external storage；核对 App ID 关联容器、正式包 iCloud/推送授权 | 代理可做本地材料和构建检查；登录/身份授权由用户本人。不要只根据 Swift 模型名手写云记录名 |
| 2 | 只读查看 CloudKit Console → CloudKit Database → 指定容器，分别查看 Development/Production 的 schema、索引和权限；只记录结构，不读私人记录值 | 代理可在后续授权时导航核查；本轮未执行。发现历史生产模型时暂停假定“可随意重置”，先分析兼容影响 |
| 3 | 若开发 schema 不完整，按 Apple 的 SwiftData 官方流程用同一 SwiftData schema 生成 Core Data model，临时 `NSPersistentCloudKitContainer` 初始化 development schema，再卸载该临时 store 后建立正常 SwiftData 容器。仅 DEBUG/显式测试入口，使用隔离测试 store，不让两套持久栈同时打开同一文件 | worker 可准备代码与测试方案；**真正写入开发云环境须另获授权**。不要依赖“读过一本书”碰巧创建了所有类型，也不要用正式用户记录填充 schema。当前源码未见 `initializeCloudKitSchema` |
| 4 | 核对六类实际生成记录、系统所需字段/索引、封面资源及权限；查看待部署差异。只私有库同步，不为了排错开放 public 数据或额外角色权限 | 代理可准备对照材料；开发环境造数/改 schema 在授权范围执行。生成的是结构，不自动证明读写同步正确 |
| 5 | Console 左侧 **Deploy Schema Changes**，检查准确容器和全部待部署变化 | 代理可导航到差异预览；**最终点击 Deploy 由用户本人**。先提供具体可审阅差异，不让用户盲签 |
| 6 | 用户部署后只读核对 Production；独立分发构建/TestFlight 使用生产容器，验证新记录写入、读回、修改/删除传播以及封面。开发与生产数据不互相复制；iCloud Documents 文件也不由这次 schema 部署迁移 | 代理可在后续授权后做检查与自动化；实际账户登录由用户本人，少量最终试用自愿。无可用的第二个同账户环境时，如实保留跨设备缺口，不宣称完整验收 |

官方 SwiftData 初始化步骤见 [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)；worker 应采用该文档的生成模型/临时 store 方法，不建立手工双 schema。此开发辅助入口不能进入 Release，也不能在生产自动调用初始化。

**不可逆边界：**部署把开发的记录类型、字段和索引合并到生产，**不复制记录**；生产不能按开发重置规则删除已有记录类型/字段或任意改类型。部署后回滚 App 二进制不会回滚 schema。首发后模型演进必须尊重生产数据，不再把“开发阶段可以改 schema”用于真实用户库。部署前若发现无关的旧开发类型，不要一并发布；先说明差异并确定处置，不能点击 Reset Environment 清理用户数据。权限扩大、删除云记录、部署 production 均不由代理在本任务中执行。[Apple 部署规则及 Console 步骤](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)

此项交付证据仅记录模型/环境、部署确认和受影响验证结果，不记录账号、私人数据、银行税务或凭据。完成 A–D 后，再对正式 archive、公开页面和 App Privacy 做一次一致性检查；本节任务完成前不得标记为“已可提交审核”。

### 2026-10-16 补充发布决定

- 版权字段：© 2026 suxiaoshao；公开支持邮箱：suxiaoshao@gmail.com。
- 英文名：Moonread: TXT Reader；首发包含欧盟、排除中国大陆，DSA 商家声明审核中。
- 四档 USD 基准价：star 0.29、tea 0.99、snack 2.99、book 6.99；页面价格仍以 StoreKit 为准。
- 打赏说明：月读没有广告，也没有自己的服务器，你的书和阅读记录只留在你的设备和 iCloud 里。可选 AI 仍经用户同意向所选第三方发送内容，政策单独说明此边界。
- 政策／支持站已迁入 `docs/site/`；仓库公开后发布到 `/moonread/`；旧 moonread-site 仓库已于 2026-10-17 删除。
