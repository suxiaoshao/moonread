import SwiftUI

struct PalettePreview: View {
    let theme: ThemeSurface
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { MoonView(size: 32); Text("月光入窗").font(.headline); Spacer(); Image(systemName: "bookmark") }
            VStack(alignment: .leading, spacing: 12) {
                Text("夜色温柔，翻过一页，还有新的故事。")
                Text("月光停在书页间").padding(.horizontal, 4).background(Color(uiColor: theme.annotation), in: .rect(cornerRadius: 4))
                Text("在故事里寻找").padding(.horizontal, 4).background(Color(uiColor: theme.search), in: .rect(cornerRadius: 4))
            }.font(.body).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: theme.paper), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            HStack { Text("第一章 · 12%").foregroundStyle(Color(uiColor: theme.secondary)); Spacer(); Text("继续阅读").foregroundStyle(Color(uiColor: theme.accent)) }.font(.caption)
        }.padding(LayoutTokens.page).background(Color(uiColor: theme.canvas), in: .rect(cornerRadius: LayoutTokens.floatingRadius))
            .themeScope(theme).accessibilityIdentifier("palettePreview")
    }
}
