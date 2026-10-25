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

## 本地化

界面支持简体中文 `zh-Hans`、台湾繁体中文 `zh-Hant` 与英文 `en`。`ios/Moonread/Localizable.xcstrings` 的源键保留简体，繁体翻译按 OpenCC `s2twp` 生成并人工校正台湾用语（設定、檔案、資料夾、字型、匯入、複製、回饋）。不要转换源键、格式占位符、协议／模型 ID、用户命名或小说正文；英文数量文案保留单复数。新增文案同步补齐三语，不直接把中文动态 String 当界面值。

可在常规 Xcode 构建中加 `SWIFT_EMIT_LOC_STRINGS=YES`，核对编译器提取的键，尤其插值和自定义视图的标题；测试用的 `full/half/compact` 等诊断值不翻译。显示名与 iCloud 容器名在各语言的 `InfoPlist.strings` 中声明（英文 Moonread、繁体月讀、简体月读），工程地区只保留规范的 `zh-Hans`／`zh-Hant`。`AppStorePrivacyTests` 验证随包资源、格式参数及名称；英文／繁体巡检须区分界面漏翻与保持原样的书籍／连接内容。

## 分支与协作

- `main` 的 App 代码始终对应 App Store 最新发布版本，不承载下一版本 App 的日常开发；正式发布后，在对应提交打版本 tag（如 `v1.1`）。TestFlight 上传不等于 App Store 发布。
- `docs/site/**` 是版本分支规则的例外：隐私政策、支持页等版本所需的网站改动，在提交 App Store 审核前用小 PR 直接合进 `main`，由 Pages 即时部署，不等待 App 版本上线。网站检查通过后再合并；“main 等于线上版本”只约束 App 代码。
- 发布工作流等不含 App 功能代码的发布基础设施可通过小 PR 直接进入 `main`，使默认分支上的手动工作流可用；合入后同步到当前 release 分支。此例外不提前发布下一版 App 代码。
- 每个版本从 `main` 建立 `release/x.y`，在该分支开发。功能、修复与文档使用独立开发分支，PR 以当前 `release/x.y` 为目标，通过检查后 **squash** 合并。
- App Store 发布后，`release/x.y` 通过 PR 以普通 **merge commit** 合回 `main`，保留版本开发历史；发布回合使用普通 merge，不 squash 发布分支；下述已上线 hotfix 回合也使用普通 merge。
- 线上问题从 `main` 建立 `hotfix/x.y.z`，在该分支修复、打包并提审；App Store 上线后才通过 PR 以普通 merge 回 `main` 并打补丁 tag（如 `v1.1.1`），随后把 `main` 合进当前 `release/x.y`。补丁审核及等待上线期间不提前合回 main，确保 main 的 App 代码始终对应线上版本。
- PR 合入 `release/x.y` 或 `hotfix` 分支时，GitHub 不会根据 `Closes` 自动关闭 issue。合并后需手动关闭对应 issue，评论注明合入的分支与提交，并把看板状态改为「完成」。
- `main` 与 `release/**` 必须经过 PR、`Linux checks` 和 `iOS unit tests`，解决所有讨论，禁止强推和删除；维护者决定何时合并，不由工具自动合并。

发版清单（分支）：

- 新开 `release/x.y` 后第一件事：把所有 target 的 `MARKETING_VERSION` 改为 `x.y`，构建号 `CURRENT_PROJECT_VERSION` 递增到大于 ASC 已有最大号；Debug/Release 保持一致。

- 新开 `release/x.y` 时，同步修改 [Dependabot](../../../.github/dependabot.yml) 两个更新项的 `target-branch`，让常规依赖版本更新 PR 指向当前版本分支。
- Dependabot 安全更新 PR 总是开到默认分支 `main`，不受 `target-branch` 控制；收到后先把 PR 的 base 改成当前 `release/x.y`，按版本分支流程修复、验证和发布，不提前把 App 修复合入 main。紧急漏洞走上述 `hotfix/x.y.z` 流程，在补丁上线后再普通 merge 回 main 并同步当前 release。
- 当前目标配置为 `release/1.2`，该分支在本流程 PR 合并后才创建；新目标分支的 CI 触发与 Dependabot 实际校验以合并并创建分支后为准，不能以本 PR 的 CI 通过代替。

