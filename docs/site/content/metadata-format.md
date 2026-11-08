+++
title = "在 App 外整理小说信息"
[extra]
kind = "metadata"
+++

可以修改月读导出的信息清单，也可以直接从本机 TXT 生成一份新清单。自己整理或交给 agent 处理作者、标签、简介与封面，最后在月读逐项确认。

此功能适用于月读 1.5；交换的是书目信息，恢复进度、书签和笔记请用「阅读数据备份」。

## 可以用来做什么

- **统一标签**：把「科幻」「科幻小说」整理成同一种写法，给一批书补上分类。
- **补齐资料**：根据手头可靠的信息，补作者、简介和自设封面，不必在手机上逐本输入。
- **整理阅读状态**：批量标记阅读中、读完或暂搁，不改变读到的位置。
- **准备改名建议**：统一文件名的写法，回到月读后再决定哪些要改。

## 三步，整理并导入小说信息

### 1. 选择起点：清单或 TXT

**已有月读资料：**打开「设置 → 数据管理 → 小说信息 → 导出」，选择全部书架或一个书架，保存 JSONL/JSON 清单；包含自设封面时会打包为 `.moonread-metadata`。在副本上编辑，保留现有正文身份与来源参考。尚未索引的书会跳过并计数；已索引但未下载的 iCloud 书可导出已有资料。

**还没有清单：**直接给本机 agent 指定 TXT 文件，让它按下文公开的 normalization-v1 算法计算正文身份，生成 JSONL/JSON。无需先从月读导出。`reference` 可省略，也可填写已知的书名、作者、相对路径作参考；不知道的书架信息不编造。要导回月读，须把这些 TXT 加入书架并建立索引，才能匹配。

<div class="metadata-shots">
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../images/metadata/zh-dark-export-scope-480.webp 480w, ../images/metadata/zh-dark-export-scope-960.webp 960w, ../images/metadata/zh-dark-export-scope-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../images/metadata/zh-light-export-scope-960.webp" srcset="../images/metadata/zh-light-export-scope-480.webp 480w, ../images/metadata/zh-light-export-scope-960.webp 960w, ../images/metadata/zh-light-export-scope-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="选择导出范围与清单格式" loading="lazy" decoding="async">
</picture>
<figcaption>选择导出范围与清单格式</figcaption>
</figure>
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../images/metadata/zh-dark-export-result-480.webp 480w, ../images/metadata/zh-dark-export-result-960.webp 960w, ../images/metadata/zh-dark-export-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../images/metadata/zh-light-export-result-960.webp" srcset="../images/metadata/zh-light-export-result-480.webp 480w, ../images/metadata/zh-light-export-result-960.webp 960w, ../images/metadata/zh-light-export-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="导出完成后分享或存储清单" loading="lazy" decoding="async">
</picture>
<figcaption>导出完成后分享或存储清单</figcaption>
</figure>
</div>

### 2. 整理资料

两种起点都可以补作者、统一标签、整理简介与自设封面。JSONL 是一行一本书的文本清单，JSON 把书目放在同一份文档里；它们不是 Excel 表格。不熟悉格式时，可使用下一节的 agent 提示语。

已有清单保留身份；从 TXT 新建时按算法计算身份，之后不要用书名或文件路径替代它。资料不确定就省略对应字段，不猜作者、不编造简介。直接生成不等于必须把全文发给云端：哈希可在本机计算，只把想整理的资料交给外部服务。

### 3. 导入，逐项确认

回到「小说信息 → 导入」，选择整理好的文件。先看哪些书有变化，再点开看修改前后；**确认前不会保存这些修改**。

默认只补空白资料、追加标签，已有的不同值会保留。替换标签、清空资料和修改真实文件名都需要明确选择。改名建议默认不勾选；同一正文对应多个文件时，不提供改名操作。

