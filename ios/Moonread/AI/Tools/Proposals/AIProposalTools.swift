import Foundation
import Observation
import AISDKProvider

struct AIMetadataProposalInput: AIReadingInput {
    var bookRef: String
    var author: String?
    var synopsis: String?
    var tags: [String]?
    var tagsMode: AITagsMode?
    var readingStatus: AIReadingStatus?
    var sourceRefs: [String]?
    var rename: AIMetadataRenameInput?
    func validate() throws {
        guard author != nil || synopsis != nil || tags != nil || readingStatus != nil || rename != nil else { throw AIToolError("invalid_argument") }
    }
    static var constraints: [String: [String: JSONValue]] {
        ["rename": ["type": .string("object"), "properties": .object(["fileRef": .object(["type": .string("string")]), "name": .object(["type": .string("string")])]), "required": .array([.string("fileRef"), .string("name")]), "additionalProperties": .bool(false)],
         "tagsMode": ["type": .string("string"), "enum": .array(AITagsMode.allCases.map { .string($0.rawValue) })],
         "readingStatus": ["type": .string("string"), "enum": .array(AIReadingStatus.allCases.map { .string($0.rawValue) })],
         "tags": ["type": .string("array"), "items": .object(["type": .string("string")])],
         "sourceRefs": ["type": .string("array"), "items": .object(["type": .string("string")])]]
    }
}
struct AINoteProposalInput: AIReadingInput {
    var bookRef: String
    var startUtf8: UInt64
    var endUtf8: UInt64
    var note: String
    var markRef: String?
    func validate() throws { guard startUtf8 < endUtf8, note.utf8.count <= 64 * 1024 else { throw AIToolError("invalid_argument") } }
}
struct AIBookmarkProposalInput: AIReadingInput { var bookRef: String; var offsetUtf8: UInt64 }
struct AICoverProposalInput: AIReadingInput { var bookRef: String; var attachmentRef: String }

