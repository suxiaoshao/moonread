import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI


/// The only choice made before Start, because it decides which service is billed.
public struct AICoverModePicker: View {
    public init(mode: Binding<AICoverMode>) { self._mode = mode }
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Binding public var mode: AICoverMode
    private func available(_ mode: AICoverMode) -> Bool { ai.providers.purposeSelection(mode.purpose) != nil }
    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            Picker("方式", selection: $mode) {
                ForEach(AICoverMode.all) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("aiCoverMode")
            if !available(mode) {
                AIModelPickerButton(purpose: mode.purpose, title: mode.unavailable)
                    .font(.subheadline).frame(minHeight: LayoutTokens.hit)
            }
        }
        .onAppear { if !available(mode), let other = AICoverMode.all.first(where: available) { mode = other } }
    }
    public static func canStart(_ mode: AICoverMode, _ ai: AIService) -> Bool { ai.providers.purposeSelection(mode.purpose) != nil }
}

/// A candidate as the session presents it; bytes stay with the session's attachment store.
public struct AICoverCandidateItem: Identifiable {
    public init(id: String, size: CGSize? = nil, source: String? = nil, sourceURL: URL? = nil,
                failure: String? = nil, load: @escaping @MainActor (Int) async -> UIImage?) {
        self.id = id; self.size = size; self.source = source; self.sourceURL = sourceURL
        self.failure = failure; self.load = load
    }
    public let id: String
    public var size: CGSize?
    /// Source domain or explicit origin label.
    public var source: String?
    public var sourceURL: URL?
    public var failure: String?
    public let load: @MainActor (_ pixels: Int) async -> UIImage?
}

public struct AICoverCandidateGrid: View {
    public init(items: [AICoverCandidateItem], open: @escaping (AICoverCandidateItem) -> Void) {
        self.items = items; self.open = open
    }
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    public let items: [AICoverCandidateItem]
    public let open: (AICoverCandidateItem) -> Void
    public var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: LayoutTokens.control, alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2)
        LazyVGrid(columns: columns, spacing: LayoutTokens.content) {
            ForEach(items) { item in
                Button { open(item) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        AICoverImage(item: item, pixels: 480)
                            .aspectRatio(3.0 / 4.0, contentMode: .fit)
                            .clipShape(.rect(cornerRadius: 10))
                        Text(verbatim: AICoverCandidateItem.caption(item)).font(.caption)
                            .foregroundStyle(Color(uiColor: item.failure == nil ? theme.secondary : theme.destructive)).lineLimit(2, reservesSpace: true)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(item.failure != nil)
                .accessibilityLabel(Text("封面候选"))
                .accessibilityValue(Text(verbatim: AICoverCandidateItem.caption(item)))
                .accessibilityIdentifier("aiCoverCandidate-\(item.id)")
            }
        }
    }
}

extension AICoverCandidateItem {
    public static func caption(_ item: AICoverCandidateItem) -> String {
        if let failure = item.failure { return failure }
        var parts: [String] = []
        if let size = item.size { parts.append("\(Int(size.width))×\(Int(size.height))") }
        parts.append(item.source ?? String(localized: "图片"))
        return parts.joined(separator: " · ")
    }
}

public struct AICoverImage: View {
    public init(item: AICoverCandidateItem, pixels: Int) { self.item = item; self.pixels = pixels }
    @Environment(\.theme) private var theme
    public let item: AICoverCandidateItem
    public let pixels: Int
    @State private var image: UIImage?
    public var body: some View {
        ZStack {
            Color(uiColor: theme.selected)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if item.failure == nil { ProgressView() }
            else { Image(systemName: "photo").foregroundStyle(Color(uiColor: theme.secondary)) }
        }
        .task(id: item.id) { image = await item.load(pixels) }
    }
}

/// Full candidate with the current cover beside it for comparison.
public struct AICoverPreview: View {
    public init(item: AICoverCandidateItem, bookTitle: String, currentCover: BookCoverAsset?,
                contentSHA256: String? = nil, author: String? = nil,
                useAsReference: (() -> Void)? = nil, canUseReference: Bool = true,
                setCover: @escaping () async -> Bool) {
        self.item = item; self.bookTitle = bookTitle; self.currentCover = currentCover
        self.contentSHA256 = contentSHA256; self.author = author; self.useAsReference = useAsReference
        self.canUseReference = canUseReference; self.setCover = setCover
    }
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    public let item: AICoverCandidateItem
    public let bookTitle: String
    public let currentCover: BookCoverAsset?
    public var contentSHA256: String? = nil
    public var author: String? = nil
    /// Nil when the image service cannot edit with a reference.
    public var useAsReference: (() -> Void)?
    public var canUseReference = true
    public let setCover: () async -> Bool
    @State private var working = false
    @State private var failed = false
    @State private var saved = false
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.section) {
                    AICoverImage(item: item, pixels: 1600).aspectRatio(3.0 / 4.0, contentMode: .fit).clipShape(.rect(cornerRadius: 14))
                        .frame(maxHeight: 420).frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("封面候选"))
                    HStack(alignment: .center, spacing: LayoutTokens.control) {
                        MetadataCoverPreview(title: bookTitle, cover: currentCover, contentSHA256: contentSHA256, author: author).frame(width: 48, height: 68)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当前封面").font(.subheadline)
                        }
                    }.accessibilityElement(children: .combine)
                    Text(verbatim: AICoverCandidateItem.caption(item)).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    if let url = item.sourceURL {
                        Button { openURL(url) } label: { Label("来源", systemImage: "safari") }.frame(minHeight: LayoutTokens.hit)
                    }
                }.padding([.horizontal, .top], LayoutTokens.content).padding(.bottom)
            }
            // The decision stays reachable without scrolling past the image.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: LayoutTokens.compact) {
                    if failed { Text("暂时无法设为封面").font(.footnote).foregroundStyle(Color(uiColor: theme.destructive)) }
                    if saved { Text("封面已更新").font(.footnote).foregroundStyle(Color(uiColor: theme.success)) }
                    Button {
                        working = true
                        Task { saved = await setCover(); failed = !saved; working = false }
                    } label: {
                        HStack { if working { ProgressView() }; Text("设为封面") }.frame(maxWidth: .infinity)
                    }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).disabled(working)
                        .accessibilityIdentifier("setAICover")
                    if let useAsReference {
                        Button("以此修改", systemImage: "wand.and.stars") { useAsReference(); dismiss() }
                            .frame(maxWidth: .infinity, minHeight: LayoutTokens.hit).disabled(!canUseReference).accessibilityIdentifier("editAICover")
                        if !canUseReference { Text("请选择支持工具的对话模型。").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                    }
                }.padding(LayoutTokens.content).background(Color(uiColor: theme.canvas))
            }
            .themedPage().navigationTitle("封面").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SystemToolbarButton("关闭", role: .close) { dismiss() }.accessibilityIdentifier("closeAICoverPreview") } }
        }
    }
}