<div class="metadata-shots">
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../images/metadata/zh-dark-import-preview-480.webp 480w, ../images/metadata/zh-dark-import-preview-960.webp 960w, ../images/metadata/zh-dark-import-preview-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../images/metadata/zh-light-import-preview-960.webp" srcset="../images/metadata/zh-light-import-preview-480.webp 480w, ../images/metadata/zh-light-import-preview-960.webp 960w, ../images/metadata/zh-light-import-preview-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="查看将更新的小说" loading="lazy" decoding="async">
</picture>
<figcaption>查看将更新的小说</figcaption>
</figure>
<figure>
<picture>
<source media="(prefers-color-scheme: dark)" srcset="../images/metadata/zh-dark-import-result-480.webp 480w, ../images/metadata/zh-dark-import-result-960.webp 960w, ../images/metadata/zh-dark-import-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px">
<img src="../images/metadata/zh-light-import-result-960.webp" srcset="../images/metadata/zh-light-import-result-480.webp 480w, ../images/metadata/zh-light-import-result-960.webp 960w, ../images/metadata/zh-light-import-result-1350.webp 1350w" sizes="(max-width: 400px) 84vw, 300px" width="1350" height="2760" alt="查看已保存的小说" loading="lazy" decoding="async">
</picture>
<figcaption>查看已保存的小说</figcaption>
</figure>
</div>

> 截图待补：逐字段对照与选择。

找不到的书会跳过；已有阅读记录的书不能改为「未读」，但其他选中的资料照常导入，阅读记录不会删除。保存中遇到错误或取消，已经保存的书会保留，结果页会说明失败原因与未处理项；重新导入时，已经保存且未再改变的资料会显示无变化。

## 交给 agent：说明输入与整理目标

这里的 agent 是您自行选用、能够处理文件的外部 AI 工具，**不需要开启月读内置 AI**。已有清单就附上副本；没有清单就向有本机文件访问能力的 agent 指定 TXT 路径。不能访问本机文件的工具，可使用您在本机算好的身份，不必上传全文。复制下方提示语并填写输入与整理要求。

```text
请为月读整理或生成小说信息清单，供我在 App 中逐项确认后导入。
输入：[清单副本，或本机 TXT 文件路径；填写一种]
整理要求：[例如统一标签，并根据我提供的可靠资料补作者与简介]

先阅读：
https://suxiaoshao.github.io/moonread/skills/moonread-metadata/SKILL.md
算法与可运行实现：
https://suxiaoshao.github.io/moonread/skills/moonread-metadata/identity/README.md
Schema：
https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json

如果输入是清单，保留已有 content_sha256 与 reference。
如果输入是 TXT，在本机只读文件，按 normalization-v1 生成 content_sha256；
使用公开参考实现，不用 Python 对 64 KiB 切片的严格解码代替检测。
若月读手选过编码，先使用同一编码。
不要把 TXT 原始字节的 SHA 当正文身份，不按书名或路径猜测。
不上传全文，不改写、移动或删除 TXT；不直接执行文件改名。
未知作者/简介不要编造，先列出疑问；未明确要求时不清空、不建议改名。

输出符合 Schema 的 JSONL、JSON 或带封面的 .moonread-metadata，
并列出改动、采用的编码和未解决问题；不要替我导入。
提醒我：月读需有对应书架索引；身份不匹配会跳过，可核对编码或改用导出清单。
```

若工具不能打开链接，请下载 [agent 编辑说明（Skill）](../skills/moonread-metadata/SKILL.md) 和 [JSON Schema](../schema/moonread-metadata-v1.schema.json)，与输入一起提供。Skill 是给工具看的操作说明；Schema 用来检查文件结构。不能处理封面包的工具，可以先只整理不带封面的清单。

**发送前检查资料内容。** 信息清单可能包含书名、作者、书架与相对路径，以及您填写的简介和自设封面。把它交给外部服务时，这些信息也会交给该服务；只发送您愿意分享的内容。

月读不会自动联网补全资料，也不会改写小说正文或输入清单。只有您在预览中明确勾选改名建议，才会修改真实文件名；不会搬动目录或覆盖同名文件。

## 格式参考：给 agent 与开发者

