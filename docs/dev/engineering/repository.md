# 仓库与持续集成

本项目使用公开 GitHub 仓库。分支约定见[开发环境](development.md#分支与协作)；CI 和模板放在 [`.github/`](../../../.github)。

## 工具链分工

保留 `flake.nix` 和 `flake.lock`：前者声明 Rust、iOS targets、Clippy、rustfmt、nixfmt、actionlint、gitleaks 与 Zola，后者锁定实际版本。本机与 CI 都通过 `nix develop --no-update-lock-file` 进入同一环境，Cargo 命令使用 `--locked`。不再维护第二份 Rust 工具链配置，也不新增安装或构建脚本。

Nix 不替代 Xcode。Apple SDK、Swift 编译器、模拟器和签名由 Xcode 管理；iOS 全量单元测试在 GitHub 托管 macOS CI 运行，UI 与真机试用仍由本地按范围验证。工具链版本固定不等于整个 iOS 构建完全可复现。

## 自动检查

[CI](../../../.github/workflows/ci.yml) 在发往 `main`、`release/**` 或 `hotfix/**` 的 PR、这些分支的 push 及手动触发时启动，不使用工作流级 paths 过滤。`changes` job 用完整 PR diff 决定后续 job 是否运行：

| 改动范围 | PR 检查 |
| --- | --- |
| `crates/**`、根目录 `Cargo.*`、`flake.*` | Linux fmt／Clippy／Rust 测试，以及 iOS 单测 |
| `ios/**`、`assets/icon/**` | iOS 单测 |
| `docs/site/**`、`flake.nix`、`flake.lock` | `Website checks`：Nix 环境 `zola build`，不设为必需检查 |
| `.github/**` | actionlint，且全部检查都跑 |
| 其他文档等改动 | 密钥扫描；不相关的 job 跳过 |
| push 到 `main`／`release/**`／`hotfix/**`，或手动触发 | 全部检查 |

`Secret scan` 对任何改动都运行：gitleaks 扫描当前 HEAD 可达的已提交历史，输出遮盖密钥，不扫描开发者本机 build/、签名配置或未提交文件。密钥扫描或适用的 actionlint 失败会使必需的 `Linux checks` 直接失败，保留拆分前的合并阻断效果；正常按范围跳过 actionlint 不阻断 Linux。Linux 同时检查 Rust/Nix 格式、工作区所有 target/feature 的 Clippy（禁止警告）及 Rust 测试；Cargo 命令均使用 `--locked`。

范围判断失败时退回全部检查。后续 job 以 job 级 `if` 跳过，保留 `Linux checks`／`iOS unit tests` 的检查名称；不相关的必需 job 显示 skipped（视为通过），不会因整个工作流未触发而一直 pending。同一 PR 的新提交取消旧检查。Cargo 缓存按平台、工具链及依赖区分，不上传本机数据或签名安装包。

`iOS unit tests` 使用官方 `xcode-27` arm64 镜像，显式选择 Xcode 27.1 与镜像已有的 iOS 27.0 iPhone 18 Pro；缺少时直接失败，不创建模拟器或替换工具链。Xcode 构建阶段通过 Nix 编译 Rust，xcodebuild 运行完整 MoonreadTests（不运行 MoonreadUITests），关闭测试并行，测试语言固定简体中文；模拟器使用 ad-hoc 签名以支持隔离命名空间的钥匙串适配器测试，单项最多五分钟。Cargo 与 DerivedData 分开缓存，日志及 xcresult 保留七天。本工作流没有 tag 发布或上传逻辑。长时性能、UI、最低系统和真实文件提供方仍按范围在本地验证，CI 不替代这些验收。

CI 工作流只读仓库，checkout 不保留凭据，引用的 Actions 固定到完整提交 SHA。不使用 `pull_request_target`，也不让工作流自动批准或合并 PR。

## 仓库设置

- 仓库公开，默认分支 `main`；使用 Issues，关闭 Wiki、Projects 和 Discussions，避免与开发文档形成重复入口。
- 开启 squash 与 merge commit，关闭 rebase merge。功能 PR 对当前 `release/x.y` 使用 squash；发布后的 `release/x.y` → `main` 使用普通 merge。线上 hotfix 从 `main` 开 `hotfix/x.y.z`，在分支上修复、打包和提审，上线后才普通 merge 回 `main` 并打 tag，再把 `main` 合进当前 release。合并后自动删除普通开发分支；受保护的 main 与 release 分支禁止删除。合并方式由维护者选择，仓库开关不会按 PR 来源自动限制。
- PR 合入 `release/x.y` 或 `hotfix` 分支时，GitHub 不会根据 `Closes` 自动关闭 issue。合并后需手动关闭对应 issue，评论注明合入的分支与提交，并把看板状态改为「完成」。
- Actions 允许范围设为全部允许；仍强制引用固定到完整 SHA，默认 token 只读，不允许其创建或批准 PR。当前工作流只使用 GitHub 官方 Actions 和 Nix 安装 action。
- 启用 Dependabot 漏洞提醒与安全更新；Cargo 和 Actions 的常规版本更新每周向当前 `release/x.y` 提出 PR，同类兼容更新分组，不自动合并；每次新开版本分支同步修改两个 `target-branch`（当前配置 `release/1.3`）。Dependabot 安全更新 PR 总是开到默认分支 `main`，不受 `target-branch` 控制；收到后先把 base 改成当前 `release/x.y`，按版本分支流程修复、验证和发布，不提前把 App 修复合入 main。紧急漏洞走上述 hotfix 流程，在补丁上线后再普通 merge 回 main 并同步当前 release。Nix 输入由维护者显式更新锁文件并验证。

`main` 的 App 代码始终对应 App Store 最新发布版本；每个版本在 `release/x.y` 开发，正式发布后普通 merge 回 main 并打 tag（如 `v1.1`）。完整流程见[分支与协作](development.md#分支与协作)。

公开仓库的分支保护已可用并启用：`main` 与 `release/**` 均必须 PR，必需检查为 `Linux checks`、`iOS unit tests`，必须解决所有讨论，禁止强推及删除。不要求其他人的批准，不要求分支在检查前更新至最新基线，不强制线性历史，以允许 release → main 的发布回合；保留现有管理员处理规则。

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

`docs/site/**` 是版本分支规则的例外：版本所需的隐私政策、支持页等网站改动，在提交 App Store 审核前以小 PR 直接合进 `main`，由 Pages 即时部署，不等待 App 发布；“main 等于线上版本”只约束 App 代码，网站可提前上线。

当前仓库已公开，Pages 来源已设为 GitHub Actions（`build_type=workflow`）。网站部署与 App 发布分别验证，不把构建通过等同于线上页面已验收。旧 `suxiaoshao/moonread-site` 仓库已于 2026-10-17 删除。

## 测试边界

测试职责与推送前单测要求统一见[测试原则](verification.md#测试原则)。

MoonreadUITests 保留少量独立小样本主路径，具体清单以测试源码为准；U04 真实重启，其余不叠加重启、外观矩阵或系统选择器/菜单验证。U15 从已选文件接收边界导入；U19 经 NSItemProvider 测试适配器发布真实 ShareInbox 清单再由主 App 消费，不声称覆盖第三方宿主的分享面板。默认只附失败截图。原 008、009、105 删除，不另设每 PR 性能通道。

商店截图由独立的 opt-in StoreScreenshots 流程生成，不计入日常关键 UI 流程；入口见[商店截图](development.md#商店截图独立-debug-测试)。UI 按改动范围验证并记录实际用时，不能由测试数量推断全量预算。Linux 与 iOS 单测以同一提交的 CI 结果为准。

### 网站维护边界

中英同步，无统计、第三方字体或外部脚本；原生系统字体、App Store/GitHub 链接同页打开。已有首页下载入口不等于阅读预览已经实现。后续预览只用原创正文，颜色与纹理参数从 App 唯一来源生成，允许的交互脚本需说明用途；不引入框架、网络追踪或另一套手抄主题。动效遵守 prefers-reduced-motion。当前公开政策不从 build 旧草稿再复制。
