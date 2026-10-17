# 封面来源页面图片提取

`find_cover` 在本地提取一层搜索来源页面显式声明的图片，不向模型回传页面正文。工具输入/结果见[工具契约](tools.md)，产品展示见[AI 设计](../design/ai.md#封面)，验证证据见[验证记录](../engineering/verification.md)。

## 获取契约

`find_cover` 只请求两类 URL：

1. 本次搜索精确返回、经 sourceRef＋URL 授权的来源。
2. 这些来源页面按下文规则显式声明的一层图片资源。

具体约束：

- 相对地址可以依据最终响应 URL 和 `<base href>` 解析。不猜测路径，不修改 query，不跟随普通链接，不执行脚本，不把网页文本加入模型上下文。
- 派生的图片资源绑定原始搜索来源，只做图片解码，不再从中递归提取网页。它不是任意 URL 的下载入口。
- 沿用 URLSession/ATS 的重定向、DNS 和信任边界，不承诺 no-LAN。

## 执行流程

### 流程

`find_cover` 沿用共同工具 schema、结果结构和提案流程，“来源 → 候选”由本地执行器负责。整体串行执行，下载和解析不在 UI actor 上进行。

1. 托管搜索不变，得到 `native.sources`。
2. 按顺序处理每个 source，用现有 fetcher 完整下载它的响应。
3. 如果 ImageIO 能解码，按下文的尺寸筛选决定是否成为候选。
4. 如果不能解码，把以下内容交给 Rust 提取器：
   - 响应体的前 2 MiB
   - HTTP `Content-Type` 里的 charset（如有）
   - `HTTPURLResponse.url`，即重定向后的最终响应 URL
   - 书名

   提取器返回该页面声明的图片 URL，已解析为绝对地址。
5. 按顺序下载这些 URL，ImageIO 解码，通过尺寸筛选的成为候选。
6. 候选的 `origin` 仍是 `.web(原始搜索 source)`，sourceRef 保持为原始搜索返回的那个，不使用重定向后的 URL 或图片 URL。
7. 合格候选凑满 8 个就停止，剩余来源不再请求。

### 上限与筛选

- **下载与解析上限**：来源页和图片每个响应最多保留 10 MiB；声明长度或接收时累计数据超限即取消，记录 `too_large`。未知长度同样按累计字节限制。页面只把前 2 MiB 交给提取器，截断可能漏掉其后的图片声明。
- **解码上限**：先读 ImageIO 元数据；宽或高超过 4096 像素（因此最多 4096×4096）直接记录 `too_large`，不创建解码图像。
- **每页最多 4 个**：每个页面最多尝试 4 个去重后的图片 URL。lazy 属性得到的 URL 与其他规则得到的 URL 一起计数。
- **每次最多 8 个候选**：单次 `find_cover` 最多产出 8 个合格候选。这是候选数上限，不是请求数上限：不合格或失败的请求不计入。
- **去重**：同一次调用内，按请求前已解析的绝对 URL 字符串精确去重，保留查询参数，不排序也不删除签名参数，重复时保留首次出现的来源。重定向形成的 URL 别名不保证合并。
- **尺寸筛选**：解码后最短边小于 100px，或宽高比 w/h 大于 1.2 的丢弃。直链图片和派生图片都适用这条筛选。这只是首版启发式：方形 logo 仍能通过。阈值集中放在一处。
- 这些规则只作用于 `find_cover`，不修改通用的 ImageStore 和生图规则。图片本身不加 MIME、后缀或字节数门槛。

### Rust 提取器（moonread-core）

`cover_page.rs` 通过 UniFFI 导出：

```
extract_page_images(body: Vec<u8>, response_url: String, charset: Option<String>, title: Option<String>) -> Vec<String>
```

依赖：`scraper`（基于 html5ever）和 `url`。不用正则替代 HTML 解析器。

**字符解码**按以下优先顺序判断编码，最后退回 UTF-8 lossy。使用已有的 `encoding_rs`。

1. HTTP charset
2. BOM
3. `<meta charset>` 或 `http-equiv` 声明

**基准地址**：取文档中第一个能相对 `response_url` 解析为有效 http(s) URL 的 `<base href>`，用解析结果作为基准；没有这样的 base 时，用 `response_url`。

**收集顺序**：按以下顺序收集，去重，最多 4 个。

1. `meta[property|name = og:image | og:image:secure_url | og:image:url]` 的 `content`。
2. `meta[name|property = twitter:image | twitter:image:src]` 的 `content`。
3. `link[rel~=image_src]` 的 `href`；`[itemprop=image]` 的 `content`、`src` 或 `href`。
4. `script[type="application/ld+json"]` 中的 `image`。
   - 支持字符串、数组、带 `url` 或 `contentUrl` 的对象（含 `ImageObject`）。
   - 支持顶层数组和 `@graph`。
   - 递归有深度保护，节点数也有上限。
5. 兜底的 `<img>`：`alt` 包含书名，或 `class/id` 含 `cover|bookimg|book-img|mainpic`。最多取 2 个。
   - 书名为空白或 nil 时，不做 alt 包含匹配。
   - 如果 `data-src`、`data-original` 或 `data-lazy-src` 按基准地址解析后是有效的 http(s) URL，优先用它；否则用 `src`。`/covers/a.jpg`、`//cdn.example/a.jpg` 这类相对地址同样有效。
   - `src` 是 `data:` 或 HTTP 占位图时，有效的 lazy URL 仍然可用。
   - 有效 lazy URL 和 `src` 只取一个，计入每页 4 个的上限。

只保留解析后 scheme 为 http(s) 且有 host 的 URL，忽略 `data:` 和 `srcset`。提取器不返回正文文字。

### Swift 侧

**`AICoverImageFetcher` 的两层职责**：

- 一层是“获取一个 URL 的字节和 `HTTPURLResponse`”。
- 另一层是授权：
  - 搜索来源要求 `allowedSources` 中精确的 sourceRef＋URL 配对。
  - 派生图片只能由“已授权来源页面的提取结果”这一类型构造。

API 上体现这种区分，不提供任意 URL 下载入口。

**Referer**：只在图片请求上设置，页面请求不设。图片请求每一跳（初始请求和每次重定向）都按最终页面 URL 与该跳的目标 URL 重新计算；如果规则是不发，就移除系统可能带上的 Referer。重定向时通过 URLSession 的 redirect delegate（`willPerformHTTPRedirection`）改写请求，系统的其他网络边界保持不变。

| 该跳目标相对于最终页面 | Referer 取值 |
| --- | --- |
| 同源 | 最终页面 URL，去掉 fragment 和 userinfo |
| 跨源 | 只发页面 origin |
| HTTPS 页面、HTTP 目标 | 不发 |

这条规则限制了应用主动发送的 Referer：页面 URL 中的查询参数只会发往与页面同源的目标。它不覆盖服务器端或其他渠道的泄露，所以不作“不会泄露”的笼统结论。是否设置移动 Safari 的 User-Agent，按实测站点结果决定，不预先加入。

**暂存与取消**：

- 维持串行执行。
- 一次调用内追踪所有已 `save` 的暂存 ID，而不只是已进入 candidates 的。
- 取消或调用失败时，清理本次调用中所有已 save、尚未提交的资产，包括已进入 candidates 的；覆盖“save 之后、append 之前”被取消的竞态。
- 正常成功时（包括达到 8 个后停止），只清理未选入返回结果的暂存资产。返回结果中的资产保留，交给既有提交机制。
- 其他调用的资产和已提交的资产都不动。
- 以后如果改成并发，由父任务统一负责去重、配额和暂存登记。

**默认 query 与工具描述**：

- 默认 query 使用偏向书页的表述，例如 `"<title> <author> 小说"`。
- 工具描述遵循上文获取契约。
