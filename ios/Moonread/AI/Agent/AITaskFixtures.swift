#if DEBUG
import Foundation
import UIKit
import AISDKProvider
import AISDKProviderUtils

extension Notification.Name { static let aiTaskFixtureReady = Notification.Name("Moonread.aiTaskFixtureReady") }
extension AIService {
    /// Runs only in the existing isolated UUID UI-test library/store. No Agent request is started.
    func seedTaskFixturesIfReady() async throws {
        guard !fixtureSeeded, !fixtureSeeding, let session = await ReaderService.shared.testSession,
              ProcessInfo.processInfo.arguments.contains("--ui-test-ai-tasks") else { return }
        if conversations.contains(where: { $0.id == "ui-ai-notes-" + session }) { fixtureSeeded = true; return }
        fixtureSeeding = true; defer { fixtureSeeding = false }
        if ReaderSmokeFixture.enabled {
            try await installFixtureSession(AISessionValue(id: "smoke-task-" + session, title: "合成任务", kind: .statistics, listed: false), entries: [])
            fixtureSeeded = true; return
        }
        let reader = ReaderService.shared
        let entries = try await reader.aiLibraryBooks("builtin")
        guard var sample = entries.first(where: { $0.name == "月读 · 排版示例.txt" }),
              let sha = sample.metadata?.sha, (try? parseSha256(value: sha)) != nil,
              let first = entries.first(where: { $0.name == "AI 待整理甲.txt" }),
              let second = entries.first(where: { $0.name == "AI 待整理乙.txt" }) else { return }
        let reviewFixture = ProcessInfo.processInfo.arguments.contains("--ui-test-ai-review")
        if reviewFixture {
            // Fictional review metadata; the body remains the original WelcomeStory fixture.
            try await reader.renameLibraryItem(sample, name: "星灯渡口_林澄.txt", replace: false)
            guard let renamed = try await reader.aiLibraryBooks("builtin").first(where: { $0.name == "星灯渡口_林澄.txt" }) else { return }
            sample = renamed
        }
        let bookRef = AIReadingTools.bookRef(sha), fileRef = AIReadingTools.ref("f", sample.id)
        let origin = AITaskOrigin(bookSHA: nil, fileRef: fileRef)
        let base = try await reader.details(sha: sha).metadata
        var initial = base; initial.author = ""; initial.synopsis = "这是一份已有简介。"; initial.tags = ["已有标签"]
        try await reader.saveMetadata(base: base, edited: initial)
        if reviewFixture {
            initial.author = "林澄"; initial.tags = ["单元故事", "虚构世界", "友情", "成长"]
            initial.synopsis = String(repeating: "这是一段用于界面验收的合成简介，验证长文本、标签和底部操作的布局。", count: 5)
            try await reader.saveMetadata(base: try await reader.details(sha: sha).metadata, edited: initial)
        }
        let metadata = AISessionValue(id: "ui-ai-metadata-" + session, title: "资料建议", origin: origin, kind: .metadata, listed: false)
        var mp = AIMetadataProposal(proposalRef: "ui-metadata-" + session, bookRef: bookRef, author: reviewFixture ? "林澄" : "示例作者", synopsis: reviewFixture ? "新的合成简介用于预览最终资料效果。切换原内容后应恢复原有简介，编辑后的建议也应保留。" : "新的简介建议", tags: reviewFixture ? ["探索", "冒险", "温暖", "奇想"] : ["温柔", "日常"], tagsMode: .merge)
        if reviewFixture {
            mp.rename = .init(fileRef: fileRef, name: "星灯渡口", originalName: sample.name, source: try await reader.aiFileSnapshot(sample.location))
            if ProcessInfo.processInfo.arguments.contains("--ui-test-ai-review-replace") {
                mp.tagsMode = .replace; mp.tags = ["单元故事", "虚构世界", "友情", "探索", "冒险", "温暖", "奇想"]
            }
        }
        try await installFixtureSession(metadata, entries: try fixtureTimeline([try fixtureResult(.metadata(mp), name: "propose_book_metadata")], purpose: AITaskKind.metadata.purpose))
        let cover = AISessionValue(id: "ui-ai-cover-" + session, title: "封面", origin: origin, kind: .cover(mode: .find), listed: false)
        await AIImageStore.shared.bind(cover.id, repository: try await fixtureRepository(cover))
        var coverSnapshots: [AIProposalSnapshot] = []
        for (index, color) in [UIColor.systemIndigo, .systemTeal].enumerated() {
            let bytes = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120)).pngData { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 120)) }
            let image = try await AIImageStore.shared.save(bytes, owner: cover.id)
            let source = AIWebSource.make(title: "离线来源示例", url: "https://example.com/cover-\(index).png")
            let cp = AICoverProposal(proposalRef: "ui-cover-\(index)-" + session, bookRef: bookRef, attachment: image, origin: source.map(AIImageOrigin.web) ?? .unknown)
            coverSnapshots.append(.cover(cp))
        }
        let links = coverSnapshots.compactMap { if case .cover(let candidate) = $0 { candidate.origin.webSource } else { nil } } + [AIWebSource.make(title: "只有网页的来源示例", url: "https://example.com/book")!]
        let findResult = AIFindCoverResult(bookRef: bookRef, candidates: coverSnapshots.compactMap { if case .cover(let candidate) = $0 { candidate } else { nil } }, answer: "找到封面候选及相关网页，请检查来源。", sources: links)
        try await installFixtureSession(cover, entries: try fixtureTimeline([try fixtureOutput(AIToolResponse(data: findResult), name: "find_cover")], purpose: AITaskKind.cover(mode: .find).purpose))
        let scopeRef = AIReadingTools.scopeRef(shelfID: "builtin", path: "")
        let organization = AISessionValue(id: "ui-ai-organization-" + session, title: "整理", origin: .init(scopeRef: scopeRef), kind: .organization, listed: false)
        let op = AIOrganizationProposal(proposalRef: "ui-organization-" + session, previewRef: "ui-preview-" + session,
            input: .init(scopeRef: scopeRef, folders: [.init(temporaryRef: "new-folder", parentRef: scopeRef, name: "整理后的小说")],
                placements: [.init(fileRef: AIReadingTools.ref("f", first.id), parentRef: "new-folder", name: nil), .init(fileRef: AIReadingTools.ref("f", second.id), parentRef: scopeRef, name: "AI 已有名称.txt"), .init(fileRef: fileRef, parentRef: scopeRef, name: "排版示例 · 新名称.txt")]))
        _ = try await fixtureRepository(organization)
        _ = try await proposals.prepare(.organization(op), owner: organization.id)
        try await installFixtureSession(organization, entries: try fixtureTimeline([try fixtureResult(.organization(op), name: "propose_library_organization")], purpose: AITaskKind.organization.purpose))
        let notes = AISessionValue(id: "ui-ai-notes-" + session, title: "笔记建议", origin: nil, kind: .statistics, listed: true)
        let id = try await reader.aiBookID(sha: sha), range = try await reader.paragraph(id, at: 0)
        let edit = try await reader.prepareUserAnnotation(id, start: range.startUtf8, end: range.endUtf8)
        _ = try await reader.saveUserNote(edit, text: "已有评论，需在原编辑页确认。")
        let retryFixture = ProcessInfo.processInfo.arguments.contains("--ui-test-ai-note-retry")
        // createSampleBook separates its header and first body paragraph with two newlines.
        // end + 1 is the empty separator, not a valid annotation range.
        let noteRange = retryFixture ? try await reader.paragraph(id, at: range.endUtf8 + 2) : range
        if retryFixture {
            guard noteRange.startUtf8 < noteRange.endUtf8,
                  !noteRange.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  noteRange.startUtf8 >= range.endUtf8 else { throw AIToolError("invalid_argument", message: "Retry fixture requires a nonempty disjoint paragraph") }
            _ = try await reader.ensureBookmark(id, at: range.startUtf8)
        }
        let np = AINoteProposal(proposalRef: "ui-note-" + session, bookRef: bookRef, kind: .note, startUtf8: noteRange.startUtf8, endUtf8: noteRange.endUtf8, note: "AI 的评论建议")
        let bp = AINoteProposal(proposalRef: "ui-bookmark-" + session, bookRef: bookRef, kind: .bookmark, startUtf8: range.startUtf8, endUtf8: range.startUtf8, note: "")
        try await installFixtureSession(notes, entries: try fixtureTimeline([try fixtureResult(.notes(np), name: "propose_note", sequence: 0), try fixtureResult(.notes(bp), name: "propose_bookmark", sequence: 1)], purpose: "笔记建议"))
        // A long listed conversation whose only "灯塔" message lies far above the newest page.
        var history: [AIAgentEntry] = []
        for index in 0..<60 {
            let turn = "long-\(index)", question = index == 3 ? "第\(index)问：灯塔在哪里？" : "第\(index)问"
            history.append(.init(sequence: history.count, turn: turn, provider: "fixture", model: "fixture", message: .object(["role": .string("user"), "content": .object(["value": .string(question)])]), userText: question))
            history.append(.init(sequence: history.count, turn: turn, provider: "fixture", model: "fixture", message: .object(["role": .string("assistant"), "content": .object(["value": .string("第\(index)答")])]), outcome: .completed))
        }
        try await installFixtureSession(AISessionValue(id: "ui-ai-long-" + session, title: "长对话", listed: true), entries: history)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-ai-expansion") {
            var entries = Array(history.prefix(30))
            let parts: [JSONValue] = (0..<3).map { .object(["type": .string("tool-call"), "toolCallId": .string("expand-call\($0)"), "toolName": .string("read_book"), "input": .object([:])]) } + [
                .object(["type": .string("reasoning"), "text": .string("")]),
                .object(["type": .string("text"), "text": .string("接着核对内容。")]),
                .object(["type": .string("reasoning"), "text": .string("查看资料。\n" + String(repeating: "这是合成思考内容，用于验证展开与滚动。", count: 8))])
            ]
            entries.append(.init(sequence: entries.count, turn: "expand", provider: "fixture", model: "fixture",
                message: .object(["role": .string("assistant"), "content": .object(["parts": .array(parts)])]), outcome: .stopped))
            try await installFixtureSession(.init(id: "ui-ai-expansion-" + session, title: "展开验证", listed: true), entries: entries)
        }
        fixtureSeeded = true
    }
    private func fixtureTimeline(_ results: [AIAgentEntry], purpose: String) throws -> [AIAgentEntry] {
        var entries: [AIAgentEntry] = []
        for (index, original) in results.enumerated() {
            let turn = "fixture-\(index)"
            if index == 0 {
                entries.append(.init(sequence: entries.count, turn: turn, provider: "fixture", model: "fixture", message: .object(["role": .string("user"), "content": .object(["value": .string(purpose)])]), userText: purpose))
            }
            let result = original.message.object["content"]?.array?.first?.object ?? [:]
            let call = JSONValue.object(["type": .string("tool-call"), "toolCallId": result["toolCallId"] ?? .null, "toolName": result["toolName"] ?? .null, "input": .object([:])])
            let assistant = JSONValue.object(["role": .string("assistant"), "content": .object(["parts": .array([call])])])
            entries.append(.init(sequence: entries.count, turn: turn, provider: "fixture", model: "fixture", message: assistant))
            var tool = original; tool.sequence = entries.count; tool.turn = turn; entries.append(tool)
            entries.append(.init(sequence: entries.count, step: 1, turn: turn, provider: "fixture", model: "fixture", message: .object(["role": .string("assistant"), "content": .object(["value": .string("请查看建议后决定。")])]), outcome: .completed))
        }
        return entries
    }
    private func fixtureResult(_ snapshot: AIProposalSnapshot, name: String, sequence: Int = 0) throws -> AIAgentEntry {
        try fixtureOutput(AIToolResponse(data: snapshot), name: name, sequence: sequence)
    }
    private func fixtureOutput<T: Encodable>(_ output: T, name: String, sequence: Int = 0) throws -> AIAgentEntry {
        .init(sequence: sequence, turn: "fixture-\(sequence)", provider: "fixture", model: "fixture",
            message: .object(["role": .string("tool"), "content": .array([.object(["type": .string("tool-result"), "toolCallId": .string("fixture-call-\(sequence)"), "toolName": .string(name), "output": .object(["type": .string("json"), "value": try AIAgentEntry.json(output)])])])]))
    }
}
#endif