struct AIFindCoverInput: AIReadingInput { var bookRef: String; var query: String? }
struct AIFindCoverResult: Codable, Sendable {
    var bookRef: String
    var candidates: [AICoverProposal]
    var answer: String?
    var sources: [AIWebSource] = []
}
/// A source verified against this session's committed tool results.
enum AIResolvedSource: Sendable, Identifiable {
    case text(bookRef: String, startUtf8: UInt64, endUtf8: UInt64, title: String)
    case web(AIWebSource)
    var id: String {
        switch self {
        case .text(let book, let start, let end, _): AIReadingTools.ref("source", "\(book):\(start):\(end)")
        case .web(let source): source.sourceRef
        }
    }
}
@MainActor @Observable final class AIProposalRegistry {
    @ObservationIgnored var history: @MainActor (String) async throws -> [AIAgentEntry] = { _ in [] }
    @ObservationIgnored var canEdit: @MainActor (String) -> Bool = { _ in false }
    @ObservationIgnored var beginApplication: @MainActor (String) throws -> UUID = { _ in throw AIError.storage }
    @ObservationIgnored var endApplication: @MainActor (String, UUID) -> Void = { _, _ in }
    @ObservationIgnored var attach: @MainActor (String, AIReadingAttachment, AIStagedAsset?) async throws -> Void = { _, _, _ in }
    private(set) var reviews: [String: AIReviewValue] = [:]
    var inFlight: Set<String> = []
    var lastErrors: [String: String] = [:]
    var feedback: [String: String] = [:]
    var renameFeedback: [String: String] = [:]
    var renameErrors: [String: String] = [:]
    var liveMetadata: [String: BookMetadata] = [:]
    let reader: AppDataService
    init(reader: AppDataService = .shared) { self.reader = reader }
    func remove(_ owner: String) { closeSession(owner) }
    func closeSession(_ owner: String) {
        for id in reviews.values.filter({ $0.sessionID == owner }).map(\.id) { closeResult(id) }
    }
    func closeResult(_ id: String) { reviews[id] = nil; lastErrors[id] = nil; feedback[id] = nil; liveMetadata[id] = nil; renameFeedback[id] = nil; renameErrors[id] = nil }
    func review(_ id: String) -> AIReviewValue? { reviews[id] }
    func update(_ value: AIReviewValue) { guard reviews[value.id] != nil else { return }; reviews[value.id] = value }
    func openResult(_ result: AIResultValue) async {
        guard canEdit(result.sessionID) else { return }
        closeResult(result.id)
        do {
            let value = try await initialReview(result)
            try Task.checkCancellation()
            guard canEdit(result.sessionID) else { return }
            reviews[result.id] = value
            await refreshLive(result.id)
        } catch is CancellationError {} catch { lastErrors[result.id] = AIRequestError.message(error) }
    }
    static func coverCandidates(_ result: AIResultValue) -> [AICoverCandidate] {
        let proposals: [AICoverProposal]
        switch result.body { case .cover(let p): proposals = [p]; case .findCover(let p): proposals = p.candidates; default: proposals = [] }
        var order: [String] = [], candidates: [String: AICoverCandidate] = [:]
        for proposal in proposals {
            let asset = proposal.attachment.id
            if candidates[asset] == nil { order.append(asset) }
            if candidates[asset]?.origin.isKnown == true { continue }
            candidates[asset] = .init(proposalRef: proposal.proposalRef, attachment: proposal.attachment, origin: proposal.origin)
        }
        return order.compactMap { candidates[$0] }
    }
    func refreshLive(_ id: String) async {
        guard let result = review(id)?.result else { return }
        let ref: String
        switch result.body {
        case .metadata(let p): ref = p.bookRef
        case .note(let p): ref = p.bookRef
        case .cover(let p): ref = p.bookRef
        case .findCover(let p): ref = p.bookRef
        case .organization: return
        }
        do { let sha = try await AIReadingReferences(reader: reader).sha(ref); liveMetadata[id] = try await reader.details(sha: sha).metadata }
        catch { /* Optional refresh does not turn an actual business save into failure. */ }
    }
    func metadataCurrent(_ id: String, field: AIMetadataFieldReview) -> String { liveMetadata[id].map { Self.metadataValue(field.kind, $0) } ?? field.current }
    static func metadataValue(_ kind: AIMetadataFieldKind, _ value: BookMetadata) -> String {
        switch kind { case .author: value.author; case .synopsis: value.synopsis; case .tags: value.tags.sorted().joined(separator: "\n"); case .readingStatus: String(describing: value.status) }
    }
    private func initialReview(_ result: AIResultValue) async throws -> AIReviewValue {
        let references = AIReadingReferences(reader: reader)
        let body: AIReviewValue.Body
        switch result.body {
        case .metadata(let p):
            let details = try await reader.details(sha: references.sha(p.bookRef)), mode = p.tagsMode ?? .merge
            let tags = p.tags.map { Set($0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }) }
            let suggested = tags.map { mode == .merge ? Set(details.metadata.tags).union($0).sorted() : $0.sorted() }
            let offered: [(AIMetadataFieldKind, String?)] = [(.author, p.author?.trimmingCharacters(in: .whitespacesAndNewlines)), (.synopsis, p.synopsis?.trimmingCharacters(in: .whitespacesAndNewlines)), (.tags, suggested?.joined(separator: "\n")), (.readingStatus, p.readingStatus?.rawValue)]
            let fields = offered.compactMap { kind, suggestion -> AIMetadataFieldReview? in
                guard let suggestion else { return nil }
                let current = Self.metadataValue(kind, details.metadata)
                let tags = Set(suggestion.split(separator: "\n").map(String.init)).subtracting(current.split(separator: "\n").map(String.init))
                return .init(kind: kind, current: current, draft: suggestion, selected: current != suggestion,
                    selectedTags: kind == .tags ? tags : [], tagsMode: mode, sourceRefs: p.sourceRefs ?? [])
            }
            var rename: AIMetadataRenameReview?
            if let proposed = p.rename {
                let entry = try? await references.file(proposed.fileRef)
                rename = .init(proposal: proposed, draft: proposed.name, selected: entry?.name == proposed.originalName,
                               currentName: entry?.name ?? proposed.originalName,
                               unavailable: entry?.name == proposed.originalName ? nil : String(localized: "文件已变化，请重新生成重命名建议。"))
            }
            body = .metadata(.init(bookRef: p.bookRef, title: details.book?.title ?? String(localized: "小说信息"), fields: fields, rename: rename))
        case .note(let p):
            var value = AINoteReviewValue(draft: p.note, selected: true, excerpt: "", chapter: nil, existingBookmark: false, unavailable: nil)
            do {
                let reading = try await references.available(p.bookRef)
                let range = p.kind == .bookmark ? try await reader.paragraph(reading, at: p.startUtf8) : try await reader.textRange(reading, start: p.startUtf8, end: p.endUtf8)
                value.excerpt = String(range.text.prefix(160)); value.chapter = try await reader.details(bookID: reading).currentChapter
                if p.kind == .bookmark {
                    let marks = try await reader.aiMarks(sha: references.sha(p.bookRef))
                    value.existingBookmark = marks.values.contains { $0.contains { $0.bookmark && $0.content?.start == p.startUtf8 } }
                    if value.existingBookmark { value.selected = false }
                }
            } catch { value.unavailable = AIRequestError.message(error); value.selected = false }
            body = .note(value)
        case .cover(let p): body = .cover(.init(bookRef: p.bookRef, candidateAssetIDs: [p.attachment.id]))
        case .findCover(let p): body = .cover(.init(bookRef: p.bookRef, candidateAssetIDs: Self.coverCandidates(result).map(\.id)))
        case .organization(let p):
            let location = try await references.location(p.input.scopeRef)
            let plan = AIOrganizationPlan(proposal: p, scope: location, reader: reader)
            try await plan.prepare()
            body = .organization(plan)
        }
        return .init(id: result.id, sessionID: result.sessionID, result: result, body: body)
    }
    func metadataProposal(_ input: AIMetadataProposalInput) async throws -> AIMetadataProposal {
        try input.validate()
        let references = AIReadingReferences(reader: reader)
        var rename: AIMetadataRenameProposal?
        if let proposed = input.rename {
            let sha = try await references.sha(input.bookRef), entry = try await references.file(proposed.fileRef)
            guard !entry.directory, entry.metadata?.sha == sha else { throw AIToolError("permission_denied", field: "rename.fileRef") }
            let source = try await reader.aiFileSnapshot(entry.location)
            let value = AIMetadataRenameProposal(fileRef: proposed.fileRef, name: proposed.name.trimmingCharacters(in: .whitespacesAndNewlines), originalName: entry.name, source: source)
            _ = try value.filename(stem: value.name)
            rename = value
        }
        return .init(proposalRef: UUID().uuidString, bookRef: input.bookRef, author: input.author, synopsis: input.synopsis,
                     tags: input.tags, tagsMode: input.tagsMode, readingStatus: input.readingStatus, sourceRefs: input.sourceRefs, rename: rename)
    }
    func prepare(_ snapshot: AIProposalSnapshot, owner: String) async throws -> AIToolResponse<AIProposalSnapshot> {
        let references = AIReadingReferences(reader: reader)
        switch snapshot {
        case .metadata(let proposal):
            _ = try await reader.details(sha: references.sha(proposal.bookRef))
            if let refs = proposal.sourceRefs, !refs.isEmpty {
                let produced = try await resolveSources(refs, owner: owner)
                guard Set(produced.map(\.id)) == Set(refs) else { throw AIToolError("stale_reference", field: "sourceRefs") }
            }
        case .notes(let proposal):
            let id = try await references.available(proposal.bookRef)
            if proposal.kind == .bookmark { _ = try await reader.paragraph(id, at: proposal.startUtf8) }
            else { _ = try await reader.textRange(id, start: proposal.startUtf8, end: proposal.endUtf8) }
        case .cover(let proposal): _ = try await AIImageStore.shared.attachment(owner: owner, ref: proposal.attachment.id)
        case .organization(let proposal):
            try proposal.input.validate()
            let location = try await references.location(proposal.input.scopeRef)
            let plan = AIOrganizationPlan(proposal: proposal, scope: location, reader: reader)
            try await plan.prepare()
        }
        return .init(data: snapshot)
    }
    func resolveSources(_ refs: [String], owner: String) async throws -> [AIResolvedSource] {
        var produced: [String: AIResolvedSource] = [:]
        for entry in try await history(owner) where entry.message.object["role"] == .string("tool") {
            for part in entry.message.object["content"]?.array ?? [] {
                let object = part.object
                guard ["read", "rg", "get_marks", "get_mark", "web_search", "find_cover"].contains(object["toolName"]?.string ?? "") else { continue }
                let output = object["output"]?.object["value"] ?? object["output"] ?? .null
                let tool = object["toolName"]?.string ?? "", status = output.object["status"]?.string
                guard status == "ok" || (tool == "rg" && status == "partial") else { continue }
                for source in AIWebSource.committed(in: output, tool: object["toolName"]?.string ?? "") { produced[source.sourceRef] = .web(source) }
                let data = output.object["data"] ?? .null
                let values = [data] + (output.object["sources"]?.array ?? []) + (data.object["sources"]?.array ?? []) + (data.object["hits"]?.array ?? []) + (data.object["items"]?.array ?? [])
                for value in values {
                    let source = value.object
                    guard let ref = source["sourceRef"]?.string else { continue }
                    if let book = source["bookRef"]?.string ?? data.object["bookRef"]?.string,
                       let start = source["range"]?.object["startUtf8"]?.int, let end = source["range"]?.object["endUtf8"]?.int,
                       (try? AIReadingReferences.parseBookReference(book)) != nil, start >= 0, end > start,
                       ref == AIReadingTools.ref("source", "\(book):\(start):\(end)") { produced[ref] = .text(bookRef: book, startUtf8: UInt64(start), endUtf8: UInt64(end), title: source["title"]?.string ?? source["chapterTitle"]?.string ?? "") }
                }
            }
        }
        var seen = Set<String>()
        return refs.compactMap { produced[$0] }.filter { seen.insert($0.id).inserted }
    }
    func imageOrigin(owner: String, ref: String) async throws -> AIImageOrigin {
        for entry in try await history(owner) {
            if entry.message.object["role"] == .string("user") {
                for attachment in entry.readingAttachments where attachment.kind == .image && attachment.attachmentRef == ref {
                    if let origin = attachment.imageOrigin, origin.isKnown { return origin }
                }
            }
            guard entry.message.object["role"] == .string("tool") else { continue }
            for part in entry.message.object["content"]?.array ?? [] {
                let object = part.object
                let output = object["output"]?.object["value"] ?? object["output"] ?? .null
                guard output.object["status"] == .string("ok"), let bytes = try? JSONEncoder().encode(output) else { continue }
                if object["toolName"] == .string("generate_image"),
                   let result = try? JSONDecoder().decode(AINativeResult.self, from: bytes),
                   result.data.attachments?.contains(where: { $0.attachmentRef == ref }) == true { return .generated }
                if object["toolName"] == .string("find_cover"),
                   let result = try? JSONDecoder().decode(AIToolResponse<AIFindCoverResult>.self, from: bytes),
                   let candidate = result.data.candidates.first(where: { $0.attachment.attachmentRef == ref }),
                   let source = candidate.origin.webSource,
                   result.data.sources.contains(where: { $0.isValid && $0.sourceRef == source.sourceRef && $0.url == source.url }) { return .web(source) }
            }
        }
        return .unknown
    }
    func definitions(owner: String, providers: AIConnectionService, makeTransport: @escaping @Sendable () -> AITransport) -> [AIAgentTool] {
        let references = AIReadingReferences(reader: reader)
        return [
            .init(name: "find_cover", description: "Search with the configured search service for a cover. Fetch only returned sources and one level of images explicitly declared by those pages. Resolve relative image URLs without guessing paths or executing scripts; filter decoded cover candidates by dimensions. Web citations without images are a valid result. No cover is applied.", input: AIFindCoverInput.self,
                enabled: { providers.purposeSelection(.search) != nil }, execute: { input in
                    let sha = try await references.sha(input.bookRef)
                    let details = try await self.reader.details(sha: sha)
                    let title = details.book?.title ?? input.bookRef
                    let native = try await AINativeTools(providers: providers, owner: owner, makeTransport: makeTransport).search(.init(query: input.query ?? (title + " " + details.metadata.author + " 小说")))
                    let fetcher = await AICoverImageFetcher(availability: providers.availability)
                    let request = try await providers.trackNativeRequest(connectionID: native.data.connectionID, cancel: { fetcher.cancel() })
                    do {
                        let report = try await fetcher.candidates(sources: native.sources, title: title, bookRef: input.bookRef,
                            save: { try await AIImageStore.shared.save($0, owner: owner) },
                            discard: { await AIImageStore.shared.discardStaged(owner: owner, refs: $0) })
                        await providers.finishNativeRequest(request)
                        return AIToolResponse(data: AIFindCoverResult(bookRef: input.bookRef, candidates: report.candidates, answer: native.data.answer, sources: native.sources))
                    } catch {
                        await providers.finishNativeRequest(request); throw error
                    }
                }),
            .init(name: "propose_library_organization", description: "Propose folders and placements for user review. scopeRef declares this plan's scope; reading attachments are context, not a file allowlist. No deletion or overwrite. parentRef is an existing folder reference within the plan scope or a temporaryRef from this plan. Only explicit user application executes the reviewed plan.", input: AIOrganizationInput.self,
                execute: { input in
                    try await self.prepare(.organization(.init(proposalRef: UUID().uuidString, previewRef: UUID().uuidString, input: input)), owner: owner)
                }),
            .init(name: "propose_book_metadata", description: "Propose only the requested metadata fields for user review. Attribute authors only from explicit filename attribution, existing metadata, front matter, body attribution or cited web sources; never infer authorship from characters or style. Extract or compose synopsis and tags as requested. Tag removals, replacements and clears require explicit user request. Never infer reading status; include it only when the user explicitly requested a status change. Omitted fields are unchanged, empty fields clear only by explicit request. Tags merge by default. Optionally propose rename {fileRef,name}: name is a filename stem and the original extension is retained. Only propose renaming to remove obvious author/site/format/completion noise from a filename, or on explicit user request. Do not rewrite, translate or infer the book title from prose. fileRef must belong to bookRef. User confirmation renames that real file without replacement, independently of metadata saving.", input: AIMetadataProposalInput.self, execute: { input in
                try await self.prepare(.metadata(self.metadataProposal(input)), owner: owner)
            }),
            .init(name: "propose_note", description: "Propose an annotation using tool-returned UTF-8 boundaries. Existing notes/conflicts are handled by the app editor; never overwrite them.", input: AINoteProposalInput.self, confirmation: { try await references.confirmText([$0.bookRef]) }, execute: { input in
                try await self.prepare(.notes(.init(proposalRef: UUID().uuidString, bookRef: input.bookRef, kind: .note, startUtf8: input.startUtf8, endUtf8: input.endUtf8, note: input.note, markRef: input.markRef)), owner: owner)
            }),
            .init(name: "propose_bookmark", description: "Propose a bookmark at a valid tool-returned UTF-8 position. Applying preserves an existing bookmark.", input: AIBookmarkProposalInput.self, confirmation: { try await references.confirmText([$0.bookRef]) }, execute: { input in
                try await self.prepare(.notes(.init(proposalRef: UUID().uuidString, bookRef: input.bookRef, kind: .bookmark, startUtf8: input.offsetUtf8, endUtf8: input.offsetUtf8, note: "")), owner: owner)
            }),
            .init(name: "propose_cover", description: "Propose an image attachment from this session as a cover for user review. For a generated cover, call generate_image first and pass its returned attachmentRef here. Does not apply the cover.", input: AICoverProposalInput.self, execute: { input in
                let image = try await AIImageStore.shared.attachment(owner: owner, ref: input.attachmentRef)
                return try await self.prepare(.cover(.init(proposalRef: UUID().uuidString, bookRef: input.bookRef, attachment: image, origin: try await self.imageOrigin(owner: owner, ref: image.id))), owner: owner)
            })
        ]
    }
}
extension AIReadingTools {
    static func scopeRef(shelfID: String, path: String) -> String { path.isEmpty ? ref("s", shelfID) : ref("d", shelfID + "/" + path) }
}
