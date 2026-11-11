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
| iPhone 真机 | `aarch64-apple-ios` |

Nix 管理开发依赖；本机 Xcode 提供 Apple SDK、Clang、链接器、资源编译、签名及设备运行。macOS 使用 `mkShellNoCC`，移除 Rust overlay 隐式传播的 Nix 编译器和目标库，避免与 Xcode SDK 混用。iOS App 不宣称是完全可复现的 `nix build` 产物；Linux 环境仅供 Rust 核心开发。个人签名配置与小说不进入 Nix store。

更新依赖显式执行 `nix flake update` 并检查锁文件变化；构建不会自行更新锁文件。新增 Nix 文件须加入 Git 跟踪后供本地 flake 使用，不能用 `path:.` 把含本地凭据的整个工作目录作为输入。

项目级 [SwiftUI Expert skill](../../../.agents/skills/swiftui-expert-skill/SKILL.md) 用于 SwiftUI 开发与审阅。来源为 [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill)，固定 `4.2.0` / `9692ec5c3e78a0acc7757de2dbe8e64e519a72fb`，保留上游 [MIT 许可](../../../.agents/skills/swiftui-expert-skill/LICENSE)；更新时显式选择版本。

## 本地化

界面支持简体中文 `zh-Hans`、台湾繁体中文 `zh-Hant` 与英文 `en`。`ios/Moonread/Localizable.xcstrings` 的源键保留简体，繁体翻译按 OpenCC `s2twp` 生成并人工校正台湾用语（設定、檔案、資料夾、字型、匯入、複製、回饋）。不要转换源键、格式占位符、协议／模型 ID、用户命名或小说正文；英文数量文案保留单复数。新增文案同步补齐三语，不直接把中文动态 String 当界面值。

可在常规 Xcode 构建中加 `SWIFT_EMIT_LOC_STRINGS=YES`，核对编译器提取的键，尤其插值和自定义视图的标题；测试用的 `full/half/compact` 等诊断值不翻译。显示名与 iCloud 容器名在各语言的 `InfoPlist.strings` 中声明（英文 Moonread、繁体月讀、简体月读），工程地区只保留规范的 `zh-Hans`／`zh-Hant`。`AppStorePrivacyTests` 验证随包资源、格式参数及名称；英文／繁体巡检须区分界面漏翻与保持原样的书籍／连接内容。

## 分支与协作

