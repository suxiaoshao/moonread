import SwiftUI

struct AIProposalCards: View {
    let results: [AIResultValue]
    var body: some View {
        ForEach(results) { result in AIResultCard(result: result) }
    }
}

/// Canonical history is always visible. Editable reviews are fresh, view-lifetime values.
struct AIResultCard: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let result: AIResultValue
    private var resultID: String { result.id }
    @State private var metadataSheet = false
    @State private var coverSheet = false
    @State private var editor: AINoteEditorRequest?
    @State private var imagePreview: AICoverCandidate?
    @State private var confirmedNodes: Set<String> = []
    @State private var confirmOrganization = false
    @State private var fullTree = false
    @State private var shelfNames: [String: String] = [:]
    private var review: AIReviewValue? { ai.proposals.review(resultID) }
    private var saving: Bool { ai.proposals.inFlight.contains(resultID) }
    var body: some View {
        Group {
            Group {
                switch result.body {
                case .metadata:
                    Button { metadataSheet = true } label: { metadataSummary }
                        .buttonStyle(AIResultButtonStyle()).disabled(saving)
                case .cover, .findCover:
                    Button { coverSheet = true } label: { coverSummary }
                        .buttonStyle(AIResultButtonStyle()).disabled(saving)
                default:
                    VStack(alignment: .leading, spacing: LayoutTokens.control) {
                        switch result.body {
                        case .note(let proposal):
                            if let review, case .note(let note) = review.body { noteContent(note, proposal: proposal) }
                            else { Text("笔记建议").font(.headline) }
                        case .organization:
                            if let review, case .organization(let organization) = review.body { organizationContent(organization) }
                            else { Text("整理方案").font(.headline) }
                        default: EmptyView()
                        }
                        AIResultFeedback(resultID: resultID)
                    }.padding(LayoutTokens.content).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: theme.surface), in: .rect(cornerRadius: LayoutTokens.inputRadius))
                }
            }
            .accessibilityIdentifier("aiResult-\(resultID)")
            .task(id: resultID) {
                await ai.proposals.openResult(result)
                if let shelves = try? await AppDataService.shared.shelves() { shelfNames = Dictionary(uniqueKeysWithValues: shelves.map { ($0.id, $0.name) }) }
            }
            .onDisappear { if !metadataSheet && !coverSheet { ai.proposals.closeResult(resultID) } }
            .sheet(isPresented: $metadataSheet) { AIMetadataResultReview(result: result).themeScope(theme) }
            .sheet(isPresented: $coverSheet) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: LayoutTokens.control) {
                            if let review, case .cover(let cover) = review.body { coverContent(cover) }
                            else if ai.proposals.lastErrors[resultID] == nil { ProgressView().frame(maxWidth: .infinity) }
                            AIResultFeedback(resultID: resultID)
                        }.padding(LayoutTokens.content)
                    }.themedPage().navigationTitle("选择封面").navigationBarTitleDisplayMode(.inline)
                        // Like the metadata review, the sheet owns its review: the card's copy can be closed while it is up.
                        .task { if review == nil { await ai.proposals.openResult(result) } }
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark") { coverSheet = false }.accessibilityIdentifier("closeAICoverSelection") } }
                        .sheet(item: $imagePreview) { candidate in coverPreview(candidate) }
                }.themeScope(theme)
            }
            .sheet(item: $editor) { request in
                NoteEditor(edit: request.edit, aiCommit: ai.proposals.annotationHooks(result)) { editor = nil }
                    .themeScope(theme).preferredColorScheme(theme.scheme)
            }
        }
    }
    private func coverPreview(_ candidate: AICoverCandidate) -> some View {
        AICoverPreview(item: coverItem(candidate), bookTitle: String(localized: "封面"), currentCover: ai.proposals.liveMetadata[resultID]?.cover,
            useAsReference: { Task { try? await ai.proposals.useImage(result, attachmentRef: candidate.id) } },
            setCover: { await ai.proposals.setCover(resultID, attachmentRef: candidate.id) }).themeScope(theme)
    }
    private var metadataSummary: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            HStack {
                Label("资料建议", systemImage: "sparkles").font(.headline)
                if let review, case .metadata(let metadata) = review.body { Text("\(ai.proposals.metadataChangeCount(resultID, metadata)) 项更改").font(.caption) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption)
            }
            if let review, case .metadata(let metadata) = review.body {
                if let rename = metadata.rename, rename.currentName != rename.targetName {
                    Text("书名  \((rename.currentName as NSString).deletingPathExtension) → \(rename.draft)").font(.subheadline)
                }
                ForEach(metadata.fields.filter { ai.proposals.metadataCurrent(resultID, field: $0) != $0.draft }) { field in
                    if field.kind == .tags {
                        let current = Set(ai.proposals.metadataCurrent(resultID, field: field).split(separator: "\n").map(String.init))
                        let offered = Set(field.draft.split(separator: "\n").map(String.init))
                        let delta = offered.subtracting(current).sorted().map { "+" + $0 } + (field.tagsMode == .replace ? current.subtracting(offered).sorted().map { "−" + $0 } : [])
                        (Text("标签  ") + Text(verbatim: delta.joined(separator: "  "))).font(.subheadline)
                    } else {
                        (Text(field.kind.label) + Text(verbatim: "  " + field.draft)).font(.subheadline).lineLimit(3)
                    }
                }
            }
            AIResultFeedback(resultID: resultID)
            ThemedDivider()
            HStack { Text("查看并应用"); Spacer(); Image(systemName: "chevron.right") }.font(.subheadline.weight(.semibold)).foregroundStyle(Color(uiColor: theme.accent))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var coverSummary: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            Label("封面", systemImage: "photo").font(.headline)
            let candidates = Array(AIProposalRegistry.coverCandidates(result).prefix(4))
            if candidates.isEmpty { Text("没有图片候选").font(.subheadline) }
            HStack(alignment: .top, spacing: 8) {
                ForEach(candidates) { candidate in
                    AICoverImage(item: coverItem(candidate), pixels: 240).aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 6))
                }
            }
            AIResultFeedback(resultID: resultID)
            ThemedDivider()
            HStack { Text("选择封面"); Spacer(); Image(systemName: "chevron.right") }.font(.subheadline.weight(.semibold)).foregroundStyle(Color(uiColor: theme.accent))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func noteContent(_ note: AINoteReviewValue, proposal: AINoteProposal) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            Text(proposal.kind == .bookmark ? "书签建议" : "笔记建议").font(.headline)
            Text(verbatim: note.excerpt).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            if note.existingBookmark { Text("已有").font(.caption) }
            else if let reason = note.unavailable { Text("暂不可用").font(.caption); Text(verbatim: reason).font(.footnote) }
            else {
                Toggle("选择", isOn: Binding(get: { note.selected }, set: { ai.proposals.editNote(resultID, selected: $0) }))
                if proposal.kind == .note {
                    TextField("批注", text: Binding(get: { note.draft }, set: { ai.proposals.editNote(resultID, text: $0) }), axis: .vertical)
                        .lineLimit(2...8).accessibilityIdentifier("aiNoteDraft-\(resultID)")
                }
                Button("保存所选") { Task { editor = await ai.proposals.saveNote(resultID) } }
                    .disabled(!note.selected || editor != nil).accessibilityIdentifier("saveAINote-\(resultID)")
            }
        }.disabled(saving)
    }
    private func coverContent(_ cover: AICoverReviewValue) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            Text("封面").font(.headline)
            let candidates = AIProposalRegistry.coverCandidates(result)
            if candidates.isEmpty { Text("没有图片候选").font(.subheadline) }
            AICoverCandidateGrid(items: candidates.map(coverItem)) { item in imagePreview = candidates.first { $0.id == item.id } }
            Button("以当前封面修改", systemImage: "wand.and.stars") { Task { try? await ai.proposals.useCurrentCover(resultID) } }
                .disabled(ai.proposals.liveMetadata[resultID]?.cover == nil || saving)
        }
    }
    private func coverItem(_ candidate: AICoverCandidate) -> AICoverCandidateItem {
        let owner = result.sessionID
        return .init(id: candidate.id, size: CGSize(width: candidate.width, height: candidate.height), source: candidate.origin.caption,
                     sourceURL: candidate.source.flatMap { URL(string: $0.url) }) { pixels in
            guard let data = try? await AIImageStore.shared.read(owner: owner, ref: candidate.id) else { return nil }
            return AIImageThumbnail.make(data, pixels: pixels)
        }
    }
    private func locationLabel(_ location: LibraryLocation?) -> String {
        guard let location, let name = shelfNames[location.shelfID] else { return String(localized: "书架不可用") }
        return location.path.isEmpty ? name : name + "/" + location.path
    }
    private func organizationContent(_ organization: AIOrganizationPlan) -> some View {
        VStack(alignment: .leading, spacing: LayoutTokens.control) {
            Text("整理方案").font(.headline)
            Text(verbatim: locationLabel(organization.scopeLocation))
            Picker("显示", selection: $fullTree) { Text("变更").tag(false); Text("全部").tag(true) }
                .pickerStyle(.segmented).accessibilityIdentifier("aiOrganizationMode")
            if fullTree {
                ForEach(organization.targetTree) { item in
                    HStack { Image(systemName: item.directory ? "folder" : "doc.text"); Text(verbatim: locationLabel(organization.displayLocation(item.parentRef)) + "/" + item.name) }.font(.subheadline)
                }
            }
            ForEach(organization.nodes) { node in
                VStack(alignment: .leading, spacing: LayoutTokens.compact) {
                    Text(verbatim: locationLabel(node.originalLocation)).font(.caption)
                    Text(verbatim: locationLabel(organization.displayLocation(node.parentRef)) + "/" + node.name).font(.caption)
                    TextField("名称", text: Binding(get: { node.name }, set: { ai.proposals.editOrganization(resultID, node: node.id, name: $0) }))
                    Toggle("包含", isOn: Binding(get: { node.included }, set: { ai.proposals.editOrganization(resultID, node: node.id, included: $0) }))
                    if let stage = node.result?.stage { Text(stage.label).font(.caption) }
                    if let conflict = node.conflict { Text(conflict.label).font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
                }.accessibilityIdentifier("aiOrganization-\(resultID)-\(node.id)")
                    .disabled(saving || node.result?.stage != nil && node.result?.stage != .notMoved)
            }
            let eligible = Set(organization.nodes.filter { $0.included && $0.conflict == nil && ($0.result?.stage == nil || $0.result?.stage == .notMoved) }.map(\.id))
            Button("执行剩余 \(eligible.count) 项") { confirmedNodes = eligible; confirmOrganization = true }
                .disabled(eligible.isEmpty || saving).accessibilityIdentifier("executeOrganization-\(resultID)")
                .confirmationDialog(String(localized: "执行剩余 \(confirmedNodes.count) 项"), isPresented: $confirmOrganization, titleVisibility: .visible) {
                    Button("执行") { let ids = confirmedNodes; Task { await ai.proposals.executeOrganization(resultID, confirmedIDs: ids) } }
                }
        }
    }
}

struct AIResultButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(LayoutTokens.content)
            .foregroundStyle(Color(uiColor: theme.ink))
            .background(Color(uiColor: configuration.isPressed ? theme.selected : theme.raised), in: .rect(cornerRadius: LayoutTokens.inputRadius))
            .overlay { RoundedRectangle(cornerRadius: LayoutTokens.inputRadius).strokeBorder(Color(uiColor: theme.border), lineWidth: 1) }
            .contentShape(.rect(cornerRadius: LayoutTokens.inputRadius))
    }
}
