import SwiftUI
import TipKit

/// Static help: it never opens a reader or accesses a book's data.
struct UsageGuideView: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("开始读", "在书架右上角点“＋”，选择“导入小说”，或从“文件”App 把 TXT 拖进“我的书架”。在书架文件夹里导入时，小说会留在当前文件夹。第一次打开大文件时，月读会边准备边显示正文。")
                section("翻页和工具栏", "轻点屏幕中间，显示或隐藏阅读工具。分页模式下，点左右两侧或左右滑动翻页；滚动模式下，上下滑动即可。")
                if ai.availability.isAvailable {
                    section("选字", "长按正文选中文字，可以标注、写批注、拷贝、全文搜索或问 AI。跨页选取时，在起点选择“从这里跨页选取”，翻到终点再长按选字，然后选择拷贝或“批注到这里”。")
                } else {
                    section("选字", "长按正文选中文字，可以标注、写批注、拷贝或全文搜索。跨页选取时，在起点选择“从这里跨页选取”，翻到终点再长按选字，然后选择拷贝或“批注到这里”。")
                }
                section("目录、书签和搜索", "显示阅读工具后，可以打开目录和全文搜索；书签与批注在“更多”中。退出阅读时会自动保存位置。")
                section("外观", "在阅读设置里调整字号、行距、段距和配色，上方会预览排版效果。")
                if ai.availability.isAvailable {
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

struct ImportNovelTip: Tip {
    var title: Text { Text("导入 TXT 小说，也可以从“文件”App 直接拖进来") }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}
struct ReaderControlsTip: Tip {
    var title: Text { Text("轻点屏幕中间显示工具栏") }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}
struct ReaderSelectionTip: Tip {
    var title: Text { Text("长按文字可以标注、写批注、拷贝或问 AI") }
    var options: [any TipOption] { Tips.MaxDisplayCount(1) }
}

/// Eligibility is device-local; TipKit owns dismissal and presentation history.
@MainActor @Observable final class Onboarding {
    static let shared = Onboarding()
    let imports = ImportNovelTip()
    let controls = ReaderControlsTip()
    let selection = ReaderSelectionTip()
    private(set) var enabled: Bool
    private enum Key {
        static let imported = "Moonread.onboarding.imported"
        static let controls = "Moonread.onboarding.controls"
        static let selection = "Moonread.onboarding.selection"
    }
    private let defaults: UserDefaults
    private(set) var imported: Bool
    private(set) var revealedControls: Bool
    private(set) var selectedText: Bool
    init(defaults: UserDefaults = .standard, enabled: Bool? = nil) {
        let args = ProcessInfo.processInfo.arguments
        self.enabled = enabled ?? (!args.contains("--disable-tips") && (!args.contains("--ui-testing") || args.contains("--ui-test-tips")))
        let session = args.firstIndex(of: "--ui-test-session").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        self.defaults = session.flatMap { UserDefaults(suiteName: "Moonread.Onboarding." + $0) } ?? defaults
        imported = self.defaults.bool(forKey: Key.imported)
        revealedControls = self.defaults.bool(forKey: Key.controls)
        selectedText = self.defaults.bool(forKey: Key.selection)
        guard self.enabled else { return }
        do {
            var config: [Tips.ConfigurationOption] = [.displayFrequency(.immediate)]
            if let session {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Tips-" + session)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                config.append(.datastoreLocation(.url(url)))
            }
            try Tips.configure(config)
        } catch { self.enabled = false }
    }
    func didImport() { guard !imported else { return }; imported = true; defaults.set(true, forKey: Key.imported); if enabled { imports.invalidate(reason: .actionPerformed) } }
    func didShowControls() { guard !revealedControls else { return }; revealedControls = true; defaults.set(true, forKey: Key.controls); if enabled { controls.invalidate(reason: .actionPerformed) } }
    func didSelectText() { guard !selectedText else { return }; selectedText = true; defaults.set(true, forKey: Key.selection); if enabled { selection.invalidate(reason: .actionPerformed) } }
}

/// Own the entire TipKit card so its close control follows the same palette.
struct ThemedTipStyle: TipViewStyle {
    var titleOverride: Text? = nil
    func makeBody(configuration: Configuration) -> some View {
        ThemedTipCard(title: titleOverride ?? configuration.title, message: configuration.message, image: configuration.image) {
            configuration.tip.invalidate(reason: .tipClosed)
        }
    }
}

struct ThemedTipCard: View {
    let title: Text?
    var message: Text? = nil
    var image: Image? = nil
    let dismiss: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(alignment: .center, spacing: LayoutTokens.control) {
            image.foregroundStyle(Color(uiColor: theme.secondary))
            VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                title.font(.subheadline.weight(.semibold))
                message.font(.subheadline)
            }.foregroundStyle(Color(uiColor: theme.ink)).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                    .frame(width: LayoutTokens.hit, height: LayoutTokens.hit)
            }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.secondary))
                .accessibilityLabel("关闭提示")
        }.padding(LayoutTokens.control)
            .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            .overlay { RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).stroke(Color(uiColor: theme.border), lineWidth: LayoutTokens.border) }
    }
}
