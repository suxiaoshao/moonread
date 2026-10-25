# 月读 · Moonread

本地 TXT 小说阅读器，支持 iPhone 和 iPad，为舒服、连续的阅读而作。

[在 App Store 下载](https://apps.apple.com/app/id6823849812) · [官网、隐私政策与支持](https://suxiaoshao.github.io/moonread/)

## 阅读与书架

- 滚动与分页阅读，支持目录及手动修正、书签、标注、私人批注和阅读位置恢复。
- 多套浅深配色、纯黑夜间、自定义配色与纸张纹理；排版和阅读控制可实时预览。
- 所有书架都是真实文件夹。支持导入 TXT、从其他 App 分享或打开 TXT、文件改名/移动/删除、列表/网格与按标签浏览。
- 全量索引关联同正文的进度与资料；按书名、作者、标签找书。书内搜索支持字面量与单行 Rust 正则，不等于完整 ripgrep 功能。
- 阅读统计、小说信息与封面编辑；阅读数据可全量备份、导入合并或单独删除，可重建缓存可独立清理。

“我的书架”由应用管理固定的本地与 iCloud Documents 目录，其他文件夹通过系统授权添加。小说原件与按正文 SHA 保存的阅读数据分离；同正文的不同文件可共用阅读记录，正文改变后保留旧记录。CloudKit 私有库同步阅读数据与配色方案，排版、当前配色选择等设备偏好留在本机。详见[数据与来源](docs/dev/data/README.md)。

## 可选 AI 助手

AI 默认关闭，支持用户自己的 API Key 或受支持的登录方式；基础阅读不依赖 AI。可查询书籍、正文、批注和统计，使用已配置服务联网搜索或生成图片，并提出资料、封面和书架整理建议。首次向 AI 发送内容须经用户同意，业务修改由用户确认。中国大陆店面不提供 AI 功能；可用能力与服务权限见 [AI 设计](docs/dev/design/ai.md)。

## 开发

最低 iOS 18，使用 Xcode 27 和 Nix。Rust 负责正文与业务计算，Swift 负责原生界面、排版及平台适配，SwiftData 保存用户事实；每条规则的归属见[架构](docs/dev/engineering/architecture.md)。

- [开发文档入口](docs/dev/README.md)：现行规则与专题导航。
- [开发环境](docs/dev/engineering/development.md)：`nix develop`、构建与签名，无需独立安装 Rust。
- [项目约定](AGENTS.md)与[仓库/CI](docs/dev/engineering/repository.md)。
- [后续安排](docs/dev/roadmap.md)与[验证记录](docs/dev/engineering/verification.md)：区分已实现能力、未实现设计和实际验收边界。

## 许可

自有代码与原创样本采用 [MIT License](LICENSE)，Copyright (c) 2026 suxiaoshao。依赖、字体、品牌图标与开发资料保留各自许可，详见[第三方声明](THIRD_PARTY_NOTICES.md)及 App 随附的完整许可文本。