以下为 v1 契约。下载：[Schema 2020-12](../schema/moonread-metadata-v1.schema.json) · [Skill](../skills/moonread-metadata/SKILL.md) · [agent.txt](../agent.txt) · 合成样例 [JSON](../skills/moonread-metadata/examples/metadata.json) / [JSONL](../skills/moonread-metadata/examples/metadata.jsonl)。

### 字段与默认行为

每条书目必需 `v: 1` 和 `content_sha256`。省略可编辑字段表示不改；`null` 不表示清空，空作者或空简介无效。

| 字段 | 含义与限制 |
| --- | --- |
| `content_sha256` | 64 位小写十六进制的正文身份；已有清单保留原值，新清单按下述 normalization-v1 从 TXT 计算 |
| `reference` | 可选的书名、已知作者、书架与相对路径；已有清单保留，新建可省略；导入时整个忽略 |
| `title` | 不含扩展名的真实改名建议，默认不选；仅适用于当前全部书架索引中该正文唯一对应的文件；保持目录与原扩展名 |
| `author` | 单个非空作者文本，最多 1024 UTF-8 字节 |
| `tags` | 字符串数组；去首尾空白、空项和重复项，最多 100 项，每项最多 128 UTF-8 字节；默认追加，替换在预览中选择；追加时 `[]` 不改变标签 |
| `description` | 非空简介，可换行，最多 64 KiB UTF-8 |
| `cover` | 包内 `covers/…jpg`、`.jpeg` 或 `.png`；缺失或坏图片只跳过封面 |
| `reading_state` | `unread` / `reading` / `finished` / `paused`；不改变阅读位置；有阅读记录时只跳过 `unread` |
| `clear` | 明确请求清空 `author` / `tags` / `description` / `cover` 的不重复数组；不能同时给同字段赋值，不能清空书名或状态；预览默认不选 |
| `requires` | 必需能力列表；v1 初始支持列表为空，未知必需能力阻塞该条记录 |

`series`、`authors` 与未知可选字段只报告未应用，再次导出不保证保留。Schema 校验结构；字节上限、能力、索引匹配、文件安全和图片解码仍由运行时检查。

直接从 TXT 生成时，可以省略整个 `reference`。若提供 `reference.files`，每项包含 `title` 和相对 `path`，`shelf` **可选**；不知道书架时省略，不猜测、不填占位书架。例如：`"reference": {"files": [{"title": "合成样书", "path": "sample.txt"}]}`。已有导出清单的参考值保留。导入器在解析可编辑字段前丢弃整个 reference，它的内容不用于选书。

### 正文身份算法：normalization-v1

`content_sha256` 不是原文件的哈希，而是**解码并规范换行后的 UTF-8 文本的 SHA-256**，输出 64 位小写十六进制。文件名、路径、书目信息不参与计算。可以保留导出清单的身份，也可以从 TXT 按以下算法生成。

1. **确定编码。** 如果月读中手动选择过编码，外部计算也必须使用同一编码策略；标签按 `encoding_rs::Encoding::for_label` 解释（例如 `latin1` 实际是 Windows-1252），不能用另一语言的同名 codec 代替。`replacement` 和 `x-user-defined` 不接受。自动策略如下：
   - 从文件开头读取最多 **65,537 字节**。前 65,536 字节用于检测，多出的 1 字节只判断是否已到 EOF；文件大小 ≤65,536 时 `complete=true`。
   - 先调用 `Encoding::for_bom`：识别 UTF-8、UTF-16LE、UTF-16BE BOM，命中即采用。没有单独的 UTF-32 或无 BOM UTF-16 启发式；无 BOM UTF-16 应明确指定编码。
   - 无 BOM 时，用 UTF-8 decoder 的 `decode_to_utf8_without_replacement` 检查样本，`last=complete`。不是 malformed 且样本中**没有 ESC（0x1B）**时用 UTF-8；截断样本末端可以是不完整多字节字符，真正 EOF 则严格检查。
   - 否则用固定 **chardetng 1.0.0**：`EncodingDetector::new(Iso2022JpDetection::Allow)`，`feed(sample, complete)`，`guess(None, Utf8Detection::Deny)`；不传语言/TLD 提示。猜为 GBK 时改用 GB18030，其他结果原样采用。
