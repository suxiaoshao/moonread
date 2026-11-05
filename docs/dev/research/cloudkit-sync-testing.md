# CloudKit / SwiftData 跨设备同步怎么测

2026-10-26。只读调研，不改代码、不登录 iCloud、不调用 cktool。月读的阅读事实走 SwiftData，底层是 `NSPersistentCloudKitContainer` 镜像私有库；小说原件走 iCloud Documents，不进 `CKAsset`。见[同步合同](../data/sync.md)。本文只谈阅读事实这条 CloudKit 路径。

整理说明（2026-10-30）：保留原调查日期与证据层级；本次未重新访问外部来源，也未执行文中任何账号、令牌或 schema 操作。它不是当前平台能力保证或自动化执行授权。

## 结论

业界能写进脚本、并且 Apple 明确支持的，是**开发环境的 schema 和原生 CloudKit 记录**，不是「用脚本扮演第二台设备，让 SwiftData 自动导入」。`NSPersistentCloudKitContainer` 的上传和导入由系统在后台调度，靠同一 iCloud 账号、网络和静默推送。官方端到端做法仍是：一台模拟器加一台真机，登录同一个 iCloud 账号，看日志和 CloudKit Console。

适合月读的分层：

1. 继续用现有单测覆盖身份、LWW 和合并。这些不连 CloudKit。
2. 脚本只读开发环境里已经导出的 `CD_` 记录，用来确认「这台设备确实传上去了」。
3. 第二台设备的导入仍要人开着已登录的模拟器或真机。不要在 CI 里登录 iCloud，也不要把用户令牌放进仓库。

## 有出处的事实

### 开发环境、模拟器和多设备

1. 开发和模拟器默认走 Development。Xcode 跑在真机上默认也是 Development。TestFlight 和 App Store 默认走 Production，不受把 entitlement 改成 Development 以外的普通调试影响；真正用哪个环境看签名后的 `com.apple.developer.icloud-container-environment`。来源：<https://developer.apple.com/documentation/cloudkit/ckcontainer> 的 Testing Your Code Using the Development Container；DTS：<https://developer.apple.com/forums/thread/795826>。

2. 保存记录必须有 iCloud 账号。文档写明在模拟器或测试设备的「设置」里登录；每台要测的模拟器都要登录。开发用的 iCloud 账号和 Apple Developer 账号不是同一个东西，可以用同一个邮箱。来源：<https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app>。

3. Core Data with CloudKit 可以在模拟器里跑，也可以用多台登录同一 iCloud 账号的真机。私有库里有一块专供这次镜像的 record zone，只有当前用户能访问。设备要解锁，并连上稳定无线网。同步在系统后台进行，应用不用自己写上传代码；官方把节奏比作水循环，不是保存后立刻到达。来源：<https://developer.apple.com/documentation/coredata/mirroring-a-core-data-store-with-cloudkit>，<https://developer.apple.com/documentation/coredata/syncing-a-core-data-store-with-cloudkit>。

4. Apple 自己的 Core Data 样例把「模拟器上改、真机收推送」当作观察方向。样例 README 写：模拟器不能注册远程推送；真机上的修改不会自动出现在正在运行的模拟器上，要重新启动模拟器才会再拉一次。来源：<https://github.com/apple/sample-cloudkit-coredatasync/raw/refs/heads/main/README.md>。同组织的私有库同步样例同样写：模拟器收不到 `CKSubscription` 推送，观察同步必须有一台真机。来源：<https://github.com/apple/cloudkit-sample-privatedb-sync/blob/main/README.md>。

5. 从 Xcode 11.4 起，`xcrun simctl push` 可以把你自己写的 `.apns` 投进模拟器。这是应用可见通知的模拟，不是 CloudKit 服务器发出的 `CKDatabaseNotification`。没有找到 Apple 文档说用这条命令能驱动 `NSPersistentCloudKitContainer` 的导入。来源：<https://developer.apple.com/forums/thread/> 以外的说明见模拟器测试文章，例如 <https://www.donnywals.com/testing-push-notifications-in-the-simulator-with-xcode-11-4/>。2023 年有工程师写道，Xcode 14、macOS 13、Apple 芯片或 T2 上，模拟器可以拿到 APNs Sandbox 设备令牌。这是第三方观察，不是 Apple 对 Core Data 镜像的更新说明：<https://nilcoalescing.com/blog/TestingRemotePushOniOSSimulator/>。

