import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import MoonreadDesign
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

public struct BookMetadataEditor<Cover: View, TagPicker: View>: View {
    @Bindable var draft: BookMetadataDraft
    let cover: (BookMetadata) -> Cover
    let tagPicker: (Binding<[String]>) -> TagPicker
    let save: (BookMetadata, BookMetadata) async throws -> Void
    let describeError: (Error) -> String

    public init(draft: BookMetadataDraft, save: @escaping (BookMetadata, BookMetadata) async throws -> Void,
                describeError: @escaping (Error) -> String, @ViewBuilder cover: @escaping (BookMetadata) -> Cover,
                @ViewBuilder tagPicker: @escaping (Binding<[String]>) -> TagPicker) {
        self.draft = draft
        self.save = save
        self.describeError = describeError
        self.cover = cover
        self.tagPicker = tagPicker
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var photo: PhotosPickerItem?
    @State private var discard = false
    @ViewBuilder private var coverActions: some View {
        Button("从照片选择", systemImage: "photo") { draft.presentsPhotoPicker = true }
            .buttonStyle(ThemedSecondaryButtonStyle()).disabled(draft.choosingImage)
        Button("从文件选择", systemImage: "folder") { draft.presentsFilePicker = true }
            .buttonStyle(ThemedSecondaryButtonStyle()).disabled(draft.choosingImage)
    }
    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 16) {
                        cover(draft.value).frame(width: 112, height: 160)
                        ZStack {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { coverActions }
                                VStack(spacing: 12) { coverActions }
                            }
                            .opacity(draft.choosingImage ? 0 : 1)
                            .accessibilityHidden(draft.choosingImage)
                            if draft.choosingImage {
                                InlineTaskProgress(title: Text("正在处理图片"))
                                    .font(.subheadline)
                                    .foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }
                        if draft.value.cover != nil {
                            Menu {
                                Button("移除封面", systemImage: "trash", role: .destructive) { draft.removeCover() }
                            } label: { Label("更多", systemImage: "ellipsis") }
                                .disabled(draft.choosingImage).accessibilityIdentifier("coverMore")
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                } header: { Text("封面") }
                .listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                Section("作者") {
                    TextField("作者", text: $draft.value.author).focused($focused).keyboardInputRegion()
                        .accessibilityIdentifier("bookAuthorField")
                }.listRowBackground(Color(uiColor: theme.surface))
                Section("标签") {
                    NavigationLink {
                        tagPicker($draft.value.tags)
                    } label: {
                        tagSummary
                    }
                    .accessibilityIdentifier("editBookTags")
                }.listRowBackground(Color(uiColor: theme.surface))
                Section("简介") {
                    TextField("简介", text: $draft.value.synopsis, axis: .vertical).lineLimit(4...12)
                        .focused($focused).keyboardInputRegion().accessibilityIdentifier("bookSynopsisField")
                }.listRowBackground(Color(uiColor: theme.surface))
            }.disabled(draft.saving).themedPage().scrollDismissesKeyboard(.interactively).dismissKeyboardOnOutsideTap($focused)
                .navigationTitle("编辑小说信息").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SystemToolbarButton("取消", role: .cancel) {
                            switch draft.requestLeave() {
                            case .close: dismiss()
                            case .confirmDiscard: discard = true
                            }
                        }
                            .disabled(draft.saving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        SystemToolbarButton("保存", role: .confirm) {
                            focused = false; draft.saving = true
                            Task {
                                defer { draft.saving = false }
                                do { try await save(draft.base, draft.value); dismiss() }
                                catch { draft.error = describeError(error) }
                            }
                        }.disabled(draft.saving || draft.choosingImage).accessibilityIdentifier("saveBookMetadata")
                    }
                }
                .alert("放弃未保存的修改？", isPresented: $discard) {
                    Button("放弃修改", role: .destructive) { draft.cancel(); dismiss() }
                    Button("取消", role: .cancel) {}
                }
                .photosPicker(isPresented: $draft.presentsPhotoPicker, selection: Binding(get: { photo }, set: { item in
                    photo = item
                    if let item { draft.chooseImage { try await item.loadTransferable(type: Data.self) } }
                }), matching: .images)
                .fileImporter(isPresented: $draft.presentsFilePicker, allowedContentTypes: [.image]) { result in
                    draft.chooseImage {
                        let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        return try await Task.detached { try Data(contentsOf: url) }.value
                    }
                }
                .alert("暂时无法完成", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) {
                    Button("知道了", role: .cancel) { draft.error = nil }
                } message: { Text(draft.error ?? "") }
        }.interactiveDismissDisabled(draft.blocksInteractiveDismissal)
            .onDisappear { draft.cancel() }
    }
    @ViewBuilder private var tagSummary: some View {
        let tags = draft.value.tags
        if tags.isEmpty {
            Text("选择标签").foregroundStyle(Color(uiColor: theme.secondary))
        } else {
            HStack(spacing: LayoutTokens.compact) {
                ForEach(tags.prefix(2), id: \.self) { tag in
                    BookTagSummaryCapsule(name: tag)
                }
                if tags.count > 2 {
                    Text("+\(tags.count - 2)").font(.subheadline)
                        .foregroundStyle(Color(uiColor: theme.secondary))
                        .fixedSize()
                }
            }
            .accessibilityLabel("标签")
            .accessibilityValue(tags.joined(separator: "、"))
        }
    }
}