2. **从头解码整个文件。** 使用 **encoding_rs 0.8.42** 的 `new_decoder_with_bom_removal()`，持续 `decode_to_utf8`，EOF 时以 `last=true` 完成解码。只移除与所选编码匹配的一个起始 BOM，不自动切换到别的编码。坏序列、孤立代理或末尾截断按该解码器的规则产生 U+FFFD，不能忽略坏字节，也不能简单假定每个坏字节对应一个替换字符。样本之后出错不重新探测/换编码。
3. **规范化。** CRLF → LF，剩余 CR → LF。除此以外原样保留：不 trim，不增加/删除末尾换行，不做 NFC/NFKC，不清除正文中或第二个 BOM、不删空格/制表符/控制字符/零宽字符，不应用智能缩进等显示规则。换行跨解码块时也按同样规则处理。
4. **哈希。** 对上述字符串编码为无额外 BOM 的 UTF-8，取 SHA-256。生产实现分块更新哈希；块边界、字数统计与分页不参与身份。

**不要用 Python 严格解码替代这一步检测。** `sample.decode('utf-8', errors='strict')` 会把 64 KiB 切片末尾当成 EOF：合法 UTF-8 文件若恰好在样本末尾截断了多字节字符，就会被误判。月读在文件还有后续字节时传 `last=false`，允许这个不完整尾部，但样本内部的坏序列仍不通过；只有真正 EOF 才传 `last=true`。请直接使用参考实现，或完整复现上述增量解码规则；也不能用 `errors='ignore'` 或 `errors='replace'` 代替检测。

阅读器另有接纳检查，不能把被拒绝的输入当成有效书：原始字节以 PNG（`89 50 4e 47 0d 0a 1a 0a`）、ZIP（`50 4b 03 04`）、gzip（`1f 8b`）或完整 JFIF 前缀（`ff d8 ff e0 00 10 4a 46 49 46 00`）开头时拒绝；解码后、换行规范化前按连续 **4096 个 Unicode 标量**分窗（末窗也检查），若 NUL ≥4 且占比 ≥10% 则拒绝。一个偶发 NUL、VT/FF、C1、已有 U+FFFD 等保留。规范化结果没有任何非空白字符时拒绝为空书（按 Rust `char::is_whitespace` 判定）。

### 可直接运行的参考实现

**运行前提与目录：**对外用户需要已安装的 Rust/Cargo（支持 edition 2024 及固定版本依赖；实测 Rust 1.99.0）和对应平台的原生链接器/构建工具。**不需要月读仓库、Xcode 工程、Nix 或 `nix develop`。**把 `Cargo.toml` 和 `identity.rs` 下载到一个新的空目录，在终端进入该目录，再用 TXT 的绝对路径执行下方命令。Cargo 构建的是下载的参考程序，不是 App；首次构建需要访问依赖仓库。没有 Rust/Cargo 时先准备工具链，不要悄悄换成 Python 检测器。

仅月读仓库开发者：`nix develop` 使用仓库的 `flake.nix`，应在仓库根目录运行，再执行 `cargo run --manifest-path /绝对路径/reference/Cargo.toml -- /绝对路径/book.txt auto`；参考目录不必放在仓库内。下载的两文件目录没有 flake，不能直接在那里运行 `nix develop`。

下载 [identity.rs](../skills/moonread-metadata/identity/identity.rs) 与 [Cargo.toml](../skills/moonread-metadata/identity/Cargo.toml)，放在同一目录；使用 Rust 2024 工具链，在该目录运行：

```sh
cargo run --release -- "/path/to/book.txt" auto
# 若月读手选了编码，使用同一标签，例如：
cargo run --release -- "/path/to/book.txt" gb18030
```

标准输出仅为哈希，标准错误输出实际采用的编码或拒绝原因。程序只读本机文件、不联网发送正文；首次构建会下载 Cargo 依赖。为便于审阅，示例把整个文件读入内存；月读生产代码使用流式解码。两者使用同版本解码器；以下是解码后的核心步骤，**不能把它单独当成完整编码识别程序**：

