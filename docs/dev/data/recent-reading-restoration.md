# 重装与新设备的最近阅读恢复

小说原件在真实文件夹／iCloud Documents；位置等私人记录在 SwiftData／CloudKit。文件扫描只索引元数据，不替整库解码。新设备缺少本机正文缓存与文件关联时，按位置记录的来源线索恢复少量最近条目，仍以 `content_sha256`（normalization-v1）验证身份，不能按文件名直接绑定。

## 发布前 v1 位置格式

`UserPosition.payload` 仍使用既有整数版本 envelope 和 LWW 的 updated/token/value，不新增 CloudKit 字段。内层位置所有字段显式出现：

```json
{"content_key":"正文 SHA","offset":1234,"source_hint":{"source_kind":"managed_icloud","relative_path":"分类/原创样本.txt","file_name":"原创样本.txt","byte_size":123456,"decoding":"auto"}}
```

`source_hint` 可以为 JSON null。非 null 时 source_kind、relative_path、file_name、byte_size、decoding 五键必须存在，byte_size 可为 null；其余不空。来源为 managed_icloud、managed_local、external；解码策略为 auto 或 Rust encoding_rs 的规范名称。拒绝未知字段／枚举／编码、类型错、缺键、绝对或越界路径、NUL、名称与最后路径组件不符及超限大小／路径。没有兼容默认字段。原始 shelf UUID、绝对路径、bookmark、授权凭据不进入同步 payload。

这是 1.0 尚未上架的明确格式修订：TestFlight build 2 缺少 source_hint 的旧记录会被原样隔离，并阻止同 key 的写入，不能被当作 null、自动覆盖或清除。测试数据重建／清理须另外授权，本实现不删除云记录或生产 schema。正式发布后字段演进继续遵循兼容规则。

真实保存位置时，填写当前阅读来源的路径、名称、可获得的原始大小与本机解码策略；来源未知时为 null，同 key 已有有效线索可沿用。线索与位置同一次 LWW 更新，移动／改名不伪造阅读时间。pending 提升只替换 content_key，保留线索、原时间和 token。

## 候选与自动下载预算

- 仅处理 last_read 最新的 10 个兼容 content key，与首页最近阅读上限一致；隐藏条目不恢复也不占可见条目的十个名额，不扩展到全部历史。
- 优先按来源范围与相对路径查找。路径未命中才使用文件名＋已知字节大小的有限回退；大小未知不做仅文件名回退。候选来自现有扫描／云元数据，不额外整库识别。
- 每 key 最多 3 个候选，超限不任意截断。少量已下载候选可依序验 SHA；远端有歧义时不自动下载。
- 只有线索唯一明确、hint 字节大小已知且不超过 50 MB（50,000,000 字节） 的 iCloud 候选才自动下载。阈值为 `RecentRestorationPolicy.automaticDownloadByteLimit`；网络沿用系统 iCloud 云盘的蜂窝数据设置，不另设网络策略。同一时刻只下载／准备一个文件，退后台暂停，可取消；取消不保证撤回系统或提供者已经开始的下载。
- 1.0 不加“下载并恢复”按钮或恢复状态页。线索失效、过大／大小未知、歧义、授权或解码失败时停止；用户主动打开正确文件后沿用正常 SHA 关联，不扩张为全库回退。
- 本机已有显式编码与线索冲突时不后台改设置。路径、大小只帮助选候选；只有规范正文 SHA 相等才准备并关联，成功前不覆盖文件编码。

## 后台准备与失效边界

Rust 纯身份探测复用 `text::decode_chunks`，流式计算原始／规范正文 SHA，不创建 books 或用户状态。验证后复用现有渐进缓存准备、去重与回收，但使用独立恢复生命周期；不调用 openSourceFile、不伪造阅读 lease、不发布 pending 文件关联、不做用户数据提升。

后台不写位置、事实、批注、StatisticsClear、最近时间、hiddenRecent 或首选来源，不更改原文件。完成时重验实际 SHA、源元数据、书架根、编码、位置 token 和恢复 generation；原子条件关联不能覆盖前台开书已改变的文件行。SQLite v20→v21 以增量迁移添加 `import_jobs.purpose`，既有任务默认为 reading，恢复专用任务为 restoration；普通导入不受恢复回收接口影响。仅回收自身未发布的临时任务，不删除共享 canonical 正文。进程重启时事务清理 restoration 未关联的 pending 草稿，保留普通暂停任务与已完成规范正文；不依赖一次进程内的 defer 清理，也不创建用户 pending 数据。

文件先到和云位置先到均触发相同 reconciliation；扫描完成、云导入和前台恢复会合并触发。失败缓存以位置 token 和候选元数据／编码／根为键；相同输入不轮询重复解码，相关变更或用户主动刷新可重试。前台开始准备／下载同一文件时即取消后台工作，准备期间也不重新准入；打开会话时再次保护；退后台／账户配置切换取消旧 generation，迟到结果不关联。

## 验证边界

单元／集成使用原创合成文件、内存用户 store 和受控 gate，覆盖严格格式、pending 提升、两种到达顺序、同名错文拒绝、候选／下载预算、无用户数据写入、取消与过期结果。真实 CloudKit 到达、iCloud 自动物化及 TestFlight 新格式重装另需用户验收，不以旧 build 2 数据证明恢复成功。
