import SwiftUI

enum ThirdPartyNotices {
    struct Paragraph: Identifiable, Sendable {
        let id = UUID()
        let number: Int
        let text: String
    }
    struct Source: Identifiable, Sendable {
        let id: String
        let version: String
        var label: String { "\(id) \(version)" }
        var url: URL { URL(string: "https://crates.io/crates/\(id)/\(version)")! }
    }
    static let mplSources = [
        Source(id: "cssparser", version: "0.37.0"),
        Source(id: "cssparser-macros", version: "0.7.1"),
        Source(id: "dtoa-short", version: "0.3.5"),
        Source(id: "selectors", version: "0.38.0"),
    ] + ["uniffi", "uniffi_bindgen", "uniffi_core", "uniffi_internal_macros", "uniffi_macros", "uniffi_meta", "uniffi_pipeline", "uniffi_udl"]
        .map { Source(id: $0, version: "0.32.2") }

    nonisolated static func loadParagraphs() throws -> [Paragraph] {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Preserve every paragraph, including empty ones; avoid laying out the entire
        // attribution resource as one enormous Text when opening this page.
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n\n")
            .enumerated().map { Paragraph(number: $0.offset, text: $0.element) }
    }
}

struct ThirdPartyLicensesView: View {
    @Environment(\.theme) private var theme
    @State private var paragraphs: [ThirdPartyNotices.Paragraph]?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("MPL 组件源码").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("以下组件使用 MPL-2.0。打开对应版本链接后，选择 Download 即可取得源码。月读使用这些组件的未修改上游版本；其他组件的许可和版权声明在下方全文列出。")
                ForEach(ThirdPartyNotices.mplSources) { source in
                    Link(source.label, destination: source.url)
                        .foregroundStyle(Color(uiColor: theme.accent))
                        .accessibilityIdentifier("thirdPartySource-" + source.id)
                }
                ThemedDivider()
                Text("许可与版权全文").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                if let paragraphs {
                    ForEach(paragraphs) { paragraph in
                        Text(verbatim: paragraph.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier(paragraph.number == 0 ? "thirdPartyNoticesFirstParagraph" : "thirdPartyNotice-\(paragraph.number)")
                    }
                } else if failed {
                    Text("无法读取许可，请重新打开此页面。")
                } else {
                    ProgressView("正在读取许可…")
                }
            }
            .foregroundStyle(Color(uiColor: theme.ink))
            .tint(Color(uiColor: theme.accent))
            .padding()
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .themedPage()
        .navigationTitle("第三方许可").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("thirdPartyNoticesScroll")
        .task {
            guard paragraphs == nil else { return }
            do {
                let loaded = try await Task.detached(priority: .utility) { try ThirdPartyNotices.loadParagraphs() }.value
                guard !Task.isCancelled else { return }
                paragraphs = loaded
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
