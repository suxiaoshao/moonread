# CloudKit 发布核对

月读 1.7 使用容器 `iCloud.dev.moonread.Moonread` 私有库中的自定义区 `MoonreadReadingV2`。阅读数据由 CKSyncEngine 传输。1.6 的 SwiftData 镜像和已发布的 `CD_` 类型保留给旧客户端。小说原件与目录树使用 iCloud Documents。

1. 核对分发包的 App ID、容器、CloudKit、CloudDocuments、推送与 remote-notification 授权，并确认签名使用 Production 环境。
2. 对照 `CloudTransportRows.supportedTypes` 的阅读事实、固定值与因果记录，以及 `ReadingCloudInitialization.recordType` 初始化记录，在 Console 分别核对 Development 和 Production 的实际类型、字段、封面资产及所需索引。AI 会话留在本机。
3. 查看待部署差异。开发环境写入与生产部署按当轮授权执行，生产 schema 只增不删。用户审阅后执行 Deploy Schema Changes。
4. 部署后用正式分发包或 TestFlight 验证生产写入、读回、修改、删除及封面附件，再由同账户第二台设备核对传播。分开记录结构部署和实际数据交付的证据。

[同步设计](sync.md) · [验证记录](../engineering/verification.md) · [Apple 容器 schema 部署说明](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)
