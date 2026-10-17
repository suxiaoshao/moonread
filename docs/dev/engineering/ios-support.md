# iOS 支持范围与最新系统设计

样本查询日期：2026-09-27；本轮文档整理未重新查询商店。以下版本数据是该日调研快照，不作为持续更新的产品版本清单。

状态：默认采用苹果最新正式版设计规范与原生组件。用户日常 iPhone 运行 **iOS 27**，个人偏好最新版本，同时需要考虑其他用户。工程采用 **iOS 18.0** Deployment Target，使用 Xcode 27 构建；部署配置与[实际验证](verification.md)分开记录。

## App Store 调研样本

以下为查询当日 Apple App Store 产品页的版本和 iPhone 兼容性要求。国内样本使用中国区，国外及独立/小团队样本使用美国区。每行链接都是对应的官方商店页。

这是代表性样本，不是市场份额统计。“最低 iOS”只表示查询时商店列出的安装要求，不表示该系统仍获安全维护、所有功能都可用，或旧版本的服务会一直可用；不同地区和后续更新可能不同。

### 国内大厂

| App | 厂商/开发者 | 当前版本 | 最低 iOS | 地区与来源 |
| --- | --- | --- | --- | --- |
| 微信 | 腾讯 / WeChat | 8.0.78 | 15.0 | [中国区](https://apps.apple.com/cn/app/%E5%BE%AE%E4%BF%A1/id414478124) |
| QQ | 腾讯 | 9.3.70 | 15.0 | [中国区](https://apps.apple.com/cn/app/qq/id444934666) |
| 支付宝 | Alipay (Hangzhou) Technology | 12.12.30 | 13.0 | [中国区](https://apps.apple.com/cn/app/%E6%94%AF%E4%BB%98%E5%AE%9D-%E4%BD%A0%E7%9A%84ai%E7%94%9F%E6%B4%BB%E4%BC%99%E4%BC%B4/id333206289) |
| 淘宝 | 浙江淘宝网络有限公司 | 10.66.30 | 13.0 | [中国区](https://apps.apple.com/cn/app/%E6%B7%98%E5%AE%9D-%E4%B8%87%E8%83%BD%E7%9A%84%E6%B7%98%E5%AE%9D/id387682726) |
| 抖音 | Beijing Douyin Technology | 40.6.0 | 15.0 | [中国区](https://apps.apple.com/cn/app/%E6%8A%96%E9%9F%B3/id1142110895) |
| 微信读书 | 腾讯 | 10.2.2 | 15.0 | [中国区](https://apps.apple.com/cn/app/%E5%BE%AE%E4%BF%A1%E8%AF%BB%E4%B9%A6/id952059546) |

### 国外大厂

| App | 厂商/开发者 | 当前版本 | 最低 iOS | 地区与来源 |
| --- | --- | --- | --- | --- |
| WhatsApp | WhatsApp Inc. | 26.37.76 | 15.1 | [美国区](https://apps.apple.com/us/app/whatsapp-messenger/id310633997) |
| YouTube | Google | 21.38.3 | 17.0 | [美国区](https://apps.apple.com/us/app/youtube/id544007664) |
| Chrome | Google | 154.0.8037.55 | 18.0 | [美国区](https://apps.apple.com/us/app/google-chrome/id535886823) |
| Gmail | Google | 6.0.260914 | 18.0 | [美国区](https://apps.apple.com/us/app/gmail-email-by-google/id422689480) |
| Spotify | Spotify | 9.1.86 | 16.1 | [美国区](https://apps.apple.com/us/app/spotify-music-and-podcasts/id324684580) |
| Outlook | Microsoft | 5.2637.1 | 26.0 | [美国区](https://apps.apple.com/us/app/microsoft-outlook/id951937596) |

### 独立开发者与小团队产品

| App | 开发者 | 当前版本 | 最低 iOS | 地区与来源 |
| --- | --- | --- | --- | --- |
| Things 3 | Cultured Code | 3.24.2 | 16.4 | [美国区](https://apps.apple.com/us/app/things-3/id904237743) |
| Bear | Shiny Frog | 3.0 | 15.6 | [美国区](https://apps.apple.com/us/app/bear-markdown-notes/id1016366447) |
| GoodLinks | Ngoc Luu | 4.0.3 | 17.0 | [美国区](https://apps.apple.com/us/app/goodlinks/id1474335294) |
| Unread | John Brayton / Golden Hill Software | 5.0.1 | 18.0 | [美国区](https://apps.apple.com/us/app/unread-an-rss-reader/id1363637349) |
| Reeder（新版） | Silvio Rizzi | 2026.9 | 17.0 | [美国区](https://apps.apple.com/us/app/reeder/id6475002485) |
| lire | Kunal Sood | 7.0.1 | 15.6 | [美国区](https://apps.apple.com/us/app/lire-rss-reader/id1531976425) |

这里按个人发布者及独立/小团队产品归类，不断言它们当前的具体团队人数。团队背景参考：[Cultured Code 自述](https://culturedcode.com/things/blog/2013/12/a-million-things/)、[Shiny Frog 自述](https://blog.bear.app/2018/05/the-who-what-and-why-of-bear/)、[Golden Hill Software](https://www.goldenhillsoftware.com/about/)；前两篇是历史背景，不能用于推断今天的人数。Reeder 新版与 Reeder Classic 是不同商店条目，本表只统计新版。

### 对选型有用的结论

- 国内这组样本下限为 13/15；国外这组为 15.1–26；独立/小团队这组为 15.6–18。不存在一个统一的“大厂标准”或“独立 App 标准”。
- 商店下限本身不能证明 App 使用了哪一代设计。需要另外看版本说明或实机行为。
- Things 的版本说明明确记录 iOS 26 的界面与玻璃按钮更新，以及 iOS 27 的系统适配，但最低仍为 16.4；lire 明确记录 iOS 26 Liquid Glass、iOS/iPadOS 27 适配，最低仍为 15.6。这说明采用最新设计与保留旧系统支持可以同时做到；不表示新版功能在旧系统上全部存在。
- Moonread 的作者偏好最新系统，同时希望服务其他用户。当前没有证据要求直接复制大型存量 App 对 iOS 13/15 的覆盖范围，也不应仅按作者自己的 iOS 27 设门槛。选型应同时考虑覆盖范围、功能收益和维护成本。

## 苹果会自动兼容哪些部分

需要区分三个概念：**构建 SDK**决定可以编译哪些 API，**Deployment Target**决定允许安装的最低系统，**运行系统**决定实际可调用的 API 和呈现的系统材质。

苹果说明：使用最新 SDK 构建，标准 SwiftUI/UIKit 控件在新系统上会采用最新外观。新系统专属 API 则需使用 `#available` / `@available` 管理可用性，并为较旧系统提供实现。[采用 Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[按系统版本运行代码](https://developer.apple.com/documentation/xcode/running-code-on-a-specific-version)

| 场景 | 系统会做什么 | Moonread 仍需做什么 |
| --- | --- | --- |
| 使用最低版本已支持的原生导航、列表、表单、按钮、菜单和弹层 | 在各系统上使用对应的原生实现与样式；最新系统可采用新设计 | 检查布局、滚动遮挡、选择与无障碍，减少强制背景和固定尺寸 |
| 调用较新系统才提供的组件或 modifier | SDK 给出 API 可用性信息，编译器检查使用位置 | 按运行版本分支，旧系统保留等价的基础功能；系统不会补出缺失的 API |
| 使用自定义 Liquid Glass 控件 | 支持的系统提供材质实现 | 26 以下改用原生普通控件或适度系统材质；不自己重绘一套玻璃模拟器 |
| 新版 SF Symbols 或特殊图标材质 | 系统渲染支持的符号和材质 | 选可用符号或提供替代；图标资源也需按最低目标验证 |
| 读取、排版、进度恢复与 Rust 桥接 | 不会替应用完成业务和跨语言兼容 | 两种阅读模式及核心功能在最低系统仍须完整，依赖与 Rust 构建目标保持一致 |

调研时本机实读为 **Xcode 27.0（27A266a）/ iOS SDK 27.0**。当时 Apple 的 Xcode 27 支持表允许 iOS 15–27 的 Deployment Target，所以使用最新 Xcode 不等于最低必须 iOS 27。[Xcode 支持表](https://developer.apple.com/xcode/system-requirements)

本机 iOS 27 SDK 的接口声明也可验证：`NavigationStack` 从 iOS 16 可用，`ScrollPosition` 从 iOS 18 可用，`glassEffect` / `GlassEffectContainer` 从 iOS 26 可用。新版本 API 是逐项判断的；这不直接替正文组件决定采用哪个滚动/分页实现。

## Moonread 的工程基线

**当前工程：最低 iOS 18.0，使用最新正式版 Xcode/SDK，以最新苹果设计与标准组件为默认方向。** 选择依据是本项目的覆盖范围、原生组件能力和维护成本。

| 方案 | 取舍 | 当前建议 |
| --- | --- | --- |
| iOS 15/16/17 起 | 覆盖更多旧系统，也扩大组件回退和验证范围 | 当前没有明确覆盖需求，不作为首选 |
| iOS 18 起 | 保留两代旧系统范围（18 → 26 → 27），可使用一批较现代的 SwiftUI 能力；26/27 上采用新设计 | 推荐的平衡方案 |
| iOS 26 起 | 统一在 Liquid Glass 时代，减少 26 之前的材质/API 回退 | 若明确只服务较新设备、优先减少维护，可选；不等于所有 27 API 自动可用 |
| iOS 27 起 | 版本分支最少，但排除仍运行 26 的设备 | 目前没有必须依赖 27 的基础阅读需求，不建议仅为最新外观设此门槛 |

日常设备已确认为 iOS 27，可以作为最新系统真机验收基准；iOS 18/26 的兼容验证仍需单独安排。测试资源不足时应明确减少支持范围，不能把未经验证的系统写成已支持。

## 已确认的设计与实现原则

- 默认采用最新正式版 HIG、SwiftUI/UIKit 标准组件与系统导航材质，跟随新系统的设计演进。
- 同一套业务和页面结构按系统能力呈现；旧系统使用其原生样式，不要求外观逐像素一致。
- 在满足支持范围的前提下优先新 API；确属新系统专用的能力集中做可用性判断与回退，避免将判断散落到所有页面。
- 新设计主要用于导航、工具栏、菜单、按钮和弹层。正文使用稳定的不透明纸色和清晰文字；App 与阅读可独立选择明暗和配色，规则见[主题模型](../design/themes.md)。
- 不为模仿旧版外观冻结系统样式，不为追求玻璃外观把正文或所有自定义控件都加特效。
- 最新正式版 SDK 与最低目标分开维护；未来提高下限前再核对实际设备、依赖要求和兼容成本，不自动逐年抬高。

## 按推荐基线实施时的验证范围

- iOS 18：最低版本上的启动、目录授权、双模式阅读、选择、搜索、恢复进度和原生 UI 回退。
- iOS 26：Liquid Glass 初代引入后的工具栏/弹层布局、主题和安全区域。
- iOS 27：最新系统主流程、组件变化、图标与最新 API 分支。
- 实机优先覆盖日常使用设备；其余可先结合模拟器。声明支持前仍需记录最低版本的实际验证结果。
- 已有验证主要使用 iOS 27 模拟器与日常 iPhone。实际结果和未覆盖范围见[验证记录](verification.md)，工具链见[开发环境](development.md)。`.icon` 离线渲染和工程部署配置不能替代最低系统运行验证。
