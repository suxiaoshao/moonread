import MoonreadDesign
import SwiftUI

public struct AIChatAttachmentPreview: View {
    let attachment: AIReadingAttachment
    let loadImage: () async throws -> UIImage

    public init(attachment: AIReadingAttachment, loadImage: @escaping () async throws -> UIImage) {
        self.attachment = attachment
        self.loadImage = loadImage
    }
    @State private var image: UIImage?
    @State private var imageError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(attachment.summary, systemImage: attachment.symbol).font(.headline)
                    if attachment.kind == .image {
                        Text("用于图片修改")
                            .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                        if let image { Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("aiReferenceImagePreview") }
                        else if let imageError { Text(verbatim: imageError).foregroundStyle(Color(uiColor: theme.destructive)) }
                        else { ProgressView() }
                    }
                    if let chapter = attachment.chapter { Text(chapter).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if let progress = attachment.progress { Text(progress, format: .percent.precision(.fractionLength(1))).foregroundStyle(Color(uiColor: theme.secondary)) }
                    if let text = attachment.excerpt, !text.isEmpty { Text(text).textSelection(.enabled) }
                    if let note = attachment.note, !note.isEmpty { Text(note).textSelection(.enabled) }
                    if let conflicts = attachment.conflictContents, !conflicts.isEmpty {
                        Text("批注有冲突").font(.headline)
                        ForEach(conflicts) { version in
                            VStack(alignment: .leading) {
                                if let value = version.content { Text(value.excerpt); Text(value.note) }
                                else { Text("已移除") }
                            }
                                .padding().background(Color(uiColor: theme.raised), in: .rect(cornerRadius: 12))
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.themedPage().navigationTitle("阅读附件").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() } } }
        }.presentationDetents([.medium, .large])
            .task(id: attachment.attachmentRef) {
                guard attachment.kind == .image else { return }
                do {
                    image = try await loadImage()
                } catch { imageError = String(localized: "参考图片已不可用。") }
            }
    }
}
