# 元数据交换格式历史调研

调查日期：2026-10-21；2026-10-30 从本机调研稿提炼。原稿提出的 `.moonread-metadata`、JSON `books[]`、CSV/OPF 适配器及具体字段只是当时建议，未确认为产品格式；本页不冻结 schema、不重启旧实施方案。当前身份与备份合同以[数据](../data/README.md)及[备份](../data/backup-and-cleanup.md)为准。

## 保留的格式取舍

调查未找到可直接完整采用、同时覆盖 TXT 书目、人工章节锚点、整库匹配和私人阅读状态的通用格式。它比较的是各格式负责什么，不是宣布必须全部支持。

| 格式 | 调查中可借鉴的用途 | 不能直接承担的职责 |
| --- | --- | --- |
| OPF 与 Calibre 旁置文件 | 作者、标签、简介等书目字段及封面关联 | Calibre 的 `metadata.opf` / `cover.jpg` 是文件组织约定；一个扁平目录有多本 TXT 时不能自动共享同一份资料 |
| CSV 目录 | 表格批改与多书列映射 | 路径、标签/作者分隔和清空语义需单独约定；不适合直接容纳嵌套章节，空单元格也不能默认删除旧值 |
| EPUB 导航、NCX | 章节标题与层次 | 原目标是内容文档及 fragment；自造 TXT 行号链接不会自动成为可互操作的 EPUB 标准 |
| schema.org Book / JSON-LD | 网页和知识图谱中的书目语义 | 不定义本地包、安全路径、正文身份、私人状态或冲突处理 |
| ONIX、ComicInfo | 出版元数据或漫画旁置组织的参考 | ONIX 的供应链语义对当前需求过重；漫画图像页序号不能当 TXT 锚点 |

原调查参考：[Calibre CLI](https://manual.calibre-ebook.com/en/generated/en/calibredb.html)、[Calibre OPF2](https://github.com/kovidgoyal/calibre/blob/master/src/calibre/ebooks/metadata/opf2.py)、[W3C EPUB 3.3](https://www.w3.org/TR/epub-33/)、[schema.org Book](https://schema.org/Book)、[ComicInfo](https://anansi-project.github.io/docs/comicinfo/intro)。源码分支链接没有固定 SHA；本次未重新抓取，不把这些旧观察称为最新兼容结论。

## 将来设计时必须分开的边界

- 交换用路径和外部 ID 帮助寻找文件，不能替代 normalization-v1 正文 SHA。相同正文多个副本的资料冲突应明确处理；强标识矛盾时不能悄悄降级成同名匹配。
- 书名来自真实文件名。外部 `title` 不自动改名或创建显示别名；系列、多作者等模型扩展必须单独决定，不能藏进格式导入。
- 资料导入是用户本次编辑，备份恢复则保留事实身份、修订、删除及合并语义。普通资料快照不能冒充可恢复完整阅读数据的备份。
- 未提供、显式清空、赋新值要有不同含义；导入前预览未支持或有损字段。不要承诺 OPF/CSV 全字段无损往返。
- TXT 章节锚点需确认正文版本及坐标体系。仅有身份索引不等于已有可校验章节的正文；重复章名、书前目录、编码和 CRLF 都会影响定位。
- 资源与文件授权分开：拿到 JSON 不代表可以读取旁边所有图片；只在明确导入/导出时操作，不在日常阅读中写旁置文件。资源路径、符号链接、包大小与未知版本按实际交换边界另行设计。

没有安装竞品、执行往返导入、验证真实 Calibre 导出或表格公式转义。旧稿具体容器、字段枚举及实施顺序不作为当前承诺；正式交换功能应按当时有效的 issue 与产品决定重新设计。