6. SwiftData 的 CloudKit 同步使用同一套 `NSPersistentCloudKitContainer`。DTS 在 2025-10 和 2026-02 都这样说，并指向 TN3162、TN3163、TN3164。同步通常不是立即的。开发 schema 用 `initializeCloudKitSchema()`：它上传一组代表性记录再删掉，只应放在 DEBUG。Console 里核对每种实体和字段是否出现。来源：<https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices>，<https://developer.apple.com/documentation/coredata/nspersistentcloudkitcontainer/initializecloudkitschema(options:)>，<https://developer.apple.com/forums/thread/804577>，<https://developer.apple.com/forums/thread/798951>。月读已有 DEBUG 启动参数 `--initialize-cloudkit-development-schema`，见 `docs/dev/data/cloudkit-release-checklist.md`。

7. 导出和导入可以在日志里分开看。子系统 `com.apple.coredata`，消息里有 `Observed`、`Scheduling automated import`、`CKNotification`。TN3163 的示例通知写明 zone 是 `com.apple.coredata.cloudkit.zone`，订阅 ID 是 `com.apple.coredata.cloudkit.private.subscription`，数据库是 Private。来源：<https://developer.apple.com/documentation/technotes/tn3163-understanding-the-synchronization-of-nspersistentcloudkitcontainer>。WWDC22 session 10119 用两台已登录设备加系统日志讲同一过程：<https://developer.apple.com/videos/play/wwdc2022/10119/>。

### 沙盒测试账号

8. App Store Connect 的 Sandbox Apple Account 文档只把它定义为店面、购买和「通过 Apple 登录」的测试账号。邮箱不能已经是 Apple Account。来源：<https://developer.apple.com/help/app-store-connect/test-in-app-purchases/create-a-sandbox-apple-account>。

9. DTS 在 2026-02 写明：测 CloudKit 共享必须用真实 Apple ID；App Store Connect 里的 Sandbox Apple Account 不行。来源：<https://developer.apple.com/forums/thread/815455>。私有库、同一账号的两台设备，官方要的是 iCloud 账号并在设备和模拟器设置里登录（事实 2），不是 Sandbox 测试员。没有官方页面说 Sandbox 测试员可以打开 CloudKit 私有库。

10. 私有库只有该 iCloud 用户自己能看。CloudKit Console 用开发者账号登录后，要选 **Act As iCloud Account…** 才能看另一个 iCloud 账号的私有数据。来源：论坛对 Console 行为的说明 <https://developer.apple.com/forums/thread/94696>。这是开发者描述的 Console 步骤，不是 API 文档正文。

### cktool、Web Services、Console

11. Apple 把 cktool 和 CKTool JS 定为开发自动化：把沙盒 schema 重置成生产定义、套用 schema 文件、灌入测试数据、从 Xcode 或 CI 跑集成测试。cktool 从 Xcode 13 起随 Xcode 提供，用 `xcrun cktool`。来源：<https://developer.apple.com/icloud/cloudkit/automating/>，<https://developer.apple.com/icloud/ck-tool/>，WWDC21 session 10118 <https://developer.apple.com/videos/play/wwdc2021/10118/>。

12. 两种令牌：
   - **管理令牌**：团队和用户范围，默认一年，只做 schema 导入导出和重置，**不能读写库里的数据**。可在 Console 的 Settings 吊销。环境变量 `CLOUDKIT_MANAGEMENT_TOKEN`、`~/.config/cktool` 或登录钥匙串。
   - **用户令牌**：一次交互登录生成，**不能自动创建**。才能读写该用户的私有库、共享库和公共库。寿命短，无人值守时要反复登录。
   来源：同上 automating 页和 cktool 页；man 页摘要 <https://keith.github.io/xcode-man-pages/cktool.1.html>。

13. `query-records` 和 `create-record` 要 team id、container id、environment、database type、record type。不带过滤的查询要求 `___recordID` 有 Queryable 索引。`--zone-name` 默认是 `_defaultZone`，所以读 Core Data 镜像必须显式传 zone。来源：cktool 页。

14. Core Data 镜像的记录类型和字段由框架生成，不是普通 `CKRecord` 模型。文档说明：按继承查用 record type，查某个具体实体用 `CD_entityName`；可用 `record(for:)` 从托管对象拿到对应 `CKRecord`。短字符串在 `CD_` 字段里，大约超过 750KB 或整记录超过 1MB 时改走 `CKAsset`。`initializeCloudKitSchema` 上传的代表性记录会被删掉。来源：<https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data>，以及事实 6。WWDC19 笔记把 zone 和 `CD_entityName` 讲得更具体，但是笔记不是 Apple 正文：<https://wwdcnotes.com/documentation/wwdcnotes/wwdc19-202-using-core-data-with-cloudkit>。TN3163 日志里的 zone 名是一手材料（事实 7）。

