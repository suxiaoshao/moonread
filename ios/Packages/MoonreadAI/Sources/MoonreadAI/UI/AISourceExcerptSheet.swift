import MoonreadDesign
import SwiftUI

public struct AISourceExcerptSheet: View {
    let id: String
    let title: String
    let load: () async throws -> String

    public init(id: String, title: String, load: @escaping () async throws -> String) {
        self.id = id
        self.title = title
        self.load = load
    }
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var error: String?
    public var body: some View {
        NavigationStack {
            ScrollView {
                if let text { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                else if let error { Text(error).padding() }
                else { ProgressView().padding() }
            }.themedPage().navigationTitle(title.isEmpty ? String(localized: "原文") : title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() } } }
        }.presentationDetents([.medium, .large]).task(id: id) {
            do {
                text = try await load()
            } catch { self.error = String(localized: "此处原文暂时不可用。") }
        }
    }
}
