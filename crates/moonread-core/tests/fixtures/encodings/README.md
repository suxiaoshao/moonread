# 原创编码样本

`corpus.json` 保存原创 UTF-8 文本、生成编码、BOM 标记与预期识别名称。测试用 encoding_rs（UTF-16 用标准库）在运行时生成输入字节，不保存真实作品或大二进制文件。覆盖 UTF-8/BOM、UTF-16LE/BE、GB18030/GBK（含短文本与四字节扩展）、Big5（含短文本）、Shift_JIS、EUC-JP、EUC-KR 和 windows-1252。新增 EOF 以 é 结尾的短 windows-1252、ISO-2022-JP 以及无 BOM UTF-16LE/BE，共 18 个样本；原 14 个样本内容与预期不变。

`encoding_detection` 集成测试经直接与渐进导入核对记录的编码、规范化正文、SHA 和原件不变；`sha_identity` 的既有简体样本固定值继续约束旧正文 SHA。`progressive` 单元测试另外固定统计不足单字“中”的 windows-1252 结果，并覆盖 BOM；text 单测覆盖真实 EOF 严格校验、有界截断 UTF-8/UTF-16 及二进制拒绝。升级精确锁定的 chardetng 前必须重跑，发布后不得悄悄调整预期来接受已支持文件的身份变化。
