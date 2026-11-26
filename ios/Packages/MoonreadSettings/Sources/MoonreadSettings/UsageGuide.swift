import MoonreadDesign
import SwiftUI

/// Static help: it never opens a reader or accesses a book's data.
public struct SettingsUsageGuide: View {
    private let aiAvailable: Bool

    public init(aiAvailable: Bool) { self.aiAvailable = aiAvailable }
    @Environment(\.theme) private var theme
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("开始读", "在书架右上角点“＋”，选择“导入小说”，或从“文件”App 把 TXT 拖进“我的书架”。在书架文件夹里导入时，小说会留在当前文件夹。第一次打开大文件时，月读会边准备边显示正文。")
                section("设置", "在书架、统计等主页面点右上角的齿轮，即可进入设置。阅读、外观、书架与同步都在这里调整。")
                section("翻页和工具栏", "轻点屏幕中间，显示或隐藏阅读工具。分页模式下，点左右两侧或左右滑动翻页；滚动模式下，上下滑动即可。")
                if aiAvailable {
                    section("选字", "长按正文选中文字，可以标注、写批注、拷贝、全文搜索或问 AI。跨页选取时，在起点选择“从这里跨页选取”，翻到终点再长按选字，然后选择拷贝或“批注到这里”。")
                } else {
                    section("选字", "长按正文选中文字，可以标注、写批注、拷贝或全文搜索。跨页选取时，在起点选择“从这里跨页选取”，翻到终点再长按选字，然后选择拷贝或“批注到这里”。")
                }
                section("目录、书签和搜索", "显示阅读工具后，可以打开目录和全文搜索；书签与批注在“更多”中。退出阅读时会自动保存位置。")
                section("外观", "在阅读设置里调整字号、行距、段距和配色，上方会预览排版效果。")
                if aiAvailable {
                    section("AI 助手", "在设置的“AI 助手”中添加连接并选择模型后，可以针对当前页面或选中的文字提问。只有你主动使用 AI 时，才会发送相应上下文。")
                }
                section("iCloud", "开启系统 iCloud Drive 后，“我的书架”的小说文件由 iCloud Drive 同步。阅读进度、书签和批注由设置中的“阅读数据 iCloud 同步”控制；更换账户时可能需要确认。")
            }.padding().frame(maxWidth: 640, alignment: .leading).frame(maxWidth: .infinity)
        }.themedPage().navigationTitle("月读使用指南").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("usageGuide")
    }
    private func section(_ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).foregroundStyle(Color(uiColor: theme.ink)).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(text).font(.body).foregroundStyle(Color(uiColor: theme.ink)).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(LayoutTokens.content)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            .overlay { RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).stroke(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
    }
}
