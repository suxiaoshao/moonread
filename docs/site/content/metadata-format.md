+++
title = "小说信息交换格式"
[extra]
kind = "metadata"
+++

## 整理信息，再带回书架

月读 1.5 的「设置 → 数据管理 → 小说信息」可导出、导入书名建议、作者、标签、简介、自设封面和阅读状态。可以自己编辑，也可把导出的清单交给 agent 整理，再在月读逐项确认。

它不包含小说正文、阅读进度、书签、笔记、统计或授权。恢复阅读记录请使用独立的「阅读数据备份」。资料不会自动联网补全。

- [下载 JSON Schema 2020-12](../schema/moonread-metadata-v1.schema.json)
- [下载 agent Skill](../skills/moonread-metadata/SKILL.md) · [agent.txt](../agent.txt)
- 合成样例：[JSON](../skills/moonread-metadata/examples/metadata.json) / [JSONL](../skills/moonread-metadata/examples/metadata.jsonl)

## 身份与只读参考

`content_sha256` 是月读从已建立索引的正文得到的 normalization-v1 身份，不是 TXT 原文件的 SHA。请原样保留，不自行计算。导入只按它查当前书架索引；不按书名、路径或 `reference` 猜测，不读 TXT、不下载、不自动建立索引。

`reference` 包含导出时的标题、已知作者及所选范围内的书架/相对路径，只供理解书目。整个对象导入时忽略。没有索引的文件跳过并提示「N 本尚未建立索引，未导出」；找不到身份的记录显示「找不到这本书」。已索引但尚未下载的 iCloud 文件仍可交换已有资料。

## JSON、JSONL 与封面包

JSONL 每个非空物理行一个 Book，每条带 `v:1`；坏行单独报告，不影响其他行。JSON 使用下方信封，每本也带 `v:1`；语法损坏整份拒绝，单本字段错误单独报告。

```json
{
  "$schema": "https://suxiaoshao.github.io/moonread/schema/moonread-metadata-v1.schema.json",
  "format": "moonread-metadata",
  "version": 1,
  "books": [{"v": 1, "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "tags": ["待整理"]}]
}
```

使用 UTF-8，可有一个开头 BOM、LF/CRLF、末行无换行；不允许重复对象键、注释或尾逗号。

有自设封面时导出 ZIP，扩展名 `.moonread-metadata`：根目录恰好一个 `metadata.jsonl` 或 `metadata.json`，可含 `README.txt` 和 `covers/` 下 JPEG/PNG。封面路径相对包根，不接受 URL、base64、SVG、链接、绝对路径、`.`/`..`、反斜杠、重复或大小写碰撞成员。裸清单不能读取旁边的图片。包安全、大小与成员预算共用阅读备份的限制；图片仍须真实解码。

## 可以修改什么

| 字段 | 规则 |
| --- | --- |
| `title` | 不含扩展名的真实改名建议，默认关闭。只有当前全部书架中该正文唯一对应一个文件时提供；保持目录与原扩展名，不覆盖同名文件 |
| `author` | 一个非空作者文本，最多 1024 UTF-8 字节 |
| `tags` | 字符串数组，沿用月读去首尾空白、空项与重复项的规则；最多 100 项，每项最多 128 UTF-8 字节。默认追加，替换须在预览选择 |
| `description` | 非空简介，可换行，最多 64 KiB UTF-8 |
| `cover` | 包内 `covers/…jpg`、`.jpeg` 或 `.png`；缺失或坏图片只跳过封面 |
| `reading_state` | `unread` / `reading` / `finished` / `paused`；不改变位置。有阅读记录时只跳过 `unread`，不删除记录 |
| `clear` | 不重复的 `author` / `tags` / `description` / `cover` 数组，明确请求清空。不可同时给同字段赋值，不可清空书名或状态 |
| `requires` | 必需能力列表。v1 初始支持列表为空；未知必需能力阻塞该条 |

缺字段表示不改，`null` 不表示清空，空作者/简介无效。默认追加模式下 `tags:[]` 不改变标签。`series`、`authors` 及未知可选字段只提示未应用，再次导出不保证保留；原文件始终不改。Schema 检查结构，运行时另做 UTF-8 字节、能力、索引、文件与图片检查。

## 预览、确认与结果

默认只补空资料；已有不同值保留，标签追加。清空、标签替换和真实改名须明确选择。同 SHA 相同内容合并一次；字段冲突列出来源位置和值，让您选择或保留。多文件共用资料，但跳过改名建议。

每本资料一次原子保存；确认采用的字段沿用现有同步冲突规则，不再次要求您复核。存储失败停批次，取消在本与本之间生效，已保存的保留。结果分别列出已保存、失败与未处理；重导未再变化的资料不生成重复修订。

真实改名在资料保存后才做现有文件快照校验。原件未下载时不会为了改名下载，资料照常保存，结果说明未改名原因。改名后无需另生成清单；正文身份不变，历史 `reference.path` 不参与匹配。

问题清单 JSONL 只含来源行/记录号、代码、字段、有效正文 SHA 与受控原因，不附正文或私有绝对路径。请勿主动发送原始资料或小说给支持人员。
