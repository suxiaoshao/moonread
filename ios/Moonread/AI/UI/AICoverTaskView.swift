import SwiftUI

extension AICoverMode: Identifiable {
    static let all: [AICoverMode] = [.find, .generate]
    var id: Self { self }
    var title: LocalizedStringKey { self == .find ? "查找" : "生成" }
    var purpose: AIModelPurpose { self == .find ? .search : .image }
    var unavailable: LocalizedStringKey { self == .find ? "未设置联网搜索" : "未设置图片生成" }
}

/// The only choice made before Start, because it decides which service is billed.
struct AICoverModePicker: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Binding var mode: AICoverMode
    private func available(_ mode: AICoverMode) -> Bool { ai.providers.purposeSelection(mode.purpose) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            Picker("方式", selection: $mode) {
                ForEach(AICoverMode.all) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("aiCoverMode")
            if !available(mode) {
                NavigationLink { AIToolServiceView(purpose: mode.purpose) } label: {
                    Label { Text(mode.unavailable) } icon: { Image(systemName: "chevron.right").font(.caption) }
                        .labelStyle(AITrailingIconLabelStyle())
                }.font(.subheadline).frame(minHeight: LayoutTokens.hit)
            }
        }
        .onAppear { if !available(mode), let other = AICoverMode.all.first(where: available) { mode = other } }
    }
    static func canStart(_ mode: AICoverMode, _ ai: AIService) -> Bool { ai.providers.purposeSelection(mode.purpose) != nil }
}

/// A candidate as the session presents it; bytes stay with the session's attachment store.
struct AICoverCandidateItem: Identifiable {
    let id: String
    var size: CGSize?
    /// Source domain or explicit origin label.
    var source: String?
    var sourceURL: URL?
    var failure: String?
    let load: @MainActor (_ pixels: Int) async -> UIImage?
}

struct AICoverCandidateGrid: View {
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let items: [AICoverCandidateItem]
    let open: (AICoverCandidateItem) -> Void
    var body: some View {
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
    static func caption(_ item: AICoverCandidateItem) -> String {
        if let failure = item.failure { return failure }
        var parts: [String] = []
        if let size = item.size { parts.append("\(Int(size.width))×\(Int(size.height))") }
        parts.append(item.source ?? String(localized: "图片"))
        return parts.joined(separator: " · ")
    }
}

struct AICoverImage: View {
    @Environment(\.theme) private var theme
    let item: AICoverCandidateItem
    let pixels: Int
    @State private var image: UIImage?
    var body: some View {
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
struct AICoverPreview: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let item: AICoverCandidateItem
    let bookTitle: String
    let currentCover: BookCoverAsset?
    /// Nil when the image service cannot edit with a reference.
    var useAsReference: (() -> Void)?
    var canUseReference = true
    let setCover: () async -> Bool
    @State private var working = false
    @State private var failed = false
    @State private var saved = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LayoutTokens.section) {
                    AICoverImage(item: item, pixels: 1600).aspectRatio(3.0 / 4.0, contentMode: .fit).clipShape(.rect(cornerRadius: 14))
                        .frame(maxHeight: 420).frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("封面候选"))
                    HStack(alignment: .center, spacing: LayoutTokens.control) {
                        LibraryBookCover(title: bookTitle, cover: currentCover).frame(width: 48, height: 68)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("当前封面").font(.subheadline)
                        }
                    }.accessibilityElement(children: .combine)
                    Text(verbatim: AICoverCandidateItem.caption(item)).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                    if let url = item.sourceURL {
                        Button { openURL(url) } label: { Label("来源", systemImage: "safari") }.frame(minHeight: LayoutTokens.hit)
                    }
                }.padding(LayoutTokens.content)
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
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark") { dismiss() }.accessibilityIdentifier("closeAICoverPreview") } }
        }
    }
}
