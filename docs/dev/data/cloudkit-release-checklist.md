# CloudKit 发布核对

本轮只准备本地模型与 DEBUG 辅助入口，未写开发云 schema、未查看私人记录、未部署生产。

- 容器：`iCloud.dev.moonread.Moonread`；阅读数据只用私有库。小说文件是 iCloud Documents，不随 schema 部署迁移。
- 唯一模型来源为 `UserDataStore.modelTypes`：UserPosition、UserValue、AnnotationOperation、ReadingFact、StatisticsClear、UserCover。AI 会话和 Rust 正文缓存排除。UserCover.bytes 为 external storage。
- DEBUG `--cloud-schema-report` 只打印同一 SwiftData 类型生成的 Core Data 实体／字段／类型／optional／external 标记，不连接云。生成实体名不代替 Console 实际记录名或系统字段。
- 获得明确开发环境写入授权后，才使用 DEBUG `--initialize-cloudkit-development-schema`。它按 Apple 流程生成同一模型，独占 DEBUG 启动页，不启动普通 App 的持久栈／刷新任务；在全新的临时隔离 store 中同步加载 NSPersistentCloudKitContainer、初始化开发 schema、卸载 store 后释放；不打开用户 store，也不自动部署 production。结束后移除启动参数重新进入正常 App；Release 不编译此入口。

发布负责人逐项核对：

1. 签名 App ID 的 iCloud 容器、CloudKit／CloudDocuments、推送与 remote-notification 授权；正式分发包使用 Production 环境，调试初始化仅 Development。
2. Console 分别只读核对 Development／Production 六类实际生成记录、系统元数据字段、查询／排序索引、封面 asset 与私有库权限。不导出用户记录值。不手工猜测记录名称。
3. 若开发 schema 不完整，先授权隔离初始化；查看待部署差异，排除无关历史类型。不得 Reset Environment 清理私人数据。
4. 用户本人审阅并执行 Deploy Schema Changes。生产 schema 合并类型、字段、索引而不复制记录，生产类型／字段不能按开发重置方式删除或随意改类型；回滚二进制不会回滚 schema。
5. 部署后以正式分发／TestFlight 验证生产写入、读回、修改／删除、封面资源和跨设备传播。没有第二个同账户环境时保留缺口。此次模拟器本地模型测试不代表生产同步通过。

官方依据：[SwiftData 与 CloudKit 同步及初始化流程](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)、[部署容器 schema](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)。不记录账号、凭据或私人内容。
