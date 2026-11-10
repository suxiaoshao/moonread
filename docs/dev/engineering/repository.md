# 仓库与持续集成

本项目使用公开 GitHub 仓库。分支约定见[开发环境](development.md#分支与协作)；CI 和模板放在 [`.github/`](../../../.github)。

## 工具链分工

保留 `flake.nix` 和 `flake.lock`：前者声明 Rust、iOS targets、Clippy、rustfmt、nixfmt、actionlint、gitleaks 与 Zola，后者锁定实际版本。本机与 CI 都通过 `nix develop --no-update-lock-file` 进入同一环境，Cargo 命令使用 `--locked`。不再维护第二份 Rust 工具链配置，也不新增安装或构建脚本。

Nix 不替代 Xcode。Apple SDK、Swift 编译器、模拟器和签名由 Xcode 管理；iOS 全量单元测试在 GitHub 托管 macOS CI 运行，UI 与真机试用仍由本地按范围验证。工具链版本固定不等于整个 iOS 构建完全可复现。

## 自动检查

[CI](../../../.github/workflows/ci.yml) 在发往 `main`、`release/**` 或 `hotfix/**` 的 PR、这些分支的 push 及手动触发时启动，不使用工作流级 paths 过滤。`changes` job 用完整 PR diff 决定后续 job 是否运行：

| 改动范围 | PR 检查 |
| --- | --- |
| `crates/**`、根目录 `Cargo.*`、`flake.*` | 同一 macOS 作业中的 fmt／Clippy／Rust 测试及 iOS 单测 |
| `ios/**`、`assets/icon/**` | iOS 单测 |
| `docs/site/**`、`flake.nix`、`flake.lock` | `Website checks`：Nix 环境 `zola build`，不设为必需检查 |
| `.github/**` | actionlint，且全部检查都跑 |
| 其他文档等改动 | 密钥扫描；不相关的 job 跳过 |
| push 到 `main`／`release/**`／`hotfix/**`，或手动触发 | 全部检查 |

`Secret scan` 对任何改动都运行：gitleaks 扫描当前 HEAD 可达的已提交历史并遮盖密钥。`Workflow syntax` 仍在 Linux 运行 actionlint；网站生成检查同样留在 Linux。这些轻量作业不保存 Actions 缓存。

`Rust and iOS tests` 是唯一 macOS 执行作业，使用 `xcode-27` arm64 镜像，固定 Xcode 27.1 与镜像已有的 iOS 27.0 iPhone 18 Pro；缺失时失败，不新建模拟器或替换工具链。先要求密钥及适用的工作流检查成功，再恢复缓存、实现当前 Nix 环境、按 Rust 范围串行运行 fmt/nixfmt、工作区全 target/feature Clippy 和 Rust 测试，随后 build-for-testing 并运行完整 MoonreadTests。纯 Swift PR 跳过 Rust 规则检查，但 Xcode 仍每次构建 Rust/绑定；分支 push 和手动运行仍全检查。Cargo 使用 `--locked`，测试关闭并行、固定简中、ad-hoc 签名以保留真实 Keychain 接线，每项最多五分钟。

范围判断失败回退全检查。`release/1.6` 直接以 `Rust and iOS tests` 作为必需检查；PR 无相关改动时，该作业可按范围跳过。分支 push 的 [TestFlight 来源检查](development.md#testflight-手动-ci)仍要求该作业明确成功。同一 PR 的新提交取消旧运行。

### 单份 macOS 缓存

唯一写入 ref 在 workflow 的 `CI_CACHE_WRITE_REF` 显式声明，当前为 `refs/heads/release/1.6`；升级 release 时更新它。只有该 ref 的 push 在完整 Rust 检查和当前 iOS 构建成功后保存；精确命中不重存。PR、main、旧 release、hotfix 和手动运行只按 GitHub 正常作用域恢复，PR 不向基线回写。不使用 `pull_request_target`、PAT 或额外缓存后端。

单包保存 Cargo registry/git、`target` 的 host/simulator 产物、DerivedData、Debug UniFFI 生成目录及实际 Nix 用户输入缓存。CI 的 Xcode 构建启用原生编译缓存及命中诊断，CAS 路径显式设为 `build/DerivedData/CompilationCache.noindex`，随同一包恢复/保存；不另建缓存或改变本机工程设置。环境前缀包含实际 macOS/架构、Xcode build、SDK、Nix 版本和工具链/依赖锁指纹；源码、工程、scheme、xcconfig、资源和 CI 配置属于精确 key 后缀，工程小改不再隔断环境前缀恢复。Nix 输入尊重 `NIX_CACHE_HOME` / `XDG_CACHE_HOME`，不包含整个 `/nix/store`。新输入的展开体积先限 1.5 GiB，超过时不发布该代，记录证据后调整；这不冒充压缩存储量。

SwiftPM 的共享仓库缓存放在 `build/DerivedData/SwiftPMPackageCache`，同样随单包恢复与保存。每轮在缓存包外的 `build/SwiftPM/SourcePackages` 按当前提交的 `Package.resolved` 重新解析并检出；不复用上轮的工作副本或解析状态。旧缓存恢复出的 `build/DerivedData/SourcePackages` 会在解析前移除。解析和构建均要求使用锁定版本，且检查锁文件未被改写。

每个新包（含编译缓存）API 存储量预算为 4 GiB。独立清理作业先确认成功 key 在精确 writer ref 唯一可见且在预算内，再删除同命名空间更旧 ID 及明确列出的旧 Cargo/DerivedData 前缀；保留当前和更晚并发代，保存失败或 API 不可确认时不删旧。新代超预算只移除该新代，保留旧种子并报告容量未通过；不提高额度。迁移清理仅作用于 Actions cache ID，不删除日志、xcresult 或 TestFlight artifact。

缓存不决定测试源码：每次仍运行当前 Cargo、UniFFI 和 Xcode build-for-testing；先移除缓存中的旧 xctestrun，要求成功构建产生唯一当前 manifest，再显式用于 test-without-building。不会仅因 cache hit 直接测试旧 App，也不按提交时间伪造 mtime。UniFFI 先写临时目录，验证三个既有输出完整，再逐文件 cmp；未变保留 mtime，缺失/有变化才替换，失败停止构建。

阶段耗时、源码与环境身份、展开尺寸（CAS 与 SwiftPM 单列但不重复计入 DerivedData）、缓存命中、SwiftPM 解析日志、编译缓存诊断、Xcode build timing、Rust/Swift 测试日志和 xcresult 保留七天；restore/save 耗时以 Actions 步骤为准，压缩包大小以 API 为准。冷缓存 PR 只读，热缓存及 Swift/Rust 源码负向对照等待 release push 生成首个种子后执行。本工作流没有打包上传逻辑，不能将性能检查当发布或真实环境验收。

构建作业只读仓库，checkout 不保留凭据；只有受信任的当前 release push 的独立缓存清理作业具有 `actions: write`，不 checkout 或执行 PR 代码，引用的 Actions 固定到完整提交 SHA。不使用 `pull_request_target`，也不让工作流自动批准或合并 PR。

## 仓库设置

- 仓库公开，默认分支 `main`；使用 Issues，关闭 Wiki、Projects 和 Discussions，避免与开发文档形成重复入口。
- 开启 squash 与 merge commit，关闭 rebase merge。功能 PR 对当前 `release/x.y` 使用 squash；发布后的 `release/x.y` → `main` 使用普通 merge。线上 hotfix 从 `main` 开 `hotfix/x.y.z`，在分支上修复、打包和提审，上线后才普通 merge 回 `main` 并打 tag，再把 `main` 合进当前 release。合并后自动删除普通开发分支；受保护的 main 与 release 分支禁止删除。合并方式由维护者选择，仓库开关不会按 PR 来源自动限制。
- PR 合入 `release/x.y` 或 `hotfix` 分支时，GitHub 不会根据 `Closes` 自动关闭 issue。合并后需手动关闭对应 issue，评论注明合入的分支与提交，并把看板状态改为「完成」。
- Actions 允许范围设为全部允许；仍强制引用固定到完整 SHA，默认 token 只读，不允许其创建或批准 PR。当前工作流只使用 GitHub 官方 Actions 和 Nix 安装 action。
- 启用 Dependabot 漏洞提醒与安全更新；Cargo 和 Actions 的常规版本更新每周向当前 `release/x.y` 提出 PR，同类兼容更新分组，不自动合并；每次新开版本分支同步修改两个 `target-branch`（当前配置 `release/1.6`）。Dependabot 安全更新 PR 总是开到默认分支 `main`，不受 `target-branch` 控制；收到后先把 base 改成当前 `release/x.y`，按版本分支流程修复、验证和发布，不提前把 App 修复合入 main。紧急漏洞走上述 hotfix 流程，在补丁上线后再普通 merge 回 main 并同步当前 release。Nix 输入由维护者显式更新锁文件并验证。

`main` 的 App 代码始终对应 App Store 最新发布版本。开发改动（含官网和文档）进入当前 `release/x.y`；正式发布后普通 merge 到 `main` 并打 tag（如 `v1.1`），线上 hotfix 按上述发布流程处理。[TestFlight 工作流](development.md#testflight-手动-ci)只在 `main` 执行，工作流维护先通过 PR 合入 `main`，再同步到当前 release。完整流程见[分支与协作](development.md#分支与协作)。

公开仓库的分支保护已启用：`main` 与 `release/**` 均必须通过 PR 和目标分支的必需检查，解决所有讨论，禁止强推及删除。`release/1.6` 要求 `Rust and iOS tests`；`main` 和旧 release 分支仍要求 `Linux checks` 和 `iOS unit tests`。不要求其他人的批准，不要求分支在检查前更新至最新基线，不强制线性历史，以允许 release → main 的发布回合；保留现有管理员处理规则。

## 源码与公开边界

自有代码使用根 MIT 许可，第三方许可与源码取得方式见 [THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md)。App 包含完整许可文本；依赖更新时一并核对锁定版本、字体声明和素材来源。

公开回归使用原创或程序生成样本，不携带私人书库名称、阅读记录、聊天快照或第三方封面。历史性能数据采用匿名样本描述，保留实测结果与局限，不改称为原创样本测量。`build/`、签名文件及审计原始材料不随源码分发。


## 提交与反馈

PR 模板记录改动、实际验证和必要限制；问题模板记录设备/版本、复现步骤及实际表现，建议模板从使用场景开始。简单事项允许空白 Issue。不添加需要个人开发者批准自己 PR 的 CODEOWNERS 规则。

参考：[Actions 安全配置](https://docs.github.com/en/actions/reference/security/secure-use)、[分支保护规则](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)。

## 政策与支持网站

网站源码位于 `docs/site/`（Zola 配置、content、templates、static），与应用一起审阅。正式根地址为 `https://suxiaoshao.github.io/moonread/`，提供中英文隐私政策与支持页。

本地预览：先在仓库运行 `nix develop --no-update-lock-file`，再执行：

```sh
cd docs/site && zola serve
```

构建使用 `zola build`；`docs/site/public/` 是生成目录，不提交。Zola 来自项目 devShell，不另用 `nix shell` 安装。

[Pages 工作流](../../../.github/workflows/pages.yml) 在 main 的网站源码、工作流或 Nix 配置变化时构建，也支持手动触发。两种触发方式均照常构建并上传 Pages artifact，仅在事件中的 `repository.private == false` 时执行 deploy，私有仓库跳过部署。仅 deploy job 授予 `pages:write` 与 `id-token:write`；checkout 不保留凭据，Actions 使用完整 SHA。不发布其余开发文档。

`docs/site/**` 与其他改动一样进入当前 `release/x.y`，发布后随版本分支合并到 `main`，再由 Pages 部署。审核前确需提前上线的隐私政策、支持页等网站页面，须先向用户申请，不自动视为例外。

当前仓库已公开，Pages 来源已设为 GitHub Actions（`build_type=workflow`）。网站部署与 App 发布分别验证，不把构建通过等同于线上页面已验收。旧 `suxiaoshao/moonread-site` 仓库已于 2026-10-17 删除。

## 测试边界

测试职责与推送前单测要求统一见[测试原则](verification.md#测试原则)。

MoonreadUITests 保留少量独立小样本主路径，具体清单以测试源码为准；U04 真实重启，其余不叠加重启、外观矩阵或系统选择器/菜单验证。U15 从已选文件接收边界导入；U19 经 NSItemProvider 测试适配器发布真实 ShareInbox 清单再由主 App 消费，不声称覆盖第三方宿主的分享面板。默认只附失败截图。原 008、009、105 删除，不另设每 PR 性能通道。

商店截图由独立的 opt-in StoreScreenshots 流程生成，不计入日常关键 UI 流程；入口见[商店截图](development.md#官网与商店原图独立-debug-测试)。UI 按改动范围验证并记录实际用时，不能由测试数量推断全量预算。Rust 与 iOS 单测以同一提交的 CI 结果为准。

### 网站维护边界

中英同步，无统计、第三方字体或外部脚本；原生系统字体、App Store/GitHub 链接同页打开。已有首页下载入口不等于阅读预览已经实现。后续预览只用原创正文，颜色与纹理参数从 App 唯一来源生成，允许的交互脚本需说明用途；不引入框架、网络追踪或另一套手抄主题。动效遵守 prefers-reduced-motion。当前公开政策不从 build 旧草稿再复制。