15. CloudKit Web Services 用 `CKFetchWebAuthTokenOperation` 拿网页令牌，面向 CloudKit JS，不是第二台 iOS 设备。来源：<https://developer.apple.com/documentation/cloudkit/ckfetchwebauthtokenoperation>。没有文档说这个令牌可以触发 `NSPersistentCloudKitContainer` 导入。

### 分层和 CI

16. Apple 的 CI 故事停在 cktool：schema 用管理令牌，灌数据用用户令牌。用户令牌不能自动签发，所以**无人值守的 CI 做不了私有库读写**。管理令牌可以进 CI 的密钥库，不进仓库。来源：事实 11–12。

17. 公开材料里，稳定的自动化是不连网的 Core Data 栈：每个测试一个独立 SQLite，或测历史事务和合并策略。示例把 CloudKit 选项在测试里关掉，并写明内存库不会因为另一个 coordinator 的写入发出 `NSPersistentStoreRemoteChange`，因此测不了 iCloud 镜像。来源：<https://briancoyner.github.io/articles/2021-08-28-testing-core-data>，<https://stackoverflow.com/questions/72837329/how-to-set-up-2-core-data-stacks-that-use-the-same-in-memory-persistent-store>。没有找到把 `NSPersistentCloudKitContainer` 端到端放进 GitHub Actions、并稳定收推送的公开范例。

18. 月读自己的验证记录已经把边界写清：本地备份和删除测试不证明 CloudKit 删除传播；schema 部署不代表生产读写或跨设备通过；最近阅读的真实 CloudKit 到达要单独验收。来源：`docs/dev/engineering/verification-history.md`，`docs/dev/data/recent-reading-restoration.md`，`docs/dev/data/sync.md`。

## 推测

- 用 cktool 往 `com.apple.coredata.cloudkit.zone` 写一条手搓的 `CD_` 记录，不能当成「另一台设备」。框架拥有 record ID、关系和资产切分。文档只保证从托管对象读出记录，以及用代表性记录初始化 schema。没有文档保证外部写入会被导入器接住。读已有记录是支持的；伪造记录是赌注。
- `simctl push` 造一条看起来像 `CKDatabaseNotification` 的 payload，未必能让镜像委托去拉 zone。Apple 样例仍要求真机收推送、模拟器重新启动。在证明之前，不要把这条写进脚本当同步测试。
- 两台模拟器登录同一账号，在新系统上也许能靠 APNs Sandbox 互相同步。Apple 样例没有改口。把它当作可试现象，不当作 CI 前提。
- 论坛里有人把 Sandbox 测试员登进模拟器的 iCloud。和 DTS「共享必须用真实 Apple ID」放在一起，不能把 Sandbox 账号当成月读私有库的测试账号。

## 可试的做法

不改生产 schema，不把令牌或私人书库写进仓库或日志。

1. 逻辑测试保持断网：正文 SHA、LWW、来源隔离、删除边界。失败不叫同步失败。
2. 需要看「导出是否发生」时，在已登录开发 iCloud 的模拟器里改一条合成记录，然后用 cktool 查询，而不是写记录：

   `xcrun cktool query-records --team-id … --container-id … --environment development --database-type private --zone-name com.apple.coredata.cloudkit.zone --record-type CD_…`

   zone 和类型以 Console 里实际出现的为准。查到记录只证明导出，不证明另一台已经导入。
3. 导入用第二台已经登录同一 iCloud 的真机，或关掉再打开模拟器。用 Console 的 Act As iCloud Account 看私有区，用 TN3163 的日志区分导出和导入。
4. CI 至多跑管理令牌能做的 schema 差分或 `reset-schema`。那会把开发库打回生产定义，会清掉开发 schema 上尚未部署的字段，不能对着月读正在用的开发容器随手执行。私有数据不进 CI。

## 需要一次准备的东西

- 一个专用 iCloud 账号，不要用日常书库的 Apple ID。在一台模拟器和一台真机的设置里登录，打开 iCloud。这是普通 Apple ID，不是 App Store Sandbox 测试员。
- 开发者账号能打开该容器的 CloudKit Console，并对这个专用账号使用 Act As iCloud Account。
- 本机 Xcode 的 `xcrun cktool save-token --type management`，以及交互式 `save-token --type user`。令牌只留在钥匙串。用户令牌过期就重新登录，不要放进 CI。
- 团队 ID 和月读开发容器 ID。调试构建确认 entitlement 是 Development。
- 已有的 DEBUG schema 初始化只在需要新字段时跑，跑完到 Console 核对 `CD_` 类型。它不代替跨设备导入。
