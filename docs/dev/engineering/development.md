# 开发环境、构建与试用

要求 Nix（启用 `nix-command` 和 `flakes`）及本机 Xcode 27。最低部署版本与 API 回退见[iOS 支持策略](ios-support.md)，已执行的检查和未覆盖范围见[验证记录](verification.md)。

## 进入环境

```sh
nix develop
cargo test --locked -p moonread-core
open ios/Moonread.xcodeproj
```

`flake.nix` 声明 Rust、Cargo、Clippy、rustfmt 和 iOS 标准库，`flake.lock` 固定输入版本。不另加安装/构建脚本，也不在构建时执行 `rustup target add`。

| 平台 | Rust target |
| --- | --- |
| Apple Silicon 模拟器 | `aarch64-apple-ios-sim` |
| Intel 模拟器 | `x86_64-apple-ios` |
| iPhone 真机 | `aarch64-apple-ios` |

Nix 管理开发依赖；本机 Xcode 提供 Apple SDK、Clang、链接器、资源编译、签名及设备运行。macOS 使用 `mkShellNoCC`，移除 Rust overlay 隐式传播的 Nix 编译器和目标库，避免与 Xcode SDK 混用。iOS App 不宣称是完全可复现的 `nix build` 产物；Linux 环境仅供 Rust 核心开发。个人签名配置与小说不进入 Nix store。

更新依赖显式执行 `nix flake update` 并检查锁文件变化；构建不会自行更新锁文件。新增 Nix 文件须加入 Git 跟踪后供本地 flake 使用，不能用 `path:.` 把含本地凭据的整个工作目录作为输入。

项目级 [SwiftUI Expert skill](../../../.agents/skills/swiftui-expert-skill/SKILL.md) 用于 SwiftUI 开发与审阅。来源为 [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill)，固定 `4.2.0` / `9692ec5c3e78a0acc7757de2dbe8e64e519a72fb`，保留上游 [MIT 许可](../../../.agents/skills/swiftui-expert-skill/LICENSE)；更新时显式选择版本。

## 本地化

界面支持简体中文 `zh-Hans`、台湾繁体中文 `zh-Hant` 与英文 `en`。`ios/Moonread/Localizable.xcstrings` 的源键保留简体，繁体翻译按 OpenCC `s2twp` 生成并人工校正台湾用语（設定、檔案、資料夾、字型、匯入、複製、回饋）。不要转换源键、格式占位符、协议／模型 ID、用户命名或小说正文；英文数量文案保留单复数。新增文案同步补齐三语，不直接把中文动态 String 当界面值。

可在常规 Xcode 构建中加 `SWIFT_EMIT_LOC_STRINGS=YES`，核对编译器提取的键，尤其插值和自定义视图的标题；测试用的 `full/half/compact` 等诊断值不翻译。显示名与 iCloud 容器名在各语言的 `InfoPlist.strings` 中声明（英文 Moonread、繁体月讀、简体月读），工程地区只保留规范的 `zh-Hans`／`zh-Hant`。`AppStorePrivacyTests` 验证随包资源、格式参数及名称；英文／繁体巡检须区分界面漏翻与保持原样的书籍／连接内容。

## 分支与协作

- `main` 的 App 代码始终对应 App Store 最新发布版本，不承载下一版本 App 的日常开发；正式发布后，在对应提交打版本 tag（如 `v1.1`）。TestFlight 上传不等于 App Store 发布。
- `docs/site/**` 是版本分支规则的例外：隐私政策、支持页等版本所需的网站改动，在提交 App Store 审核前用小 PR 直接合进 `main`，由 Pages 即时部署，不等待 App 版本上线。网站检查通过后再合并；“main 等于线上版本”只约束 App 代码。
- 每个版本从 `main` 建立 `release/x.y`，在该分支开发。功能、修复与文档使用独立开发分支，PR 以当前 `release/x.y` 为目标，通过检查后 **squash** 合并。
- App Store 发布后，`release/x.y` 通过 PR 以普通 **merge commit** 合回 `main`，保留版本开发历史；发布回合使用普通 merge，不 squash 发布分支；下述已上线 hotfix 回合也使用普通 merge。
- 线上问题从 `main` 建立 `hotfix/x.y.z`，在该分支修复、打包并提审；App Store 上线后才通过 PR 以普通 merge 回 `main` 并打补丁 tag（如 `v1.1.1`），随后把 `main` 合进当前 `release/x.y`。补丁审核及等待上线期间不提前合回 main，确保 main 的 App 代码始终对应线上版本。
- PR 合入 `release/x.y` 或 `hotfix` 分支时，GitHub 不会根据 `Closes` 自动关闭 issue。合并后需手动关闭对应 issue，评论注明合入的分支与提交，并把看板状态改为「完成」。
- `main` 与 `release/**` 必须经过 PR、`Linux checks` 和 `iOS unit tests`，解决所有讨论，禁止强推和删除；维护者决定何时合并，不由工具自动合并。

