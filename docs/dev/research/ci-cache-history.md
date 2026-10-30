# CI 缓存调查的历史证据

整理日期：2026-10-30；调查日期：2026-10-27。依据 PR #131 的三次既有日志与 `283196f` 工作流。这里保存可复用的判断与测量口径，不描述当前 CI 配置，也不构成缓存改造授权；现行配置见[仓库与持续集成](../engineering/repository.md)。本次整理没有重跑 CI 或重新在线核对工具链文档。

## 实测与不能推断的事

| 记录 | 编译步骤 | 步骤开始至 Xcode 首条日志 | Swift 单文件编译记录 |
| --- | ---: | ---: | ---: |
| [40334128311](https://github.com/suxiaoshao/moonread/actions/runs/40334128311) | 237 秒 | 约 68 秒 | 254 |
| [40356322558](https://github.com/suxiaoshao/moonread/actions/runs/40356322558) / `88090ca` | 1075 秒 | 约 545 秒 | 254 |
| [40359596438](https://github.com/suxiaoshao/moonread/actions/runs/40359596438) / `b12ca04` | 1071 秒 | 约 582 秒 | 241 |

只计 `SwiftCompile normal arm64 /…swift`，不重复统计 batch 标题和 JobDiscovery；共享源在不同 target 中分别计数，254 不是独立文件数。最慢两轮没有多编大量 Swift。Xcode 首条日志前的时间窗口包含 Nix 等准备工作，不能把整个窗口归为纯 Nix；Xcode 的包图、工具探测及 build description 也要单独计时。

三轮 Rust target cache 都精确命中，但 Cargo 是否重新编译并不相同；DerivedData 精确或 prefix 命中也不等于自有 Swift 输入能跳过编译。基线 test 345 秒、第三轮 144 秒，同时存在用例耗时差异，因此不能据此证明后台 boot 净节省了 201 秒，或没有 CPU 争用。

原始日志保留在本机 `build/Research/ci-performance/ci-cache-evidence/`；它们是上述历史测量依据，不随源码提交。GitHub 日志可能过期，run 链接不保证永久保存附件。

## 可复用的判断

- 分开测量 Nix 环境、Xcode 准备、Swift/Rust 编译、模拟器启动和测试；不要只比较 job 总时长或 Actions cache 的 hit 标签。
- 不用每个文件最后一次 Git 提交时间伪造上次构建的 mtime。Cargo 与 Swift/Xcode 的新鲜度规则不同，源文件被回拨到旧产物之前有漏编风险。历史 [P1 评论](https://github.com/suxiaoshao/moonread/pull/131#discussion_r4379581394) 指出的是风险，不证明该轮已经执行错误 Rust 代码。
- 当时 Rust/UniFFI phase 每次运行，生成文件位于 DerivedData 外；UniFFI 0.32.2 会直接写生成文件。可研究内容不变时避免替换，但不能直接关闭 `alwaysOutOfDate` 而没有完整输入依赖。生成物删除也须处理。
- 若评估 Nix 缓存，应连同 store 注册与 flake 输入获取成本考虑，不能只打包 `/nix/store`。若评估 Xcode 内容编译缓存，应核实实际工具链、CAS 路径和 hit/miss，不假定 `-derivedDataPath` 已覆盖 CAS。
- 冷缓存、命中缓存、改变 Swift 输入、改变 Rust 输入须分别观察；继续正常构建校验，成功后才运行 `test-without-building`。预计收益不是测得收益，恢复/压缩/上传成本计入总耗时。

历史参考：[UniFFI 0.32.2 生成器](https://github.com/mozilla/uniffi-rs/blob/v0.32.2/uniffi_bindgen/src/bindings/swift/mod.rs#L96)、[Apple 构建过程](https://developer.apple.com/videos/play/wwdc2018/415/)、[Cargo fingerprint](https://doc.rust-lang.org/stable/nightly-rustc/cargo/compiler/fingerprint/index.html)、[Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)。其中滚动文档和主干实现需在未来实施时重新核实，不把新特性当作历史 CI 已启用。