签名配置、小说原件、构建产物与凭据不随代码推送。CI、仓库保护、模板及依赖更新见[仓库与持续集成](repository.md)，测试范围与推送前要求见[测试原则](verification.md#测试原则)。

## Xcode 与 Rust 集成

应用 Swift 源码的真实目录与显式 Xcode groups 对应，见[源码目录职责](architecture.md#swift-源码目录)。移动现有文件保留 file reference、Sources UUID 与 target membership；拆分文件单独加入应用 target，资源及签名配置继续使用原路径。

工程使用 Swift 6 及完整并发检查。在 Xcode 选择 `Moonread` scheme；从 Finder 打开工程也会通过 `nix develop --no-update-lock-file` 使用锁定 Cargo。

- 构建阶段执行编译与生成绑定两条工具调用。target、Debug/Release、链接路径声明在 [Rust.xcconfig](../../../ios/Rust.xcconfig)。
- UniFFI 从 [uniffi.toml](../../../crates/moonread-core/uniffi.toml) 读取输出名称；使用 `--no-format` 生成，避免每次构建格式化自动生成代码。
- 链接明确指定 `libmoonread_core.a`，避免同目录动态库被优先选中或把 Mac 路径带进 iPhone。
- Rust 输出位于 `build/cargo/`，绑定位于 `build/ios/Generated/<Configuration>/`，均不提交。模拟器构建生成 arm64 / x86_64 两个 slice。
- Xcode 构建缓存只用两份：模拟器构建和测试统一 `-derivedDataPath build/DerivedData`，真机构建统一 `build/DeviceDerivedData`。不按任务另建缓存目录；任务的日志、截图等验证记录可以放在 `build/<任务名>/`，任务合并后删除。
- Nix 默认路径为 `/nix/var/nix/profiles/default/bin/nix`；非标准安装可在本地 `LocalSigning.xcconfig` 覆盖 `MOONREAD_NIX`。

首次运行需要下载工具链和 Cargo 依赖，之后复用缓存。

## 签名与安装

在 Xcode 登录 Apple 账户，在设备开启开发者模式。将 [LocalSigning.example.xcconfig](../../../ios/LocalSigning.example.xcconfig) 复制为 `ios/LocalSigning.xcconfig` 并填写自己的团队 ID；公共配置通过可选 include 读取它，本地文件已被 Git 忽略。项目不写入个人团队，证书和描述文件由 Xcode 管理。首次安装若要求信任个人开发者，在设备上完成确认。

安装、自动启动、真机交互或性能采集以当轮任务授权为准；安装成功不等于已启动、已运行测试或真机体验已验收。

发布后数据演进须保留旧数据并执行版本迁移，规则见[持久化演进](architecture.md#持久化演进与发布兼容)，不能通过要求用户删除重装解决格式升级。开发重置仅按当轮授权执行，不影响外部及 iCloud 小说原件；普通更新覆盖安装。

### 发布版本与构建号

App 的营销版本（`MARKETING_VERSION`，用户可见）和构建号（`CURRENT_PROJECT_VERSION`）以 `ios/Moonread.xcodeproj` 的工程设置为准，文档不记录具体数值。构建号使用单调递增的正整数，每次对外上传新构建时增加，不能因营销版本变化而回退或复用；Debug/Release 保持一致。Cargo crate 版本独立，不作为 App Store 版本。提交前核对两种配置、已上传构建号与持久化兼容/迁移回归。

### TestFlight 打包与上传

使用干净提交和本机 `LocalSigning.xcconfig`，在 Nix 环境执行 Release archive，真机缓存统一为 `build/DeviceDerivedData`。自动签名的原始归档通常使用开发签名，导出时由 Xcode 重签为 App Store Connect 分发包，这是正常流程；不要给自动开发签名的归档强行指定 Apple Distribution 身份。

```sh
nix develop --no-update-lock-file -c xcodebuild \
  -project ios/Moonread.xcodeproj -scheme Moonread -configuration Release \
  -xcconfig ios/LocalSigning.xcconfig -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData \
  -archivePath build/TestFlight/Moonread.xcarchive -allowProvisioningUpdates archive
```

先用 `xcodebuild -exportArchive` 本地导出并核对分发包。ExportOptions 使用 `method=app-store-connect`、`signingStyle=automatic`、`iCloudContainerEnvironment=Production`、`manageAppVersionAndBuildNumber=false`；预检用 `destination=export`，上传时改为 `destination=upload`，两次均允许自动签名更新，并使用同一归档。每次新上传先按上一节递增构建号；遇账号登录或钥匙串授权，由用户本人处理。

上传前检查 Bundle ID、版本/构建号、`ITSAppUsesNonExemptEncryption=NO`、隐私清单、无 DEBUG/诊断入口、无 `.storekit` 文件，以及签名完整性。生产权限应在**导出分发包**核对：`aps-environment=production`、CloudKit 环境 Production、`get-task-allow=false`，容器为 `iCloud.dev.moonread.Moonread`，服务同时包含 CloudKit 与 CloudDocuments。不要拿原始开发签名归档的权限代替分发包结论。

`TipJar.storekit` 仅保留 Debug scheme 的 StoreKit Configuration 引用，不属于任何 target 的 Copy Bundle Resources；普通 Release 归档不需要资源排除参数。本地 StoreKitTest 自动化在模拟器通过源文件 URL 读取同一配置，不依赖 App 或测试 bundle 内的副本。上传成功与 ASC 处理完成／可测试分别记录；上传不等于提交审核或正式发布。归档、分发包核验和上传日志保存在 `build/TestFlight/`。

### TestFlight 手动 CI

[`TestFlight`](../../../.github/workflows/testflight.yml) 只接受在默认分支 `main` 上的 `workflow_dispatch`，不由 tag、PR 或 push 上传。工作流本身须先通过 PR 合入 main；维护者再同步到当前 release 分支。Actions 中选择 `main`，填写 `source_branch`（仅 `release/x.y` 或 `hotfix/x.y.z`）、`expected_sha`（完整 40 位、等于该分支 HEAD）、`mode`（默认 `verify`）。`upload` 必须另获用户明确授权后才选择；verify 从不上传。

无凭据的 prepare job 检查同一个可信 `ci.yml` 的该 SHA 最新 push run：`Secret scan`、`Workflow syntax`、`Linux checks`、`iOS unit tests` 全部成功，skipped/pending 不放行。签名 job 进入 `testflight` Environment 后再次检查分支 HEAD，检出固定 SHA；上传前再检查一次。所有版本共用 `moonread-testflight` 串行组，不取消正在运行的任务；不要连续排多个发版请求。

用户在 GitHub **Environment `testflight`** 中自行配置三项 Secrets：`ASC_API_KEY_BASE64`（ASC Team API Key 的 p8 原字节 Base64）、`ASC_KEY_ID`、`ASC_ISSUER_ID`；配置非敏感 Variable `APPLE_TEAM_ID`。API Key 按已确认自动签名方案使用 Admin 角色。Environment 限制只允许 main 部署，并由用户设置可用的审批保护；不要把签名 Secrets 配到 PR 可访问的仓库环境。代理不读取或代填密钥，也不索要 p12/profile。未配置或自动签名权限、协议、证书额度不足时停止报告，不自动改走手动签名、不撤销证书或循环申请。GitHub-hosted `xcode-27` 必须提供 Xcode 27.1 / iPhoneOS SDK，否则停止，不自行换工具链。

先在工程 PR 中分配全局递增构建号，App/Share、Debug/Release 一致，营销版本与源分支版本一致。CI 只读取，绝不修改版本号。ASC 对 App `6823849812` 的所有营销版本分页取数字最大构建号；upload 的候选号必须更大，verify 可以核验已用号但不消耗新号。上传命令非零退出时立即保存网络、权限、协议、签名或导出失败的脱敏类别并停止，不空等处理结果或自动重传；上传是否发生可能不明，列表也可能延迟，需用户先核对 ASC 后决定重试或新号。

archive、本地 export、upload export 都使用 `-allowProvisioningUpdates` 和三个 `-authenticationKey*` 参数、`CODE_SIGN_STYLE=Automatic`，不指定 Distribution 身份或 profile 映射。两份 ExportOptions 除 destination 外一致：automatic、Production、`manageAppVersionAndBuildNumber=false`。工作流不读取本机 `LocalSigning.xcconfig`，p8 只存在 runner 临时文件中，隔离钥匙串在 finally 步骤恢复并删除；只运行在一次性 GitHub-hosted runner。Nix 使用锁定工具链；SPM 必须使用已提交的 Package.resolved；不复用 PR 的构建/签名产物。

归档完成后本地导出，解压 **IPA** 审计：App/Share Bundle ID 与版本/构建、逐个代码签名与 arm64、有效 App Store profile 与团队/签名证书、生产推送与 CloudKit/CloudDocuments/固定容器、App Group、`get-task-allow=false`、加密声明、四处已知隐私清单，以及无 DEBUG/诊断入口、`.storekit`、测试包；App 与 Share 二进制均禁止 `--ui-test` 前缀的所有测试启动参数（包括 `--ui-testing`、`--ui-test-session`、`--ui-test-tips`、`--ui-test-introduction`），同时检查其他既有诊断标记。原始 archive 的开发签名不能代替此结论。上传使用同一份已审计且未改动的 archive 再导出，不宣称两次重签的 IPA 字节完全相同。

公开仓库 artifact **仅**保存白名单脱敏 JSON（来源 SHA、版本/构建、锁文件与 IPA 哈希、审计结果、失败类别/ASC 状态），保留 7 天；不上传 IPA、archive、dSYM、完整签名日志、profile、entitlements 或密钥。原始资料只在临时 runner，结束时删除；需要私有 dSYM 留存时另行授权配置。失败按网络、权限/签名、协议和构建/导出区分；日志不输出凭据。只有上传命令成功才只读查询准确版本/构建，最多 20 分钟；分别记录 Xcode 接受上传、ASC VALID/PROCESSING/FAILED/INVALID/结果待确认。目标 Moonread Auto 组由维护者在 ASC 配置/核对，工作流不改分组、外部测试、审核或发布状态。

首次验收为：用户合并工作流并配置 Environment 后，手动执行一次 `verify`，审计通过再单独授权 upload。PR CI 或 actionlint 通过只证明对应检查，不证明自动签名或上传已成功。

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