发版清单（分支）：

- 新开 `release/x.y` 后第一件事：把所有 target 的 `MARKETING_VERSION` 改为 `x.y`，构建号 `CURRENT_PROJECT_VERSION` 递增到大于 ASC 已有最大号；Debug/Release 保持一致。

- 新开 `release/x.y` 时，同步修改 [Dependabot](../../../.github/dependabot.yml) 两个更新项的 `target-branch`，让常规依赖版本更新 PR 指向当前版本分支。
- Dependabot 安全更新 PR 总是开到默认分支 `main`，不受 `target-branch` 控制；收到后先把 PR 的 base 改成当前 `release/x.y`，按版本分支流程修复、验证和发布，不提前把 App 修复合入 main。紧急漏洞走上述 `hotfix/x.y.z` 流程，在补丁上线后再普通 merge 回 main 并同步当前 release。
- 当前常规依赖更新目标为 `release/1.3`，以 `.github/dependabot.yml` 为准；新版本分支切换后需核对实际配置。

签名配置、小说原件、构建产物与凭据不随代码推送。CI、仓库保护、模板及依赖更新见[仓库与持续集成](repository.md)，测试范围与推送前要求见[测试原则](verification.md#测试原则)。

## Xcode 与 Rust 集成

应用 Swift 源码的真实目录与显式 Xcode groups 对应，见[源码目录职责](architecture.md#swift-源码目录)。移动现有文件保留 file reference、Sources UUID 与 target membership；拆分文件单独加入应用 target，资源及签名配置继续使用原路径。

工程使用 Swift 6 及完整并发检查。在 Xcode 选择 `Moonread` scheme；从 Finder 打开工程也会通过 `nix develop --no-update-lock-file` 使用锁定 Cargo。

- 构建阶段执行编译与生成绑定两条工具调用。target、Debug/Release、链接路径声明在 [Rust.xcconfig](../../../ios/Rust.xcconfig)。
- UniFFI 从 [uniffi.toml](../../../crates/moonread-core/uniffi.toml) 读取输出名称；使用 `--no-format` 生成，避免每次构建格式化自动生成代码。
- 链接明确指定 `libmoonread_core.a`，避免同目录动态库被优先选中或把 Mac 路径带进 iPhone。
- Rust 输出位于 `build/cargo/`，绑定位于 `build/ios/Generated/<Configuration>/`，均不提交。模拟器只编译 `aarch64-apple-ios-sim`（arm64）。
- Xcode 构建缓存只用两份：模拟器构建和测试统一 `-derivedDataPath build/DerivedData`，真机构建统一 `build/DeviceDerivedData`。不按任务另建缓存目录；任务的日志、截图等验证记录可以放在 `build/<任务名>/`，任务合并后删除。
- 不使用 git worktree；在主目录切分支，共用 `build/cargo`、`build/DerivedData` 和 `build/DeviceDerivedData`。
- Nix 默认路径为 `/nix/var/nix/profiles/default/bin/nix`；非标准安装可在本地 `LocalSigning.xcconfig` 覆盖 `MOONREAD_NIX`。

首次运行需要下载工具链和 Cargo 依赖，之后复用缓存。

本机主模拟器仍使用 iOS 27.0 的 iPhone 18 Pro（`FFA6F448-E09C-4885-B59C-53C5E07185F5`）；当前 iOS 27.1 运行时仅支持 Duo，Duo 检查使用独立的 iPhone Duo（`6E42EBA5-DA26-4E2C-BF50-0CA9DC193893`），两个运行时均保留，CI 不变。

## 签名与安装

在 Xcode 登录 Apple 账户，在设备开启开发者模式。将 [LocalSigning.example.xcconfig](../../../ios/LocalSigning.example.xcconfig) 复制为 `ios/LocalSigning.xcconfig` 并填写自己的团队 ID；公共配置通过可选 include 读取它，本地文件已被 Git 忽略。项目不写入个人团队，证书和描述文件由 Xcode 管理。首次安装若要求信任个人开发者，在设备上完成确认。

安装、自动启动、真机交互或性能采集以当轮任务授权为准；安装成功不等于已启动、已运行测试或真机体验已验收。

发布后数据演进须保留旧数据并执行版本迁移，规则见[持久化演进](architecture.md#持久化演进与发布兼容)，不能通过要求用户删除重装解决格式升级。开发重置仅按当轮授权执行，不影响外部及 iCloud 小说原件；普通更新覆盖安装。

### 发布版本与构建号

App 的营销版本（`MARKETING_VERSION`，用户可见）和构建号（`CURRENT_PROJECT_VERSION`）以 `ios/Moonread.xcodeproj` 的工程设置为准，文档不记录具体数值。构建号使用单调递增的正整数，每次对外上传新构建时增加，不能因营销版本变化而回退或复用；Debug/Release 保持一致。Cargo crate 版本独立，不作为 App Store 版本。提交前核对两种配置、已上传构建号与持久化兼容/迁移回归。

### TestFlight 打包与上传

统一见[发布手册](release.md)：main 手动触发、branch+SHA、verify 后授权 upload，或本机同归档导出核验。

### 商店截图（独立 DEBUG 测试）

先对比本地上一版截图，只拍有变化的页面。使用独立的 `StoreScreenshots` scheme；它不进入日常 `Moonread` 测试计划的关键 UI 用例，不改变正常用户的书库、云设置或阅读数据。所有拍摄启动参数、原创样书和 App 处理代码均由 `#if DEBUG` 包围，Release 不识别这些参数（沿用 #83 的约定）。

从主目录执行一条命令；`-destination` 选择已经存在的模拟器，不能用设备组代替 UUID：

```sh
nix develop --no-update-lock-file -c xcodebuild \
  -project ios/Moonread.xcodeproj -scheme StoreScreenshots -configuration Debug \
  -destination 'platform=iOS Simulator,id=FFA6F448-E09C-4885-B59C-53C5E07185F5' \
  -derivedDataPath build/DerivedData -parallel-testing-enabled NO \
  -collect-test-diagnostics never \
  STORE_SCREENSHOT_DEVICE=iphone-medium \
  STORE_SCREENSHOT_LANGUAGES=zh-Hans,zh-Hant,en \
  STORE_SCREENSHOT_SCENES=01,02,03,04,05,06 \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES test
```

`STORE_SCREENSHOT_LANGUAGES` 传到测试进程后，按语言设置 App 的 `-AppleLanguages` / `-AppleLocale` 和对应原创正文、书名、批注；可只填 `zh-Hans`、`zh-Hant` 或 `en`。`STORE_SCREENSHOT_SCENES` 是逗号分隔的场景 ID，可只填 `01`，不会跑其他页面。未指定语言时默认三语，未指定场景时手机/iPad 默认 01–06，Duo 默认 01/02/03/06。

| 设备组 | 已有模拟器 | 原生 PNG 尺寸 | 阅读字号与准备 |
| --- | --- | --- | --- |
| `iphone-medium` | iPhone 18 Pro（上例 UUID） | 1206×2622 | 20 pt |
| `ipad-13` | iPad Pro 13-inch (M5)，`0F4A5FC1-EA80-4A88-81C2-D1650CFCA791` | 2064×2752 | 24 pt；先在系统「设置 → 多任务与手势」选择全屏 App，确认没有窗口缩放手柄 |
| `duo-outer` | iPhone Duo，`6E42EBA5-DA26-4E2C-BF50-0CA9DC193893` | 1398×2034 | 20 pt；DeviceHub 选择 Closed |
| `duo-inner` | 同一台 Duo | 2853×2007（横向） | 20 pt；先启动 Duo，在 DeviceHub 打开该设备窗口并选择 Open，确认横向内屏能显示 App，再执行命令；本轮不自动旋转/折叠 |

| 场景 | 内容 |
| --- | --- |
| 01 | 素白 + 宣纸（中），正文 |
| 02 | 纯黑夜读，无纹理，保留书签标记 |
| 03 | 豆沙绿 + 细麻布（中），配色设置展开阅读预览 |
| 04 | 书架，文件夹有书 |
| 05 | 标注与笔记 |
| 06 | 数据管理与备份入口 |

scheme 的 pre-action 启动 `ios/StoreScreenshots/export.py` 拍摄/导出协作器，post-action 停止它并关闭所选模拟器；构建本身仍全部由 xcodebuild/Nix 管理，没有独立 shell 构建脚本。App 每个场景使用随机 UUID 隔离会话，只在自己的临时目录写原创 TXT，拒绝 iCloud/Downloads 路径。固定系统状态栏为 9:41、满电满格；阅读器中的当前时间保持真实路径。

PNG 自动保存到 `build/Release/<MARKETING_VERSION>-screenshots/<语言>/<设备组>/01.png` 等路径，只覆盖本次指定的场景，其余图片保留。导出原生截图，不缩放、不叠标题；按实际 RGB 像素排除黑图，不把 alpha 算成画面。尺寸或 DeviceHub 展开状态不符时直接失败，日志见 `build/StoreScreenshots/export.log`。失败截图不能当作交付，交付前仍需目视检查正文、构图和全屏状态。若用户强制中断 xcodebuild，先执行 `touch build/StoreScreenshots/stop` 停止导出协作器，再手动关闭本次使用的模拟器，不保留空闲 Booted 设备。

### 当前真机云能力构建

现有开发者团队已支持 iCloud。使用默认云配置和自动签名，不再为当前手机构建覆盖 `MOONREAD_CLOUD_ENABLED=NO` 或清空 entitlements：

```sh
xcodebuild -project ios/Moonread.xcodeproj -scheme Moonread \
  -destination 'generic/platform=iOS' -derivedDataPath build/DeviceDerivedData \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

2026-10-02 已验证描述文件和应用签名包含云容器及推送权限。以下无云签名流程仅适用于没有相应权限的 Personal Team。

需要让本机真机试用包读取用户现有的正式 iCloud 数据时，在 PR CI 通过后使用 Release 配置，复制主 App 的 entitlements 到忽略的 `build/`，仅在该副本加入 `com.apple.developer.icloud-container-environment=Production`，通过现有的主 App 参数 `MOONREAD_ENTITLEMENTS` 指向该副本（绝对路径），扩展沿用自己的权限文件；不修改或提交普通 Debug 的权限配置。覆盖安装前用 `codesign -d --entitlements :-` 检查实际签名的环境确为 Production、容器为 `iCloud.dev.moonread.Moonread`，并确认 `get-task-allow` 与本次使用的开发/分发描述文件一致（本机开发调试签名为 true，分发签名为 false）。自动签名如不允许该组合，停止报告，不改用 Development 云数据。核验后用 `devicectl` 覆盖安装并启动，保留 App 和数据，不卸载；连接、解锁或人工授权由用户处理。试用安装不等于发版或合并。

### Personal Team 本地试用包

默认工程声明 iCloud 能力，Personal Team 无法为其自动签名。本地试用沿用 `MOONREAD_CLOUD_ENABLED=NO`、`CODE_SIGN_ENTITLEMENTS=`、`CODE_SIGNING_ALLOWED=NO` 构建，再使用本机已有有效证书、描述文件及匹配的本地应用权限签名；不修改公共工程的云能力声明。

无签名构建包含 `Moonread.debug.dylib` 和 `__preview.dylib`。必须先签内部动态库，再签应用，最后逐个校验签名和 TeamIdentifier；动态库不套用主应用的 entitlements。只签 `.app` 或只运行 `codesign --verify --deep` 不足以覆盖应用根目录中的这两个库，会出现安装成功但启动时被 dyld 拒绝的情况。签名修复使用覆盖安装，不因签名错误卸载或重置数据库。

当前产物的签名顺序如下；证书、描述文件和应用权限文件均留在本机，不提交。`MOONREAD_SIGNING_IDENTITY` 使用本机有效 Apple Development 证书标识，`MOONREAD_LOCAL_ENTITLEMENTS` 指向与描述文件匹配的本地权限文件；描述文件须先复制到包内 `embedded.mobileprovision`。

```sh
moonread_app=build/DeviceDerivedData/Build/Products/Debug-iphoneos/Moonread.app
for moonread_binary in "$moonread_app"/*.dylib; do
  /usr/bin/codesign --force --sign "$MOONREAD_SIGNING_IDENTITY" --timestamp=none "$moonread_binary" || exit
done
/usr/bin/codesign --force --sign "$MOONREAD_SIGNING_IDENTITY" \
  --entitlements "$MOONREAD_LOCAL_ENTITLEMENTS" --generate-entitlement-der \
  --timestamp=none "$moonread_app"
for moonread_binary in "$moonread_app"/*.dylib "$moonread_app"; do
  /usr/bin/codesign --verify --strict "$moonread_binary" || exit
  /usr/bin/codesign -dvv "$moonread_binary"
done
```

## 命令行检查

在 `nix develop` 中执行。`<SIMULATOR_UUID>` 取自 `/usr/bin/xcrun simctl list devices available`：

```sh
/usr/bin/xcodebuild -project ios/Moonread.xcodeproj -scheme Moonread \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
/usr/bin/xcodebuild -project ios/Moonread.xcodeproj -scheme Moonread \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UUID>' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO test
```

按改动选受影响的核心测试、原生排版回归和必要交互流程；需要时使用 `-only-testing:` 限定测试，不因小修自动重复全部验收。UI 用例各自使用独立测试存储，同一用例重启仍复用该目录，不覆盖正常书库。DEBUG 下同时提供 `--ui-testing` 和有效 UUID `--ui-test-session` 时，新会话重置标准 defaults 的阅读设置及设置分类，从默认滚动模式、20 号字开始；相同 UUID 的重启保留修改以验证持久化，正常启动不重置。

## 试用入口

首次初始化空的内置书架会放入自带原创短篇《月光下的归途》，通过普通书籍行阅读；它可以删除，重启不会补回。首页“＋”里的“添加书架”授权其他目录，“导入小说”复制 TXT 到固定内置书架。仓库只包含这份原创预置内容，不包含用户小说。首页放大镜查所有书架，目录放大镜查所属书架及子目录；搜索在原页面展开。目录“更多 → 显示方式”切换列表／网格，所有目录共用并在重启后保留。

UI 阅读回归使用 `--ui-testing`、独立 session 和 `--ui-test-reader-fixture`，将长篇合成排版文本放到测试目录，再经普通文件行开书；`--ui-test-home` 走真实首次预置流程。测试辅助入口不显示在正式首页。UI 测试默认跳过开场四页引导；专测引导时添加 `--ui-test-introduction`，完成状态按测试 session 隔离。所有 UI 测试启动参数及其处理代码仅在 `#if DEBUG` 中编译（包括测试存储、云能力替代、模型 fixture 和测试辅助值）；Release 不识别这些参数，App 与 Share 的产物审计禁止 `--ui-test` 前缀标记。测试 fixture 截图须使用 Debug，不能靠 Release 启动参数启用。

轻点正文展开工具，在阅读设置切换模式、字号和行距；“目录”中有章节、书签、笔记，搜索独立展开。长按正文可标注或写批注，点已有高亮可编辑。试用重点是连续阅读、定位返回和位置稳定，具体行为见[正文](../reader/reading.md)与[阅读工具](../reader/tools.md)。

参考：[UniFFI Swift 绑定](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html)、[Xcode 集成](https://mozilla.github.io/uniffi-rs/latest/swift/xcode.html)。
