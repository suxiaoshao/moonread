import SwiftUI

public struct BookSearchOptionSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String
    var prompt: LocalizedStringKey = "搜索选项"

    public init(enabled: Bool, query: Binding<String>, prompt: LocalizedStringKey = "搜索选项") {
        self.enabled = enabled; self._query = query; self.prompt = prompt
    }

    public func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, prompt: prompt)
        } else {
            content
        }
    }
}
