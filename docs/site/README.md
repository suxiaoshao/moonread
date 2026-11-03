# 官网

使用项目 Nix 环境的 Zola，中英文静态生成；不引入外部字体、脚本或统计。部署与分支流程见 [repository.md](../dev/engineering/repository.md#政策与支持网站)。

## 1.2 阅读预览

`config.toml` 的 `extra.reading_preview` 控制是否输出预览，关闭时不输出其正文、控件、脚本或样式。当前随 1.2 上线；首页按中英文分别使用 1.2 商店截图，并以 WebP 压缩交付。

修改 Rust 配色/纹理/排版描述、相关本地化或 App 纹理原图后，从仓库根运行：

```sh
nix develop --no-update-lock-file -c cargo run --locked -p moonread-core --bin site-theme-data -- --write
nix develop --no-update-lock-file -c cargo run --locked -p moonread-core --bin site-theme-data -- --check
nix develop --no-update-lock-file -c zola --root docs/site build
```

导出器直接调用 moonread-core，生成 `data/themes.json`（schemaVersion 3），含配色、专属纹理 descriptor、图层/锚点/尺度限制/混合参数、三语资源中的中英文名称、排版控件。逐字节复制正式 Asset Catalog RGBA 并记录 SHA-256；`--check` 同时拒绝过期数据、错误字节和额外旧 mask。CI 将正式 ReaderBackdrop 素材列为生成输入。

阅读预览只在支持配色时显示纹理 checkbox，按配色独立开关；没有通用纹理/强度选择。图案固定于阅读预览容器外，由共享 descriptor 按实际容器计算图块：纸纹 cover、云雾上下贴边、植物左右/四角完整等比放置，尺寸变化只改已有图层 frame；不再按横竖换整稿。所有支持项和参数都来自 Rust 数据，不在 JS 复制名单。内联脚本只处理当前页面内存，不调用 API、不记录访问、不持久化、不改 App；没有脚本时仍显示纸色与原创正文。字体度量/断行归浏览器，不能把 Web 当成 TextKit 排版等价物。