- `main` 的 App 代码始终对应 App Store 最新发布版本，不承载下一版本 App 的日常开发；正式发布后，在对应提交打版本 tag（如 `v1.1`）。TestFlight 上传不等于 App Store 发布。
- 所有改动（含官网、文档和发布基础设施）都进入当前 `release/x.y`；不直接向 `main` 提交开发 PR，`main` 只接收发布后的版本分支合并。审核前确需提前上线的隐私政策、支持页等网站页面，须先向用户申请，不自动视为例外。
- 通常从 `main` 建立 `release/x.y`。上一版已提审但未上线时，可从其固定提审提交建立下一版分支并行开发；上一版上线或追加修复后，再把发布结果同步到下一版，不能提前把未上线 App 代码合入 `main`。功能、修复、官网与文档使用独立开发分支，PR 以当前 `release/x.y` 为目标，通过检查后 **squash** 合并。
- App Store 发布后，`release/x.y` 通过 PR 以普通 **merge commit** 合回 `main`，保留版本开发历史；发布回合使用普通 merge，不 squash 发布分支；下述已上线 hotfix 回合也使用普通 merge。
- 线上问题从 `main` 建立 `hotfix/x.y.z`，在该分支修复、打包并提审；App Store 上线后才通过 PR 以普通 merge 回 `main` 并打补丁 tag（如 `v1.1.1`），随后把 `main` 合进当前 `release/x.y`。补丁审核及等待上线期间不提前合回 main，确保 main 的 App 代码始终对应线上版本。
- PR 合入 `release/x.y` 或 `hotfix` 分支时，GitHub 不会根据 `Closes` 自动关闭 issue。合并后需手动关闭对应 issue，评论注明合入的分支与提交，并把看板状态改为「完成」。
- `main` 与 `release/**` 必须经过 PR 并满足目标分支的[必需检查](repository.md#仓库设置)，解决所有讨论，禁止强推和删除；维护者决定何时合并，不由工具自动合并。

发版清单（分支）：

- 每个版本建立或复用文档整理与代码清理 issue（1.4 为 #173）；发布前核对文档现状、遗留项与验证边界，不为清理而强拆所有长文件。
- 新开 `release/x.y` 后第一件事：把所有 target 的 `MARKETING_VERSION` 改为 `x.y`，构建号 `CURRENT_PROJECT_VERSION` 递增到大于 ASC 已有最大号；Debug/Release 保持一致。

- 新开 `release/x.y` 时，同步修改 [Dependabot](../../../.github/dependabot.yml) 两个更新项的 `target-branch`，让常规依赖版本更新 PR 指向当前版本分支。
- Dependabot 安全更新 PR 总是开到默认分支 `main`，不受 `target-branch` 控制；收到后先把 PR 的 base 改成当前 `release/x.y`，按版本分支流程修复、验证和发布，不提前把 App 修复合入 main。紧急漏洞走上述 `hotfix/x.y.z` 流程，在补丁上线后再普通 merge 回 main 并同步当前 release。
- 当前常规依赖更新目标为 `release/1.6`，以 `.github/dependabot.yml` 为准；新版本分支切换后需核对实际配置。

签名配置、小说原件、构建产物与凭据不随代码推送。CI、仓库保护、模板及依赖更新见[仓库与持续集成](repository.md)，测试范围与推送前要求见[测试原则](verification.md#测试原则)。

## Xcode 与 Rust 集成

应用 Swift 源码的真实目录与显式 Xcode groups 对应，见[源码目录职责](architecture.md#swift-源码目录)。移动现有文件保留 file reference、Sources UUID 与 target membership；拆分文件单独加入应用 target，资源及签名配置继续使用原路径。

工程使用 Swift 6 及完整并发检查。在 Xcode 选择 `Moonread` scheme；从 Finder 打开工程也会通过 `nix develop --no-update-lock-file` 使用锁定 Cargo。

- 构建阶段先进入 Nix devShell，再在本机按 PATH、`$HOME/.cargo/bin/mbx` 的顺序寻找 mbx；找到时用 `mbx build`，否则用 `cargo build`。CI 始终直接用 Cargo。mbx 使用 devShell 中锁定的 Cargo/Rust（含 iOS targets），不选系统 rustup 工具链；UniFFI 绑定生成仍用 Cargo。
- 构建阶段每次编译当前 Rust 库与 host bindgen 工具，再运行生成器；三段分别输出耗时。target、Debug/Release、链接路径声明在 [Rust.xcconfig](../../../ios/Rust.xcconfig)。
- 主 App 的 `Prune unused math fonts` 阶段依赖 SwiftPM 已复制的资源 bundle，在 Release 签名前只保留 Latin Modern Math 的 OTF、metrics plist 与三份许可证；上游依赖不变。该阶段每次构建执行，防止增量复制恢复未用字体，缺少必需资源时构建失败。Debug 的 SwiftPM 资源 bundle 有独立临时签名，不做裁剪。
- UniFFI 从 [uniffi.toml](../../../crates/moonread-core/uniffi.toml) 读取输出名称；使用 `--no-format` 写入临时目录；三个预期输出全部成功生成后逐文件 `cmp`，缺失或内容变化才替换正式文件，内容相同保留原 mtime。失败不能回退旧绑定，生成目录与 CI DerivedData 成套缓存；不跳过当前 Rust 构建。
- 链接明确指定 `libmoonread_core.a`，避免同目录动态库被优先选中或把 Mac 路径带进 iPhone。
- Rust 输出位于仓库默认的 `target/`，绑定位于 `build/ios/Generated/<Configuration>/`，均不提交。模拟器只编译 `aarch64-apple-ios-sim`（arm64）。
- Xcode 构建缓存只用两份：模拟器构建和测试统一 `-derivedDataPath build/DerivedData`，真机构建统一 `build/DeviceDerivedData`。不按任务另建缓存目录；任务的日志、截图等验证记录可以放在 `build/<任务名>/`，任务合并后删除。
- 不使用 git worktree；在主目录切分支，共用 `target`、`build/DerivedData` 和 `build/DeviceDerivedData`。
- Nix 默认路径为 `/nix/var/nix/profiles/default/bin/nix`；非标准安装可在本地 `LocalSigning.xcconfig` 覆盖 `MOONREAD_NIX`。
- 开发环境以 `build/nix-dev-profile` 作为 GC root。运行 `nix gc` / `nix-collect-garbage` 前确认该 root 存在，否则开发环境会被回收，需要重新下载工具链。

首次运行需要下载工具链和 Cargo 依赖，之后复用缓存。

### 本机模拟器约定

本机主模拟器仍使用 iOS 27.0 的 iPhone 18 Pro（`FFA6F448-E09C-4885-B59C-53C5E07185F5`）；当前 iOS 27.1 运行时仅支持 Duo，Duo 检查使用独立的 iPhone Duo（`6E42EBA5-DA26-4E2C-BF50-0CA9DC193893`），两个运行时均保留，CI 不变。iPad 检查使用 iPad Pro 13 英寸（`0F4A5FC1-EA80-4A88-81C2-D1650CFCA791`）。只复用这三台，不按任务新建；需要干净状态时重装 App。同一时间只开一台，用完关机；模拟器是测试和截图机，不清理桌面小组件、系统语言或外观。

## 签名与安装

在 Xcode 登录 Apple 账户，在设备开启开发者模式。将 [LocalSigning.example.xcconfig](../../../ios/LocalSigning.example.xcconfig) 复制为 `ios/LocalSigning.xcconfig` 并填写自己的团队 ID；公共配置通过可选 include 读取它，本地文件已被 Git 忽略。项目不写入个人团队，证书和描述文件由 Xcode 管理。首次安装若要求信任个人开发者，在设备上完成确认。

安装、自动启动、真机交互或性能采集以当轮任务授权为准；安装成功不等于已启动、已运行测试或真机体验已验收。

发布后数据演进须保留旧数据并执行版本迁移，规则见[持久化演进](architecture.md#持久化演进与发布兼容)，不能通过要求用户删除重装解决格式升级。开发重置仅按当轮授权执行，不影响外部及 iCloud 小说原件；普通更新覆盖安装。

### 发布版本与构建号

App 的营销版本（`MARKETING_VERSION`，用户可见）和构建号（`CURRENT_PROJECT_VERSION`）以 `ios/Moonread.xcodeproj` 的工程设置为准，文档不记录具体数值。构建号使用单调递增的正整数，每次对外上传新构建时增加，不能因营销版本变化而回退或复用；Debug/Release 保持一致。Cargo crate 版本独立，不作为 App Store 版本。提交前核对两种配置、已上传构建号与持久化兼容/迁移回归。

### TestFlight 打包与上传

统一见[发布手册](release.md)：main 手动触发、branch+SHA、verify 后授权 upload，或本机同归档导出核验。

### 官网与商店原图（独立 DEBUG 测试）

使用独立的 `StoreScreenshots` scheme，不进入日常关键 UI 测试。拍摄参数、原创样书与处理入口都只存在于 DEBUG（#83）；每次启动使用随机 UUID 的临时书库，拒绝用户 iCloud / Downloads 路径。不能用用户小说或真实 AI 网络请求作夹具。

先对比上一版原图，只拍有变化或旧图里没有的页面。官网和商店共用一份原图，不能按用途重复拍。源码或构建参数变化后先重新编译；同一源码、SDK 和架构下，后续批次复用同一份测试产物。进入一次 Nix shell，在仓库根目录运行：

```sh
nix develop --no-update-lock-file
common=(
  -project ios/Moonread.xcodeproj -scheme StoreScreenshots -configuration Debug
  -destination 'platform=iOS Simulator,id=FFA6F448-E09C-4885-B59C-53C5E07185F5'
  -derivedDataPath build/DerivedData -parallel-testing-enabled NO
  -onlyUsePackageVersionsFromResolvedFile -collect-test-diagnostics never
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES
)
xcodebuild "${common[@]}" build-for-testing
xcodebuild "${common[@]}" STORE_SCREENSHOT_DEVICE=iphone-medium \
  STORE_SCREENSHOT_LANGUAGES=zh-Hans STORE_SCREENSHOT_SCENES=R15 \
  STORE_SCREENSHOT_APPEARANCES=light test-without-building
```

同一个模拟器姿态、系统语言下的多张图放在同一轮 `test-without-building`，用逗号同时传入场景与明暗，例如 `STORE_SCREENSHOT_SCENES=R01,R12,R15` 和 `STORE_SCREENSHOT_APPEARANCES=light,dark`。只启动一次 runner；每张图仍用隔离的 App 会话准备对应数据。App 内页面可在同一轮用 `STORE_SCREENSHOT_LANGUAGES=zh-Hans,zh-Hant,en` 按语言分组；R04 必须按 SpringBoard 系统语言单独分批。iPad 横竖屏、Duo 内外屏按实际姿态分批，使用已有模拟器，一次只开一台。需要矩阵时由当轮已审定清单提供，可用 `STORE_SCREENSHOT_IDS=<完整ID,...>` 筛选；未限定时会处理所选设备组和语言的全部场景，执行前先核对范围。矩阵中的语言、配色、纹理、明暗、方向、店面与输出路径通过同一 `StoreShotCapture` 提交，导出前核对 App 实际应用的 receipt。

不传矩阵时，可用同名 `STORE_SCREENSHOT_SCENES=R01`、`STORE_SCREENSHOT_LANGUAGES=zh-Hans`、`STORE_SCREENSHOT_APPEARANCES=light,dark`、`STORE_SCREENSHOT_ORIENTATION=portrait` 单独拍；可显式指定 `STORE_SCREENSHOT_APP_PALETTE` / `STORE_SCREENSHOT_READER_PALETTE`。店面由 `STORE_SCREENSHOT_STOREFRONT` 独立指定，默认 USA，与语言无关。单页 `PAGE_SHOT_SCENE/APPEARANCE/ORIENTATION` 保留，也走同一配置入口，输出仍在 `build/PageShots/`。旧 kraft/linen 与 01–08 别名不再使用。

| 设备组 | 已有模拟器 | 原生 PNG 尺寸与准备 |
| --- | --- | --- |
| `iphone-medium` | iPhone 18 Pro，`FFA6F448-E09C-4885-B59C-53C5E07185F5` | 1206×2622，20 pt |
| `ipad-portrait` / `ipad-landscape` | iPad Pro 13-inch (M5)，`0F4A5FC1-EA80-4A88-81C2-D1650CFCA791` | 2064×2752 / 2752×2064，24 pt；系统设为全屏 App。`ipad-13` 可一次选中矩阵 P/L 两种方向 |
| `duo-outer` | iPhone Duo，`6E42EBA5-DA26-4E2C-BF50-0CA9DC193893` | 1398×2034，20 pt；DeviceHub Closed |
| `duo-inner` | 同一台 Duo | 2853×2007，20 pt；先在 DeviceHub Open。方向参数不能代替真实展开，不自动折叠 |

| 场景 | 实际内容 |
| --- | --- |
| R01 / R12 / R13 | 同书同锚点与排版，分别为纸色 / 薄荷 / 竹绿及各自正式图案；竹绿只有浅色生产预设，不发明深色 ID |
| R02 | 阅读设置的排版控件与真实阅读预览 |
| R03 | 隔离本机基线与较后候选触发的生产续读提示，未接受 |
| R04 | 真实 SpringBoard 中号继续阅读组件；百分比与章节通过 Rust 目录查询取得 |
| R05 | 六本原创书、两个非空文件夹的实际书架 |
| R06 | 真实笔记列表；保留小说选项入口按钮可见，不展开导出菜单 |
| R07 | 固定 2026-10-25 的七天统计，使用生产时钟写入与查询 |
| R08 / R09 | 正文高亮 / 原创人物名实际书内搜索，键盘收起 |
| R10 / R11 | 六本有效记录的数据管理总览 / 已审合成 AI 回顾（不发网络请求） |
| R15 | 听书播放条与固定句子高亮（无实际播放） |

R04 的桌面只需准备一次：倒数第二页是拍摄页，只放月读中号「继续阅读」小组件，退出编辑状态；最后一页保留已安装的开发 App 和 XCTest runner。首次安装后如图标落在拍摄页，把它们移到最后一页，后续不卸载或清理。运行前停在拍摄页或最后一页，测试从 App 回桌面后会检查当前页；找不到组件时向右翻一页，再等待可见组件显示本批书名、章节和进度。若失败，检查桌面分工、组件尺寸和系统语言，从拍摄页重跑。App 的语言参数不改变 SpringBoard；必须在模拟器设置切到本批系统语言。独立的 `StoreScreenshots/catalog.json` 不改正常 `SystemReading/v1`。

pre-action 调用 `ios/StoreScreenshots/export.py` 展开所选批次并启动导出协作器；post-action 只停止协作器，保留 runner、桌面和组件配置。不要求拍完恢复系统语言或明暗。固定系统状态栏 9:41、满电满格，阅读器当前时间仍走真实路径。

R15 使用隔离合成书库，在正文就绪后以生产播放条和高亮显示固定的朗读句，不创建语音合成任务。三种语言、五个设备组、两种明暗共 30 个组合；按上面的流程每个设备姿态选 `R15` 和两个明暗，供官网与商店第 2 张共用。一次性同步 1.6 用途索引：

```sh
/usr/bin/python3 ios/StoreScreenshots/export.py sync-sources --root "$PWD"
```

R15 原图写到 `build/Release/1.4-screenshots/raw/1.6/<语言>/<设备组>/<light|dark>/R15.png`，按 `R15-<F|P|L|O|I>-<语言>-<明暗>` 更新同集 `raw/manifest.json`；`sources.json` 可列待拍项，文件和 manifest 才证明已经拍摄。其他场景仍写 `build/Release/<工程MARKETING_VERSION>-screenshots/raw/<语言>/<设备组>/<light|dark>/<场景>.png`。Manifest 记录来源提交与 dirty 摘要、设备/运行时、像素、方向、请求配置、App 实际 receipt 和 PNG SHA。旧图保留原来源与哈希，不随索引改写；同一张原图重拍后再重新派生各用途。

只导出原生 PNG，不缩放、不叠标题；按 RGB 排除黑图，去掉误导方向的 EXIF，核对尺寸/姿态。manifest 的像素检查不代替人工审图，默认 `review=pending-visual-review`。错误写入 `build/StoreScreenshots/export.log` 并使当前用例失败。中断后保留已有原图与证据，继续时只补缺项，不要求清理模拟器或重拍已完成且画面未变的页面。

### TestFlight 手动 CI

[`TestFlight`](../../../.github/workflows/testflight.yml) 只接受在默认分支 `main` 上的 `workflow_dispatch`，不由 tag、PR 或 push 上传。工作流本身须先通过 PR 合入 main；维护者再同步到当前 release 分支。Actions 中选择 `main`，填写 `source_branch`（仅 `release/x.y` 或 `hotfix/x.y.z`）、`expected_sha`（完整 40 位、等于该分支 HEAD）、`mode`（默认 `verify`）。`upload` 必须另获用户明确授权后才选择；verify 从不上传。

不接触签名凭据的 prepare job 检查同一个可信 `ci.yml` 中该来源分支与 SHA 的最新 push run。该运行必须成功，且 `Secret scan` 和 `Workflow syntax` 必须成功；如果该运行包含 `Rust and iOS tests`，也必须要求它成功；只有不存在该作业时才要求旧版的 `Linux checks` 和 `iOS unit tests` 都成功。每项必需作业必须恰好出现一次，且结果为 `success`；skipped、pending 等状态均不放行。签名 job 进入 `testflight` Environment 后再次检查分支 HEAD，检出固定 SHA；上传前再检查一次。所有版本共用 `moonread-testflight` 串行组，不取消正在运行的任务；不要连续排多个发版请求。

用户在 GitHub **Environment `testflight`** 中自行配置 Secrets：`ASC_API_KEY_BASE64`（ASC Team API Key 的 p8 原字节 Base64）、`ASC_KEY_ID`、`ASC_ISSUER_ID`，以及固定 Apple Development 证书 `IOS_DEVELOPMENT_CERTIFICATE_P12_BASE64` / `IOS_DEVELOPMENT_CERTIFICATE_PASSWORD`（导入临时钥匙串，供自动签名复用，避免每次运行新建开发证书占满额度）；配置非敏感 Variable `APPLE_TEAM_ID`。导入后仅接受临时钥匙串中通过 codesigning 有效性检查、含匹配私钥且 Subject `OU` 等于配置团队的唯一 Apple Development 身份；证书名称括号内是成员标识，不能拿来匹配 Team ID。证书类型、团队或信任链不满足时停止，不自动新建证书，也不修改信任设置。API Key 按已确认自动签名方案使用 Admin 角色。Environment 限制只允许 main 部署，不设审批；不要把签名 Secrets 配到 PR 可访问的仓库环境。代理不在仓库、日志或报告中保存密钥与 p12。未配置或自动签名权限、协议、证书额度不足时停止报告，不自动改走手动签名、不撤销证书或循环申请。GitHub-hosted `xcode-27` 必须提供 Xcode 27.1 / iPhoneOS SDK，否则停止，不自行换工具链。

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

1.3 按可独立试用的功能批次组织 PR；重大功能或 UI 先完成本地相关测试和真机试用，由用户确认后一次推送开 PR，CI 运行全量测试，合并仍由用户安排。

需要让本机真机试用包读取用户现有的正式 iCloud 数据时，按当轮已确认的验收顺序使用 Release 配置，复制主 App 的 entitlements 到忽略的 `build/`，仅在该副本加入 `com.apple.developer.icloud-container-environment=Production`，通过现有的主 App 参数 `MOONREAD_ENTITLEMENTS` 指向该副本（绝对路径），扩展沿用自己的权限文件；不修改或提交普通 Debug 的权限配置。覆盖安装前用 `codesign -d --entitlements :-` 检查实际签名的环境确为 Production、容器为 `iCloud.dev.moonread.Moonread`，并确认 `get-task-allow` 与本次使用的开发/分发描述文件一致（本机开发调试签名为 true，分发签名为 false）。自动签名如不允许该组合，停止报告，不改用 Development 云数据。核验后用 `devicectl` 覆盖安装并启动，保留 App 和数据，不卸载；连接、解锁或人工授权由用户处理。试用安装不等于发版或合并。

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

### 按页面截图对照效果图

沿用独立的 `StoreScreenshots` scheme，通过 DEBUG 夹具直接打开指定页面。先对比已有页面图，只补需核对的页面，不增加日常 UI 用例。拍 iPad 浅色横屏详情时，在上文同一个 Nix shell 中把 `common` 的 destination 改为 `platform=iOS Simulator,id=0F4A5FC1-EA80-4A88-81C2-D1650CFCA791`。当前源码还没有测试产物时先执行一次 `xcodebuild "${common[@]}" build-for-testing`，然后：

```sh
xcodebuild "${common[@]}" STORE_SCREENSHOT_DEVICE=ipad-13 \
  STORE_SCREENSHOT_LANGUAGES=zh-Hans PAGE_SHOT_SCENE=book-details \
  PAGE_SHOT_APPEARANCE=light PAGE_SHOT_ORIENTATION=landscape test-without-building
```

`PAGE_SHOT_SCENE` 可选 `book-details`（小说详情）、`reader-settings`（阅读设置）、`settings`（设置，regular 宽度自动两栏）、`library-home`（书架首页）、`reader`（单页阅读器）。每次只运行指定页面；`PAGE_SHOT_APPEARANCE=light|dark` 选择杏桃浅／深，页面模式默认只用简中，也可通过 `STORE_SCREENSHOT_LANGUAGES` 指定一个语言。`PAGE_SHOT_ORIENTATION=portrait|landscape|current` 控制方向，默认 iPad 横屏、iPhone 竖屏、Duo 保持当前姿态。沿用现有四个设备组与 UUID destination；Duo 内屏须先手动在 DeviceHub 展开，再用 `duo-inner`，不自动折叠或创建模拟器。

PNG 保存到 `build/PageShots/<设备组>/<场景>-浅.png` 或 `-深.png`；simctl 按实际 display 导出横屏像素，去掉会让查看器再次旋转的方向元数据，不缩放，不从 XCTest attachment 转图。模拟器按专用测试/截图机保留，不要求结束后关闭或恢复设置。未设置 `PAGE_SHOT_SCENE` 时，使用上文 R01–R13、R15 场景及统一 raw 输出目录。

按改动选受影响的核心测试、原生排版回归和必要交互流程；需要时使用 `-only-testing:` 限定测试，不因小修自动重复全部验收。UI 用例各自使用独立测试存储，同一用例重启仍复用该目录，不覆盖正常书库。DEBUG 下同时提供 `--ui-testing` 和有效 UUID `--ui-test-session` 时，新会话重置标准 defaults 的阅读设置及设置分类，从默认滚动模式、20 号字开始；相同 UUID 的重启保留修改以验证持久化，正常启动不重置。

## 试用入口

首次初始化空的内置书架会放入自带原创短篇《月光下的归途》，通过普通书籍行阅读；它可以删除，重启不会补回。首页“＋”里的“添加书架”授权其他目录，“导入小说”复制 TXT 到固定内置书架。仓库只包含这份原创预置内容，不包含用户小说。首页放大镜查所有书架，目录放大镜查所属书架及子目录；搜索在原页面展开。目录“更多 → 显示方式”切换列表／网格，所有目录共用并在重启后保留。

UI 阅读回归使用 `--ui-testing`、独立 session 和 `--ui-test-reader-fixture`，将长篇合成排版文本放到测试目录，再经普通文件行开书；`--ui-test-home` 走真实首次预置流程。测试辅助入口不显示在正式首页。UI 测试默认跳过开场四页引导；专测引导时添加 `--ui-test-introduction`，完成状态按测试 session 隔离。所有 UI 测试启动参数及其处理代码仅在 `#if DEBUG` 中编译（包括测试存储、云能力替代、模型 fixture 和测试辅助值）；Release 不识别这些参数，App 与 Share 的产物审计禁止 `--ui-test` 前缀标记。测试 fixture 截图须使用 Debug，不能靠 Release 启动参数启用。

轻点正文展开工具，在阅读设置切换模式、字号和行距；“目录”中有章节、书签、笔记，搜索独立展开。长按正文可标注或写批注，点已有高亮可编辑。试用重点是连续阅读、定位返回和位置稳定，具体行为见[正文](../reader/reading.md)与[阅读工具](../reader/tools.md)。

参考：[UniFFI Swift 绑定](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html)、[Xcode 集成](https://mozilla.github.io/uniffi-rs/latest/swift/xcode.html)。
