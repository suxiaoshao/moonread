# 第三方声明

Moonread 自有代码与原创样本采用根目录的 [MIT 许可](LICENSE)。下列第三方代码、字体、品牌素材和开发资料保留各自许可；根许可不覆盖其权利。品牌标志仅用于识别服务商，不表示授权背书或转移商标权。

完整许可、版权、NOTICE 和字体内嵌声明集中在 [ThirdPartyNotices.txt](ios/Moonread/Resources/ThirdPartyNotices.txt)，该文件同时作为 App target 资源分发，可在“设置 → 关于月读 → 第三方许可”中滚动查看与选择文字。页面开头提供 MPL 组件具体版本的可点击源码链接。重复文本按 SHA-256 前缀共用一份，索引逐项保留来源。更新依赖时须同步核对锁文件、版权和许可文本。

## Swift 包

版本依据 `Package.resolved`。表中包含直接及传递依赖。隐私清单 fork 的改动仅添加 PrivacyInfo.xcprivacy 及其 Package.swift 资源声明，不改变上游许可。

| 包 | 版本 / revision | 许可 | 源码 |
| --- | --- | --- | --- |
| displaylink | 3.0.1 / `41bea2661e04bebcb1c4f15fc0b6197850100fdd` | MIT | [锁定源码](https://github.com/Lakr233/DisplayLink/tree/41bea2661e04bebcb1c4f15fc0b6197850100fdd) |
| litext | revision / `c1d74fe65557534e01301a58a8617fddc0e88992` | MIT | [锁定源码](https://github.com/suxiaoshao/Litext/tree/c1d74fe65557534e01301a58a8617fddc0e88992) |
| lrucache | 1.3.0 / `f0570e943ea4445d258113ba73f50cb2b7e564ac` | MIT | [锁定源码](https://github.com/nicklockwood/LRUCache/tree/f0570e943ea4445d258113ba73f50cb2b7e564ac) |
| markdownview | 4.8.3 / `00bcbc12a58601b407f379deb06791fe02fa1e31` | MIT | [锁定源码](https://github.com/Lakr233/MarkdownView/tree/00bcbc12a58601b407f379deb06791fe02fa1e31) |
| swift-ai-sdk | revision / `9843cba7de6c2a0f1a042a4f3b1facc8af910a82` | Apache-2.0 | [锁定源码](https://github.com/suxiaoshao/swift-ai-sdk/tree/9843cba7de6c2a0f1a042a4f3b1facc8af910a82) |
| swift-argument-parser | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Apache-2.0 WITH Swift-exception | [锁定源码](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382) |
| swift-cmark | 0.9.0 / `08ddb528923cc1a6527e02b7a1aee9e516ca749a` | BSD / MIT（完整 COPYING） | [锁定源码](https://github.com/swiftlang/swift-cmark/tree/08ddb528923cc1a6527e02b7a1aee9e516ca749a) |
| swift-collections | 1.7.2 / `3b69cedbaa49957e97c092ae400bb57602ef941f` | Apache-2.0 WITH Swift-exception | [锁定源码](https://github.com/apple/swift-collections/tree/3b69cedbaa49957e97c092ae400bb57602ef941f) |
| swiftmath | 1.7.3 / `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7` | MIT；字体另列 | [锁定源码](https://github.com/mgriebling/SwiftMath/tree/fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7) |

## SwiftMath 字体

以下为 SwiftMath 1.7.3 原样分发的字体；映射以锁定 OTF 的 name 表版权、许可及许可 URL 为依据，完整字段与包内 GUST/OFL 许可均保存在随附声明。字体未改名、未修改，保留 Reserved Font Name。GUST 字体附 LPPL 1.3c 原文；不将 SwiftMath 的 MIT 扩展到字体。

| 字体文件 | 许可 |
| --- | --- |
| Asana-Math.otf | SIL OFL-1.1 |
| Euler-Math.otf | SIL OFL-1.1 |
| FiraMath-Regular.otf | SIL OFL-1.1 |
| Garamond-Math.otf | SIL OFL-1.1 |
| KpMath-Light.otf | SIL OFL-1.1 |
| KpMath-Sans.otf | SIL OFL-1.1 |
| LeteSansMath.otf | SIL OFL-1.1 |
| LibertinusMath-Regular.otf | SIL OFL-1.1 |
| NotoSansMath-Regular.otf | SIL OFL-1.1 |
| latinmodern-math.otf | GUST Font License / LPPL-1.3c-or-later |
| texgyretermes-math.otf | GUST Font License / LPPL-1.3c-or-later |
| xits-math.otf | SIL OFL-1.1 |

## Rust crates

下表完整列出 Cargo.lock 的 registry 包，包含工具、构建、测试及非 iOS 目标，不表示全部进入 iOS 二进制。iOS 使用系统 SQLite；其他目标启用 rusqlite bundled SQLite（SQLite 为 public domain）。双许可包可按列出的 MIT 或 Apache 许可使用；r-efi 选择 MIT，不要求使用 LGPL。

MPL-2.0 部分保持原许可，包括 cssparser、cssparser-macros、dtoa-short、selectors 和 UniFFI 各包；没有修改这些包的上游文件。接收者可通过下表每个精确版本的 crates.io 源码包取得对应源代码（下载地址为 `https://crates.io/api/v1/crates/<name>/<version>/download`），也可用本仓库 Cargo.lock 执行 `cargo vendor --locked` 取得同版本源码与校验信息。更大作品的 MIT 不覆盖 MPL 文件；以后修改这些文件时须提供对应修改源码。

| 包 | 版本 | 声明许可 | 对应源码 |
| --- | --- | --- | --- |
| aho-corasick | 1.1.5 | Unlicense OR MIT | [源码包](https://crates.io/crates/aho-corasick/1.1.5) |
| anstyle | 1.0.14 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/anstyle/1.0.14) |
| anyhow | 1.0.104 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/anyhow/1.0.104) |
| askama | 0.16.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/askama/0.16.1) |
| askama_derive | 0.16.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/askama_derive/0.16.1) |
| askama_macros | 0.16.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/askama_macros/0.16.1) |
| askama_parser | 0.16.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/askama_parser/0.16.1) |
| autocfg | 1.5.1 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/autocfg/1.5.1) |
| basic-toml | 0.1.10 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/basic-toml/0.1.10) |
| bitflags | 2.13.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/bitflags/2.13.2) |
| block-buffer | 0.12.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/block-buffer/0.12.1) |
| bumpalo | 3.20.3 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/bumpalo/3.20.3) |
| bytes | 1.12.1 | MIT | [源码包](https://crates.io/crates/bytes/1.12.1) |
| camino | 1.2.6 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/camino/1.2.6) |
| cargo-platform | 0.3.3 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/cargo-platform/0.3.3) |
| cargo_metadata | 0.23.1 | MIT | [源码包](https://crates.io/crates/cargo_metadata/0.23.1) |
| cc | 1.8.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/cc/1.8.0) |
| cfg-if | 1.0.5 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/cfg-if/1.0.5) |
| clap | 4.6.7 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/clap/4.6.7) |
| clap_builder | 4.6.7 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/clap_builder/4.6.7) |
| clap_derive | 4.6.7 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/clap_derive/4.6.7) |
| clap_lex | 1.1.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/clap_lex/1.1.1) |
| const-oid | 0.10.2 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/const-oid/0.10.2) |
| core_detect | 1.0.0 | MIT/Apache-2.0 | [源码包](https://crates.io/crates/core_detect/1.0.0) |
| cpufeatures | 0.3.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/cpufeatures/0.3.1) |
| crypto-common | 0.2.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/crypto-common/0.2.2) |
| cssparser | 0.37.0 | MPL-2.0 | [源码包](https://crates.io/crates/cssparser/0.37.0) |
| cssparser-macros | 0.7.1 | MPL-2.0 | [源码包](https://crates.io/crates/cssparser-macros/0.7.1) |
| derive_more | 2.1.1 | MIT | [源码包](https://crates.io/crates/derive_more/2.1.1) |
| derive_more-impl | 2.1.1 | MIT | [源码包](https://crates.io/crates/derive_more-impl/2.1.1) |
| digest | 0.11.3 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/digest/0.11.3) |
| displaydoc | 0.2.7 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/displaydoc/0.2.7) |
| dtoa | 1.0.11 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/dtoa/1.0.11) |
| dtoa-short | 0.3.5 | MPL-2.0 | [源码包](https://crates.io/crates/dtoa-short/0.3.5) |
| ego-tree | 0.11.0 | ISC | [源码包](https://crates.io/crates/ego-tree/0.11.0) |
| encoding_rs | 0.8.42 | (Apache-2.0 OR MIT) AND BSD-3-Clause | [源码包](https://crates.io/crates/encoding_rs/0.8.42) |
| equivalent | 1.0.2 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/equivalent/1.0.2) |
| errno | 0.3.14 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/errno/0.3.14) |
| fallible-iterator | 0.3.0 | MIT/Apache-2.0 | [源码包](https://crates.io/crates/fallible-iterator/0.3.0) |
| fallible-streaming-iterator | 0.1.9 | MIT/Apache-2.0 | [源码包](https://crates.io/crates/fallible-streaming-iterator/0.1.9) |
| fastrand | 2.5.0 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/fastrand/2.5.0) |
| find-msvc-tools | 0.1.14 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/find-msvc-tools/0.1.14) |
| foldhash | 0.2.0 | Zlib | [源码包](https://crates.io/crates/foldhash/0.2.0) |
| form_urlencoded | 1.2.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/form_urlencoded/1.2.2) |
| fs-err | 3.3.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/fs-err/3.3.2) |
| futures-core | 0.3.34 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/futures-core/0.3.34) |
| futures-task | 0.3.34 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/futures-task/0.3.34) |
| futures-util | 0.3.34 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/futures-util/0.3.34) |
| getrandom | 0.4.3 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/getrandom/0.4.3) |
| glob | 0.3.4 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/glob/0.3.4) |
| goblin | 0.8.2 | MIT | [源码包](https://crates.io/crates/goblin/0.8.2) |
| hashbrown | 0.16.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/hashbrown/0.16.1) |
| hashbrown | 0.17.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/hashbrown/0.17.1) |
| hashlink | 0.12.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/hashlink/0.12.2) |
| heck | 0.5.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/heck/0.5.0) |
| html5ever | 0.39.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/html5ever/0.39.0) |
| hybrid-array | 0.4.15 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/hybrid-array/0.4.15) |
| icu_collections | 2.3.0 | Unicode-3.0 | [源码包](https://crates.io/crates/icu_collections/2.3.0) |
| icu_locale_core | 2.3.0 | Unicode-3.0 | [源码包](https://crates.io/crates/icu_locale_core/2.3.0) |
| icu_normalizer | 2.3.0 | Unicode-3.0 | [源码包](https://crates.io/crates/icu_normalizer/2.3.0) |
| icu_normalizer_data | 2.3.0 | Unicode-3.0 | [源码包](https://crates.io/crates/icu_normalizer_data/2.3.0) |
| icu_properties | 2.3.0 | Unicode-3.0 | [源码包](https://crates.io/crates/icu_properties/2.3.0) |
| icu_properties_data | 2.3.0 | Unicode-3.0 | [源码包](https://crates.io/crates/icu_properties_data/2.3.0) |
| icu_provider | 2.3.1 | Unicode-3.0 | [源码包](https://crates.io/crates/icu_provider/2.3.1) |
| idna | 1.1.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/idna/1.1.0) |
| idna_adapter | 1.2.2 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/idna_adapter/1.2.2) |
| indexmap | 2.14.2 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/indexmap/2.14.2) |
| itoa | 1.0.18 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/itoa/1.0.18) |
| js-sys | 0.3.106 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/js-sys/0.3.106) |
| libc | 0.2.190 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/libc/0.2.190) |
| libsqlite3-sys | 0.38.2 | MIT | [源码包](https://crates.io/crates/libsqlite3-sys/0.38.2) |
| linux-raw-sys | 0.12.1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | [源码包](https://crates.io/crates/linux-raw-sys/0.12.1) |
| litemap | 0.8.3 | Unicode-3.0 | [源码包](https://crates.io/crates/litemap/0.8.3) |
| lock_api | 0.4.14 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/lock_api/0.4.14) |
| log | 0.4.34 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/log/0.4.34) |
| markup5ever | 0.39.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/markup5ever/0.39.0) |
| memchr | 2.8.3 | Unlicense OR MIT | [源码包](https://crates.io/crates/memchr/2.8.3) |
| minimal-lexical | 0.2.1 | MIT/Apache-2.0 | [源码包](https://crates.io/crates/minimal-lexical/0.2.1) |
| multiversion_no_op | 1.0.0 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/multiversion_no_op/1.0.0) |
| new_debug_unreachable | 1.0.6 | MIT | [源码包](https://crates.io/crates/new_debug_unreachable/1.0.6) |
| nom | 7.1.3 | MIT | [源码包](https://crates.io/crates/nom/7.1.3) |
| once_cell | 1.21.4 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/once_cell/1.21.4) |
| parking_lot | 0.12.5 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/parking_lot/0.12.5) |
| parking_lot_core | 0.9.12 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/parking_lot_core/0.9.12) |
| percent-encoding | 2.3.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/percent-encoding/2.3.2) |
| phf | 0.13.1 | MIT | [源码包](https://crates.io/crates/phf/0.13.1) |
| phf_codegen | 0.13.1 | MIT | [源码包](https://crates.io/crates/phf_codegen/0.13.1) |
| phf_generator | 0.13.1 | MIT | [源码包](https://crates.io/crates/phf_generator/0.13.1) |
| phf_macros | 0.13.1 | MIT | [源码包](https://crates.io/crates/phf_macros/0.13.1) |
| phf_shared | 0.13.1 | MIT | [源码包](https://crates.io/crates/phf_shared/0.13.1) |
| pin-project-lite | 0.2.17 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/pin-project-lite/0.2.17) |
| pkg-config | 0.3.34 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/pkg-config/0.3.34) |
| plain | 0.2.3 | MIT/Apache-2.0 | [源码包](https://crates.io/crates/plain/0.2.3) |
| potential_utf | 0.1.6 | Unicode-3.0 | [源码包](https://crates.io/crates/potential_utf/0.1.6) |
| precomputed-hash | 0.1.1 | MIT | [源码包](https://crates.io/crates/precomputed-hash/0.1.1) |
| proc-macro2 | 1.0.107 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/proc-macro2/1.0.107) |
| quote | 1.0.47 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/quote/1.0.47) |
| r-efi | 6.0.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later | [源码包](https://crates.io/crates/r-efi/6.0.0) |
| redox_syscall | 0.5.18 | MIT | [源码包](https://crates.io/crates/redox_syscall/0.5.18) |
| regex | 1.13.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/regex/1.13.1) |
| regex-automata | 0.4.18 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/regex-automata/0.4.18) |
| regex-syntax | 0.8.11 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/regex-syntax/0.8.11) |
| rsqlite-vfs | 0.1.1 | MIT | [源码包](https://crates.io/crates/rsqlite-vfs/0.1.1) |
| rusqlite | 0.40.2 | MIT | [源码包](https://crates.io/crates/rusqlite/0.40.2) |
| rustc-hash | 2.1.3 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/rustc-hash/2.1.3) |
| rustc_version | 0.4.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/rustc_version/0.4.1) |
| rustix | 1.1.5 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | [源码包](https://crates.io/crates/rustix/1.1.5) |
| rustversion | 1.0.23 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/rustversion/1.0.23) |
| scopeguard | 1.2.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/scopeguard/1.2.0) |
| scraper | 0.27.0 | ISC | [源码包](https://crates.io/crates/scraper/0.27.0) |
| scroll | 0.12.0 | MIT | [源码包](https://crates.io/crates/scroll/0.12.0) |
| scroll_derive | 0.12.1 | MIT | [源码包](https://crates.io/crates/scroll_derive/0.12.1) |
| selectors | 0.38.0 | MPL-2.0 | [源码包](https://crates.io/crates/selectors/0.38.0) |
| semver | 1.0.28 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/semver/1.0.28) |
| serde | 1.0.229 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/serde/1.0.229) |
| serde_core | 1.0.229 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/serde_core/1.0.229) |
| serde_derive | 1.0.229 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/serde_derive/1.0.229) |
| serde_json | 1.0.154 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/serde_json/1.0.154) |
| serde_spanned | 1.1.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/serde_spanned/1.1.2) |
| servo_arc | 0.4.3 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/servo_arc/0.4.3) |
| sha2 | 0.11.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/sha2/0.11.0) |
| shlex | 2.0.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/shlex/2.0.1) |
| simdutf8 | 0.1.5 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/simdutf8/0.1.5) |
| siphasher | 1.0.4 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/siphasher/1.0.4) |
| slab | 0.4.12 | MIT | [源码包](https://crates.io/crates/slab/0.4.12) |
| smallvec | 1.16.3 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/smallvec/1.16.3) |
| smawk | 0.3.3 | MIT | [源码包](https://crates.io/crates/smawk/0.3.3) |
| sqlite-wasm-rs | 0.5.5 | MIT | [源码包](https://crates.io/crates/sqlite-wasm-rs/0.5.5) |
| stable_deref_trait | 1.2.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/stable_deref_trait/1.2.1) |
| static_assertions | 1.1.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/static_assertions/1.1.0) |
| string_cache | 0.9.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/string_cache/0.9.0) |
| string_cache_codegen | 0.6.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/string_cache_codegen/0.6.1) |
| strsim | 0.11.1 | MIT | [源码包](https://crates.io/crates/strsim/0.11.1) |
| syn | 2.0.119 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/syn/2.0.119) |
| syn | 3.0.8 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/syn/3.0.8) |
| synstructure | 0.14.0 | MIT | [源码包](https://crates.io/crates/synstructure/0.14.0) |
| tempfile | 3.27.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/tempfile/3.27.0) |
| tendril | 0.5.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/tendril/0.5.1) |
| textwrap | 0.16.4 | MIT | [源码包](https://crates.io/crates/textwrap/0.16.4) |
| thiserror | 2.0.21 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/thiserror/2.0.21) |
| thiserror-impl | 2.0.21 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/thiserror-impl/2.0.21) |
| tinystr | 0.8.4 | Unicode-3.0 | [源码包](https://crates.io/crates/tinystr/0.8.4) |
| toml | 1.1.8+spec-1.1.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/toml/1.1.8+spec-1.1.0) |
| toml_datetime | 1.1.2+spec-1.1.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/toml_datetime/1.1.2+spec-1.1.0) |
| toml_parser | 1.1.5+spec-1.1.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/toml_parser/1.1.5+spec-1.1.0) |
| toml_writer | 1.1.3+spec-1.1.0 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/toml_writer/1.1.3+spec-1.1.0) |
| typenum | 1.20.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/typenum/1.20.1) |
| unicode-ident | 1.0.27 | (MIT OR Apache-2.0) AND Unicode-3.0 | [源码包](https://crates.io/crates/unicode-ident/1.0.27) |
| unicode-segmentation | 1.13.3 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/unicode-segmentation/1.13.3) |
| unicode-width | 0.2.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/unicode-width/0.2.2) |
| uniffi | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi/0.32.2) |
| uniffi_bindgen | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi_bindgen/0.32.2) |
| uniffi_core | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi_core/0.32.2) |
| uniffi_internal_macros | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi_internal_macros/0.32.2) |
| uniffi_macros | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi_macros/0.32.2) |
| uniffi_meta | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi_meta/0.32.2) |
| uniffi_pipeline | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi_pipeline/0.32.2) |
| uniffi_udl | 0.32.2 | MPL-2.0 | [源码包](https://crates.io/crates/uniffi_udl/0.32.2) |
| url | 2.5.8 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/url/2.5.8) |
| utf8_iter | 1.0.4 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/utf8_iter/1.0.4) |
| uuid | 1.28.0 | Apache-2.0 OR MIT | [源码包](https://crates.io/crates/uuid/1.28.0) |
| vcpkg | 0.2.15 | MIT/Apache-2.0 | [源码包](https://crates.io/crates/vcpkg/0.2.15) |
| wasm-bindgen | 0.2.129 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/wasm-bindgen/0.2.129) |
| wasm-bindgen-macro | 0.2.129 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/wasm-bindgen-macro/0.2.129) |
| wasm-bindgen-macro-support | 0.2.129 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/wasm-bindgen-macro-support/0.2.129) |
| wasm-bindgen-shared | 0.2.129 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/wasm-bindgen-shared/0.2.129) |
| web_atoms | 0.2.6 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/web_atoms/0.2.6) |
| weedle2 | 5.0.0 | MIT | [源码包](https://crates.io/crates/weedle2/5.0.0) |
| windows-link | 0.2.1 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/windows-link/0.2.1) |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 | [源码包](https://crates.io/crates/windows-sys/0.61.2) |
| winnow | 1.0.4 | MIT | [源码包](https://crates.io/crates/winnow/1.0.4) |
| writeable | 0.6.4 | Unicode-3.0 | [源码包](https://crates.io/crates/writeable/0.6.4) |
| yoke | 0.8.3 | Unicode-3.0 | [源码包](https://crates.io/crates/yoke/0.8.3) |
| yoke-derive | 0.8.4 | Unicode-3.0 | [源码包](https://crates.io/crates/yoke-derive/0.8.4) |
| zerofrom | 0.1.8 | Unicode-3.0 | [源码包](https://crates.io/crates/zerofrom/0.1.8) |
| zerofrom-derive | 0.1.8 | Unicode-3.0 | [源码包](https://crates.io/crates/zerofrom-derive/0.1.8) |
| zerotrie | 0.2.5 | Unicode-3.0 | [源码包](https://crates.io/crates/zerotrie/0.2.5) |
| zerovec | 0.11.8 | Unicode-3.0 | [源码包](https://crates.io/crates/zerovec/0.11.8) |
| zerovec-derive | 0.11.6 | Unicode-3.0 | [源码包](https://crates.io/crates/zerovec-derive/0.11.6) |
| zmij | 1.0.23 | MIT | [源码包](https://crates.io/crates/zmij/1.0.23) |

## 素材与参考实现

- **LobeHub icons 1.95.1**：MIT，Copyright (c) 2023 LobeHub；24 张服务商品牌 SVG 的逐项映射和变换见 [PROVIDER-ICONS.md](ios/Moonread/AI/PROVIDER-ICONS.md)。不沿用来源未闭环的 Gupi 中间副本。
- **Pi**：MIT，Copyright (c) 2025 Mario Zechner；协议与认证实现参考/适配来源为 [pi-mono](https://github.com/badlogic/pi-mono/tree/200387122ca450d6387f033949423114a270b96c)。保留完整 MIT 声明，不把协议常量的来源误写成服务商授权。
- **SwiftUI Expert skill**：仅开发资料，MIT，Copyright (c) 2026 Antoine van der Lee，固定 [4.2.0 / 9692ec5](https://github.com/AvdLee/SwiftUI-Agent-Skill/tree/9692ec5c3e78a0acc7757de2dbe8e64e519a72fb)，原始 LICENSE 保留在 skill 目录。
- **FlowDown**：仅设计思路参考，不是依赖，未复制其 AGPL 实现；参见 [MarkdownView 集成说明](ios/Moonread/AI/MARKDOWNVIEW.md)。

本表覆盖当前锁定版本，不替代对历史 Git/GitHub 材料的处理。许可来源和版权声明保留上游公共作者信息，与本地私人数据脱敏分开。
