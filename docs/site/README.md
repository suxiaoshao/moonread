# 官网

使用项目 Nix 环境的 Zola，中英文静态生成；不引入外部字体、脚本或统计。部署与分支例外流程见 [repository.md](../dev/engineering/repository.md#政策与支持网站)。

## 1.2 阅读预览

`config.toml` 的 `extra.reading_preview` 控制是否输出预览，关闭时不输出其正文、控件、脚本或样式。当前随 1.2 上线；首页按中英文分别使用 1.2 商店截图，并以 WebP 压缩交付。

修改 Rust 配色/纹理/排版描述、相关本地化或 App 纹理原图后，从仓库根运行：

```sh
nix develop --no-update-lock-file -c cargo run --locked -p moonread-core --bin site-theme-data -- --write
nix develop --no-update-lock-file -c cargo run --locked -p moonread-core --bin site-theme-data -- --check
nix develop --no-update-lock-file -c zola --root docs/site build
```

导出器直接调用 moonread-core，生成 `data/themes.json`（schemaVersion 1）并逐字节复制 Asset Catalog 的四张原始 PNG 到 `static/textures/`。完整角色色、每配色三档 alpha、控件默认值/范围/步长和平铺周期均来自 App 共享规则；名称读取 `Localizable.xcstrings`，缺少中英文词条则失败。JSON 中同时记录纹理 SHA-256。`--check` 拒绝缺失、过期或多余的生成纹理；CI 与 Pages 只检查，不自动更新文件。

`reader-preview-script.html` 只在当前页面内存处理原生选项和步进按钮，写入 CSS 变量，不调用 API、不记录访问、不持久化设置、不改 App。正文是原创合成示例；无脚本时仍显示默认纸面和正文，控件在初始化成功后才出现。纹理层固定在滚动容器外；Web 按 1 App pt≈1 CSS px 示意，字体度量/断行与 UIKit 有差异。
