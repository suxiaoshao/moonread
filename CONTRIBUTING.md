# 开发与贡献

月读优先保护真实文件、阅读位置和连续阅读体验。开始前阅读[项目约定](AGENTS.md)、[产品方向](docs/dev/product.md)与[开发文档入口](docs/dev/README.md)；待讨论计划不是实现授权。问题或改动应说明用户场景、期望行为和验证范围，不附小说原文、凭据或个人签名信息。

## 环境与运行

需要 macOS、Xcode 27 和启用 flakes 的 Nix。App 最低 iOS/iPadOS 18；Nix 管理 Rust、targets 和开发工具，本机 Xcode 提供 SDK、签名和运行。Linux 可开发 Rust 核心，不构建 iOS App。

```sh
nix develop
open ios/Moonread.xcodeproj
```

在 Xcode 选择 `Moonread` scheme 与已有模拟器，Build / Run；工程会通过 Nix 编译 Rust 并生成绑定，不另安装 Rust 或添加独立构建脚本。真机需要你自己的签名配置，按[开发环境与签名](docs/dev/engineering/development.md)操作，配置文件留在本机。构建、安装、启动与验收分别记录。

## 改动与验证

- 每条业务规则只有一个归属方，先查[架构归属表](docs/dev/engineering/architecture.md)，不要在 Swift/Rust 或不同入口复制规则。
- 已发布数据保持可读；正文身份/解码稳定、迁移与 CloudKit 只增不删要求见架构。不能通过清空数据或要求重装完成升级。
- SwiftUI 实现与审阅使用仓库 [SwiftUI Expert](.agents/skills/swiftui-expert-skill/SKILL.md)。新增界面文案补齐简中、繁中和英语。
- 按[测试原则](docs/dev/engineering/verification.md)保护独立的重要规则：Rust 为主，Swift 测边界和自身状态，UI 只留关键用户流程。命令由开发环境文档维护，纯文档改动核对引用和 diff，不启动 App 测试。
- 当前开发基线为 `release/1.3`；功能 PR 指向版本分支，main 对应线上版本。具体协作、提交与合并门槛见[分支规则](docs/dev/engineering/development.md#分支与协作)。不擅自合并、打 tag、上传或提交审核。

## 导航

[开发文档](docs/dev/README.md)按数据、阅读、界面、AI、工程与计划组织；[仓库与 CI](docs/dev/engineering/repository.md)维护 GitHub 设置和持续检查；[发布手册](docs/dev/engineering/release.md)维护 verify / upload 与 App Store 阶段。测试日志、截图和实验材料放忽略的 build，小说原件与凭据不提交。

修复实际行为时同步更新对应规则；历史结果写[验证历史](docs/dev/engineering/verification-history.md)，不要把某次 CI 或试用结果当成全平台保证。
