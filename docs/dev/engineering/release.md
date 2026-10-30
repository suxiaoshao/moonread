# 发布与 TestFlight

此页维护发布操作顺序，不代表某次构建、审核、地区开放或生产同步已完成。分支规则见[开发协作](development.md#分支与协作)，历史证据见[验证记录](verification.md)。1.2 已发布是文档整理的产品基线，地区供应与审核状态另以当次 ASC 核对为准。

## 构建来源与递增

- `main` 对应线上版本；发布后才打 `v*` tag，因此不能用发布 tag 触发候选 TestFlight 构建。
- 从 **main 的 `.github/workflows/testflight.yml`** 手动 `workflow_dispatch`，指定 `source_branch`（release/x.y 或 hotfix 分支）、`expected_sha` 完整 SHA 和 `mode`。版本分支没有该 workflow 不等于未配置 CI。
- 版本号/构建号先经 PR 修改工程并合入目标分支，使用那个完整 SHA；不由 CI 临时改号或自动回写。新上传的构建号不能复用已上传号。
- 默认 `verify`：归档、导出和核验，不上传。CI verify 会记录构建号冲突但不因此阻止核验；upload 才强制递增门槛，verify 不是 ASC 上传唯一性保证。检查通过后，用户明确授权才运行 `upload`，仍固定同一分支/SHA；源分支变化时重新确认目标。
- Rust 由仓库 Nix 环境编译，Xcode 构建继续调用该环境；不另安装 Rust、复制独立构建脚本或绕过锁定工具链。

## 自动签名与凭据

当前 main workflow 使用 App Store Connect API Key 自动签名：`xcodebuild -allowProvisioningUpdates` 配合 `-authenticationKeyPath`、`-authenticationKeyID`、`-authenticationKeyIssuerID`。GitHub `testflight` Environment 中的 Secrets 为 `ASC_API_KEY_BASE64`、`ASC_KEY_ID`、`ASC_ISSUER_ID`，变量 `APPLE_TEAM_ID`。权限和临时文件清理以 workflow 为准。

用户本人创建具有所需权限的 API Key、下载私钥并填写 Secrets；代理只核对名称和运行结果，不读取、打印、复制或记录私钥、密码、token 或个人签名配置。不把旧手动签名七项方案当作当前必填项。账号登录、验证、协议、银行与税务由用户本人完成。

## 归档与导出核验

本机补充构建沿用下方[归档命令](#本机归档与导出)和开发环境的 Nix 接线，归档产物放 build。CI 和本机都检查最终分发产物，而不只检查工程设置：

- 主 App、分享扩展和嵌套组件签名有效，Bundle ID、版本/构建号、Team 和 provision 匹配；分发包 `get-task-allow=false`。
- 推送、iCloud Documents、CloudKit 使用预期生产授权与容器；不接受无云开发备用配置冒充分发构建。
- App 及实际链接 SDK 的隐私清单已随包打入；required-reason API 用途与实际调用一致。清单、公开政策与 ASC 隐私标签分别核对，不能以 plist 合法代替用途准确。
- 无 DEBUG/UI 测试开关、测试夹具、`.storekit` 或凭据；Release 条件编译审计与产物检查一起完成。
- 检查 IPA/归档导出、架构和日志；workflow 的失败分类区分构建/签名/核验与上传服务失败，不把失败当成上传成功。

源工程决定本次应有的扩展集合：旧版本只有 Share，新版本为 Share 与 Widget；缺少或出现未知扩展均拒绝。逐一核对 App、Share、Widget 的版本、签名、profile、App Group、arm64、隐私清单及 Release 测试入口；三个 bundle 的 `CFBundleDisplayName` 必须是非空字符串。不能只检查主 App，或认为 archive/export 成功就已满足上传要求。

### 上传失败的诊断

先读失败阶段、退出码及脱敏 Apple/NSError 描述，再决定修复还是重试。`exit 70` 本身不能区分网络偶发与包元数据错误。1.3 的一次本机上传明确被 Apple 以 Widget 缺少 `CFBundleDisplayName` 拒绝；补齐基础名称并复用既有三语 `InfoPlist.xcstrings` 后，再走固定提交的 verify/upload。此前 CI 私有日志已清理的失败不能据此倒推为同一根因。

工作流清理私有材料前，从本阶段明确引用的 `.xcdistributionlogs` 提取有界脱敏摘要；不公开原始分发日志、凭据或 profile。查看 `truncated`、`readFailures`、`collector-failed` 等标记，区分“没有错误”和“没有完整采集到”。未知格式补充摘要规则，不以公开原日志兜底。实现及审查依据：[诊断修复 #158](https://github.com/suxiaoshao/moonread/pull/158)、[Widget 修复 #159](https://github.com/suxiaoshao/moonread/pull/159)。

CloudKit 模型变更使用[生产 schema 核对](../data/cloudkit-release-checklist.md)，只增不删。签名、schema 部署、上传成功和跨设备交付是四种不同证据。

## TestFlight 与 App Store

1. verify 通过后经授权上传；记录 run、完整 SHA、版本/构建号及结果。上传成功后等待 ASC Processing，确认出口合规及内部群组可测试状态，不凭 CI 日志认定测试员已收到。
2. 商店版本填三语新增内容；截图使用合成或自有样例，按[商店截图流程](development.md#商店截图独立-debug-测试)核对尺寸、语言和顺序。每次明确构建、发布方式和地区；保存不等于提交。
3. 出口合规、内容版权等答案只能在事实未变且已有明确答案时沿用；拿不准先报告。审核、发布、撤回和销售范围变动需要对应授权。
4. 地区开放与版本上线分开。中国大陆店面禁用 AI 已实现，但不推断备案豁免或国区可供应；ICP 阻塞时保留原文并报告，不自行改地区、填写号码或提交申诉。
5. 公开隐私/支持文案以 `docs/site/content/privacy*.md`、`support*.md` 为正本，不在发布文档保留首发草稿。隐私政策披露主动 AI 发送，不能把 Apple 云同步与 IAP 描述成完全离线。
6. 打赏为[四个消耗型项目](../design/tip-jar.md)，不解锁功能。用户核对商品 ID、本地化、价格、地区、可售状态和协议；新增商品的审核/沙盒联调单独确认，不假定旧配置永久有效。

发布后由负责人核对实际上线版本，再按分支规则更新 main/tag。GitHub CI、PR 合并或本机安装不替代 App Store 上线证据。

## 本机归档与导出

使用干净提交和本机 `LocalSigning.xcconfig`，在 Nix 环境执行 Release archive，真机缓存统一为 `build/DeviceDerivedData`。自动签名的原始归档通常使用开发签名，导出时由 Xcode 重签为 App Store Connect 分发包，这是正常流程；不要给自动开发签名的归档强行指定 Apple Distribution 身份。

```sh
nix develop --no-update-lock-file -c xcodebuild \
  -project ios/Moonread.xcodeproj -scheme Moonread -configuration Release \
  -xcconfig ios/LocalSigning.xcconfig -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData \
  -archivePath build/TestFlight/Moonread.xcarchive -allowProvisioningUpdates archive
```

先用 `xcodebuild -exportArchive` 本地导出并核对分发包。ExportOptions 使用 `method=app-store-connect`、`signingStyle=automatic`、`iCloudContainerEnvironment=Production`、`manageAppVersionAndBuildNumber=false`；预检用 `destination=export`，上传时改为 `destination=upload`，两次均允许自动签名更新，并使用同一归档。每次新上传先按构建号规则递增；遇账号登录或钥匙串授权，由用户本人处理。

## 商店资料的核对口径

2026-10-17 的产品页调查曾发现 App Store 展示的新年龄档与 Lookup 返回的旧档不同；`languageCodesISO2A` 的 `ZH` 也不能区分简繁。这里只保留数据源差异的经验，不维护会过期的竞品分级/语言数量榜。每次提交按 ASC 当前问卷、实际功能和明确语言资源核对，不从竞品标签推导月读分级，不因有 AI 就自行改年龄档。