```rust
use sha2::{Digest, Sha256};
let (decoded, _) = encoding.decode_with_bom_removal(bytes);
let normalized = decoded.replace("\r\n", "\n").replace('\r', "\n");
let digest = Sha256::digest(normalized.as_bytes());
let content_sha256 = digest.iter().map(|b| format!("{b:02x}")).collect::<Vec<_>>().join("");
```

完整实现包含自动检测、BOM、容错与接纳检查，依赖固定为 chardetng 1.0.0、encoding_rs 0.8.42、sha2 0.11.1。不把 Python `chardet`、`charset-normalizer` 或默认 `open()` 当成等价实现。提供 [原创 TXT 样例](../skills/moonread-metadata/identity/sample.txt) 与 [直接生成的 JSON 样例](../skills/moonread-metadata/identity/generated.json)；在月读中导入 TXT 并建立索引后，可用 JSON 验证匹配。校验记录见 [参考实现说明](../skills/moonread-metadata/identity/README.md)。

非 UTF-8 文件使用不同检测器、不同解码映射/容错或与月读不同的手选编码，身份可能对不上；短文件尤其不能凭编码名称猜测。匹配失败显示「找不到这本书」并跳过，不会按名字或路径改另一部书。可先核对月读采用的编码，或改用月读导出清单中的身份。即使外部已算好身份，月读当前书架仍须有相应索引；资料导入不会自动下载正文或建立索引。

### JSON 与 JSONL

JSON 使用以下结构；示例身份仅为占位，实际使用时保留已有值或从 TXT 按上述算法计算。

```json
{
  "$schema": "https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json",
  "format": "moonread-metadata",
  "version": 1,
  "books": [
    {
      "v": 1,
      "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "tags": ["待整理"]
    }
  ]
}
```

JSONL 不带外层结构，每个非空物理行一个书目对象，每条同样带 `v: 1`。坏行单独报告；JSON 语法损坏则整份拒绝，单本字段错误单独报告。使用 UTF-8，可有一个开头 BOM、LF/CRLF、末行无换行；不允许重复对象键、注释或尾逗号。

### 带封面的包

`.moonread-metadata` 是 ZIP：根目录恰好一个 `metadata.jsonl` 或 `metadata.json`，可含 `README.txt` 和 `covers/` 下的 JPEG/PNG。图片路径相对包根；裸清单不能读取旁边的图片。

不接受 URL、base64、SVG、链接、绝对路径、`.`/`..`、反斜杠、重复或大小写碰撞成员。公共上限使用二进制单位：ZIP 文件或裸 JSON/JSONL 文件最多 **512 MiB（536,870,912 字节）**；ZIP 所有成员解包后合计最多 **2 GiB（2,147,483,648 字节）**；最多 **100,000 个 ZIP 成员**（目录条目也计数）；单张封面文件最多 **32 MiB（33,554,432 字节）**；单条书目记录及可选 README.txt 各最多 **16 MiB（16,777,216 字节）**。包内清单共用 2 GiB 总预算；各字段仍遵守上面的更小上限。ZIP 中央目录另限 64 MiB。图片必须能解码；满足字节上限不代表可以绕过图片或路径校验。

### 匹配与保存

匹配只看索引中的 `content_sha256`（normalization-v1），不是 TXT 原文件 SHA。不按书名、路径或 `reference` 猜测，不重读或下载 TXT，也不自动索引。正文变了导致身份不匹配时，报告「找不到这本书」并跳过。

同 SHA 的相同内容合并一次；矛盾字段列出来源位置和值，由用户选择或保留。每本资料原子保存，已确认字段沿用现有同步冲突规则，不在确认前再次复核字段。存储错误停止批次，取消在单本事务边界生效；重导未变化的资料不生成重复修订。

资料保存后才执行真实改名及现有文件快照校验。原件未下载时不为改名下载；改名失败保留已保存的资料，结果说明原因。改名后无需更新清单，历史路径不参与匹配。

问题清单 JSONL 只含来源行/记录号、代码、字段、有效正文身份与受控原因，不附私有绝对路径。反馈问题时，请勿主动发送原始资料或小说。
