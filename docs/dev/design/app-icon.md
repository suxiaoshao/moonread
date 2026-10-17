# 应用图标

状态：2026-10-16 桌面图标改为「夜读」：深蓝夜空、一弯暖金色月亮、两颗星，下方一本翻开的书。`.icon` 已更新并接入工程，`ictool` 已渲染 26、27 两代系统的全部外观。启动图、关于页与无封面扉页同步换成新图标；阅读助手同步改为「月光」。真机主屏效果待试用确认。应用内操作图标的分工见[外观设计](appearance.md)。

## 设计方向

- 中文名：月读；英文名：Moonread。
- 出发点是“睡前在床上读小说”。书是主角，一眼就能看出这是阅读应用；夜空和月亮点出“睡前”，不再把月亮当成主概念。
- 参照主流阅读应用：Apple 图书、微信读书等都以一本书或书页为主体，形状不超过两三块，品牌差异靠底色。静读天下以月亮为主体，所以我们的月亮只做点缀，避免相像。
- 深蓝底在主屏上能和 Apple 图书的橙色、常见小说应用的红色分开。书页用暖米色，像床头灯照在纸上；月亮用暖金色。
- 书保持左右对称。画面的不对称由左上的月亮和右上的星星承担。翻页式的不对称会和月亮争抢焦点，小尺寸下显得乱，也太像 Apple 图书，所以不用。
- 只用清晰的平面形状，不预先画高光、阴影、模糊或描边；立体感交给系统的 Liquid Glass 材质。
- 2026-10-10 至 10-16 使用的「月印」字标（朱红底，弯月、书签和两行字组成「月」字）已停用。它概念成立但需要解释，远看先看到的是符号而不是书。

## 母版与几何

- [夜读 SVG 母版](../../../assets/icon/night-reading.svg)：1024 × 1024，透明背景，由四个图层按从下到上的顺序合成。母版也是应用内品牌资产 `BrandGlyph` 的原图。
- 书：左右镜像，以 x = 512 为书脊。单页上沿从书脊 (512, 540) 经控制点 (458, 492)、(338, 466) 到外角 (200, 488)；外沿垂直向下到 y = 760；下沿经 (334, 738)、(452, 756) 回到书脊 (512, 806)。书页下方露出两层纸张厚度：第 k 层的外角向外移 10k、向下移 6k，下沿向下移 16k，书脊底端向下移 18k。书脊折线从 (512, 548) 到 (512, 798)，线宽 7。
- 月亮：两圆相减。外圆圆心 (356, 296)、半径 110；内圆圆心相对外圆偏移 (+0.40r, −0.30r)，半径 0.84r。
- 星星：四角星，四条边都是内凹曲线。大星中心 (672, 236)、半径 30；小星中心 (772, 352)、半径 19。
- 配色（默认外观）：
  - 背景渐变 `#2B3D78` → `#0F1736`
  - 书页 `#FFF4DF`；书脊线与第一层纸 `#EED6AA`；第二层纸 `#D2AF73`
  - 月亮 `#F7C75F`；星星 `#FFE7B0`

## Icon Composer 组合稿

- [Moonread.icon](../../../assets/icon/Moonread.icon)：四个分组，自上而下为：
  1. `Pages`：书页与书脊线；
  2. `Stack`：纸张厚度；
  3. `Moon`：月亮；
  4. `Stars`：星星。
- 分组的目的是让系统材质在书页与纸张之间、月亮与夜空之间产生前后层次。图层素材都是完整的 1024 画布，100% 缩放，无偏移：`night-pages.svg`、`night-stack.svg`、`night-moon.svg`、`night-stars.svg`。
- 外观：
  - Dark：背景改为 `#18223F` → `#070A17`；书页 `#EADAB9`，纸张 `#C9AE7E`／`#9E8455`；月亮 `#E9B44E`，星星 `#E9D3A0`（各图层的 `-dark.svg`）。
  - Tinted：绑定 `-mono.svg`，书页与月亮为白色，纸张为两级灰，几何与默认外观一致。
  - 更新母版时，三套图层要同步重新派生。
- 各分组的半透明关闭，中性阴影不透明度 50%，高光 Automatic。

[两代系统外观对照](../../../assets/icon/moonread-icon-appearances-preview.png)：上排为 27 代，下排为 26 代；从左到右依次为 Default、Dark、ClearLight、ClearDark、TintedLight、TintedDark。下面的单张 512 × 512 PNG 都是 27 代渲染，只用于预览，应用实际使用的是 `.icon` 源文件：

- [默认](../../../assets/icon/moonread-icon-default.png)
- [深色](../../../assets/icon/moonread-icon-dark.png)
- [浅色透明](../../../assets/icon/moonread-icon-clear-light.png)
- [深色透明](../../../assets/icon/moonread-icon-clear-dark.png)
- [深色着色](../../../assets/icon/moonread-icon-tinted-dark.png)
- [浅色着色](../../../assets/icon/moonread-icon-tinted-light.png)

着色预览中的紫色是导出工具的默认示例色，不是品牌色。透明外观在真机上还会受壁纸影响。87、120、180 px 小尺寸已用 `ictool` 导出检查：书、月亮和星星都可辨认。

## 资源分工

- 应用图标：`.icon`（Icon Composer 组合），App 内不读取。
- 启动图：`LaunchSeal` 是用 `ictool` 以 Default 外观导出的 120pt 桌面图标（1x/2x/3x PNG），系统 Launch Screen 和 App 首帧 `MoonLaunchCover` 共用。
- 品牌位置：`BrandSeal` 在 SwiftUI 中绘制深蓝渐变的连续圆角方块（与图标背景同色），上面叠加矢量资产 `BrandGlyph`（`night-reading.svg` 原色渲染）。用于关于页和无封面扉页，颜色固定，不随阅读主题变化。
- 应用内：`MoonArtwork` 用固定品牌色与两圆相减路径绘制「月光」（`MoonView` 空闲形象，以及阅读助手的六种任务状态）。无五官或道具，动效与状态见[月亮组件](motion-and-moon.md)和[阅读月亮入口](ai.md#阅读月亮入口)。

## 平台制作参考

- 用少量清晰的形状表达核心概念，注意小尺寸和不同外观下的识别：[Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)。
- 平面图形优先保留矢量源图并分层导出；高光、阴影等系统材质在 Icon Composer 中调整，源图不预先加外形遮罩：[Apple Icon Composer 制作流程](https://developer.apple.com/videos/play/wwdc2025/361/)。
