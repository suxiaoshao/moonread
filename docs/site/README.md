# 官网

使用项目 Nix 环境的 Zola，中英文静态生成；不引入外部字体、脚本或统计。部署与分支流程见 [repository.md](../dev/engineering/repository.md#政策与支持网站)。

## 阅读预览

`config.toml` 的 `extra.reading_preview` 控制是否输出预览，关闭时不输出其正文、控件、脚本或样式。预览与 App 的主题数据共用生成来源；首页截图来源见下文。

修改 Rust 配色/纹理/排版描述、相关本地化或 App 纹理原图后，从仓库根运行：

```sh
nix develop --no-update-lock-file -c cargo run --locked -p moonread-core --bin site-theme-data -- --write
nix develop --no-update-lock-file -c cargo run --locked -p moonread-core --bin site-theme-data -- --check
nix develop --no-update-lock-file -c zola --root docs/site build
```

导出器直接调用 moonread-core，生成 `data/themes.json`（schemaVersion 3），含配色、专属纹理 descriptor、图层/锚点/尺度限制/混合参数、三语资源中的中英文名称、排版控件。逐字节复制正式 Asset Catalog RGBA 并记录 SHA-256；`--check` 同时拒绝过期数据、错误字节和额外旧 mask。CI 将正式 ReaderBackdrop 素材列为生成输入。

阅读预览只在支持配色时显示纹理 checkbox，按配色独立开关；没有通用纹理/强度选择。图案固定于阅读预览容器外，由共享 descriptor 按实际容器计算图块：纸纹 cover、云雾上下贴边、植物左右/四角完整等比放置，尺寸变化只改已有图层 frame；不再按横竖换整稿。所有支持项和参数都来自 Rust 数据，不在 JS 复制名单。内联脚本只处理当前页面内存，不调用 API、不记录访问、不持久化、不改 App；没有脚本时仍显示纸色与原创正文。字体度量/断行归浏览器，不能把 Web 当成 TextKit 排版等价物。

## 首页与截图

首页依次展示舒服阅读、跨设备续读、书籍与记录，保留阅读预览和中英文政策入口。
截图通过 `data/screenshots.json` 选择手机、Duo 内/外屏、iPad、语言与系统明暗；文件在 `static/images/screenshots/`。
来源统一查 `build/Release/1.4-screenshots/sources.json` 中 `consumers` 含 `website` 的用途 ID；目录名不代表截图版本，以各项 `origin` 为准。只替换受已合并改动影响的画面，未变画面复用既有真实截图。1.5 已替换的槽位在 `data/screenshots.json` 记录源 ID、版本、SHA 与官方设备外框信息；完整原图嵌入对应 Apple 官方外框，尺寸不同只按比例缩放；原图不改动、不删除。官网和商店共用原图，不从宣传成图反裁，不借其他设备或语言、不反色冒充暗色。

派生沿用本机 ImageMagick，无额外安装/构建脚本或前端框架。派生产出约480/960/1600宽 WebP，不上采样；没有原图的槽位明确标记 pending，不能拿其他设备替代。后续补图时先更新核验来源记录，再重新派生对应图片与数据。 原图登记仍带未通过的 `review` 标记时，不接入该新图；保留该槽位上一张已核验的截图，待修复后再替换。英文 R10 的手机、Duo 内屏与 iPad 明暗六槽已换用 1.5 本地化修复后的原图。

本机 `zola serve` 不监听 `data/`，且会缓存 `load_data` 结果；更新截图索引后重启预览进程，再核验浏览器实际载入的数据。

`?device=phone|duo|ipad`、`display=outer|inner` 保存手选，语言切换与刷新保持；默认仅明确 iPad 标记选择 iPad，其他回退手机，不猜 Duo 身份。Duo 默认内屏。选择不写设备存储，无脚本时仍有手机 `<picture>` 明暗图。下方只加载当前场景，缺图/加载失败有文字回退；图片原比例展示，大图同页打开。官网构建不等于部署或 App 上架，本轮不改发布流程。
