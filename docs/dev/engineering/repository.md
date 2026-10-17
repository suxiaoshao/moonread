# 仓库与持续集成

本项目使用私有 GitHub 仓库。分支约定见[开发环境](development.md#分支与协作)；CI 和模板放在 [`.github/`](../../../.github/)。

## 工具链分工

保留 `flake.nix` 和 `flake.lock`：前者声明 Rust、iOS targets、Clippy、rustfmt、nixfmt、actionlint、gitleaks 与 Zola，后者锁定实际版本。本机与 CI 都通过 `nix develop --no-update-lock-file` 进入同一环境，Cargo 命令使用 `--locked`。不再维护第二份 Rust 工具链配置，也不新增安装或构建脚本。

Nix 不替代 Xcode。Apple SDK、Swift 编译器、模拟器和签名由本机 Xcode 管理；iOS 构建、定向测试、UI 与真机试用以本地验证为准，不在云端 CI 运行。工具链版本固定不等于整个 iOS 构建完全可复现。

## 自动检查

[CI](../../../.github/workflows/ci.yml) 在发往 `main` 的 PR、`main` 更新及手动触发时运行单个 Ubuntu 24.04 的 `Linux checks`：

- gitleaks 扫描当前 HEAD 可达的已提交历史，发现疑似密钥使检查失败；输出遮盖密钥，不扫描开发者本机 build/、签名配置或其他未提交文件。
- Rust/Nix 格式与 actionlint 工作流语法检查。
- Rust 工作区所有 target/feature 的 Clippy，禁止警告。
- Rust 工作区测试，Cargo 命令均使用 `--locked`。

文档改动也运行检查和密钥扫描，不再单独分类跳过。同一 PR 的新提交取消旧检查。Cargo 缓存按平台、工具链及依赖区分，不上传开发者本机数据或签名安装包。iOS、长时性能、全部 UI、最低系统和真实文件提供方按改动范围在本地验证；Linux CI 通过不替代这些验收。

CI 工作流只读仓库，checkout 不保留凭据，引用的 Actions 固定到完整提交 SHA。不使用 `pull_request_target`，也不让工作流自动批准或合并 PR。

## 仓库设置

- 保持私有，默认分支 `main`；使用 Issues，关闭 Wiki、Projects 和 Discussions，避免与开发文档形成重复入口。
- 只允许 squash 合并，关闭普通 merge 与 rebase merge。合并后自动删除开发分支，是否合并由维护者决定。
- Actions 允许范围设为全部允许；仍强制引用固定到完整 SHA，默认 token 只读，不允许其创建或批准 PR。当前工作流只使用 GitHub 官方 Actions 和 Nix 安装 action。
- 启用 Dependabot 漏洞提醒与安全更新；Cargo 和 Actions 每周提出依赖更新 PR，同类兼容更新分组，不自动合并。Nix 输入由维护者显式更新锁文件并验证。

**当前平台限制：** 私有仓库的分支保护需要 GitHub Pro 或更高套餐，当前账号 API 返回 403，因此 `main` 的“必须 PR、检查通过、禁止强推/删除”暂时只有协作约定，不能声称已强制生效。套餐支持后，要求 `Linux checks`、解决所有讨论，禁止强推和删除；个人开发无需强制另一个人的批准，也不要求线性历史。

## 公开前当前树准备

自有代码使用根 MIT 许可，第三方许可与源码取得方式见 [THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md)。App 包含完整许可文本；依赖更新时一并核对锁定版本、字体声明和素材来源。

公开回归使用原创或程序生成样本，不携带私人书库名称、阅读记录、聊天快照或第三方封面。历史性能数据采用匿名样本描述，保留实测结果与局限，不改称为原创样本测量。`build/`、签名文件及审计原始材料不随源码分发。

**公开前仍需完成：** Codex 认证通过独立 #18 改用官方 Sign in with ChatGPT（dynamic_agent_client + 127.0.0.1 回调），先验证 iOS 本机回调可行性。当前树清理不修改该认证，也不表示借用的 Codex CLI client ID 已获得授权。历史 Git/GitHub 材料和仓库可见性另行处理，本次不改历史或设置。

## 提交与反馈

PR 模板记录改动、实际验证和必要限制；问题模板记录设备/版本、复现步骤及实际表现，建议模板从使用场景开始。简单事项允许空白 Issue。不添加需要个人开发者批准自己 PR 的 CODEOWNERS 规则。

参考：[Actions 安全配置](https://docs.github.com/en/actions/reference/security/secure-use)、[私有仓库规则的套餐要求](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets)。

## 政策与支持网站

网站源码位于 `docs/site/`（Zola 配置、content、templates、static），与应用一起审阅。正式根地址为 `https://suxiaoshao.github.io/moonread/`，提供中英文隐私政策与支持页。

本地预览：先在仓库运行 `nix develop --no-update-lock-file`，再执行：

```sh
cd docs/site && zola serve
```

构建使用 `zola build`；`docs/site/public/` 是生成目录，不提交。Zola 来自项目 devShell，不另用 `nix shell` 安装。

[Pages 工作流](../../../.github/workflows/pages.yml) 在 main 的网站源码、工作流或 Nix 配置变化时构建，也支持手动触发。两种触发方式均照常构建并上传 Pages artifact，仅在事件中的 `repository.private == false` 时执行 deploy，私有仓库跳过部署。仅 deploy job 授予 `pages:write` 与 `id-token:write`；checkout 不保留凭据，Actions 使用完整 SHA。不发布其余开发文档。

当前仓库私有，本次只验证构建和工作流语法，不启用 Pages。开源切换时，先在新公开仓库启用 Pages 并将来源设为 GitHub Actions（`build_type=workflow`），再首次推送网站变更（或手动触发工作流），最后逐页验证新站；不能在 Pages 尚未配置时触发公开仓库的首次部署。旧 `suxiaoshao/moonread-site` 仓库已于 2026-10-17 删除。App 的新链接需要等新站部署后才可在线验收。
