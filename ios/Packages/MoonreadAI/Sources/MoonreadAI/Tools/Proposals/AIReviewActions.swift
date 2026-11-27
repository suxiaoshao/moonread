import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

public struct AINoteEditorRequest: Identifiable, Sendable {
    public let id: String
    public let sessionID: String
    public var edit: AnnotationEdit
    public init(id: String, sessionID: String, edit: AnnotationEdit) { self.id = id; self.sessionID = sessionID; self.edit = edit }
}


extension AIProposalRegistry {
    func openNewNoteReviews(_ suggestions: [AINoteSuggestion]) async {
        for suggestion in suggestions where reviews[suggestion.id] == nil {
            guard !Task.isCancelled else { return }
            await openResult(suggestion.result)
        }
    }

    public func editMetadata(_ id: String, kind: AIMetadataFieldKind, text: String? = nil, selected: Bool? = nil, tag: String? = nil) {
        guard var value = review(id), canEdit(value.sessionID), !inFlight.contains(id), case .metadata(var body) = value.body,
              let i = body.fields.firstIndex(where: { $0.kind == kind }) else { return }
        if let text { body.fields[i].draft = text.trimmingCharacters(in: .whitespacesAndNewlines); body.fields[i].edited = true; body.fields[i].selected = true }
        if let selected { body.fields[i].selected = selected }
        if let tag { if body.fields[i].selectedTags.contains(tag) { body.fields[i].selectedTags.remove(tag) } else { body.fields[i].selectedTags.insert(tag) } }
        value.body = .metadata(body); update(value); lastErrors[id] = nil; feedback[id] = nil
    }
    public func editNote(_ id: String, text: String? = nil, selected: Bool? = nil) {
        guard var value = review(id), canEdit(value.sessionID), !inFlight.contains(id), case .note(var body) = value.body, body.canSave else { return }
        if let text { body.draft = text }; if let selected { body.selected = selected }
        value.body = .note(body); update(value); lastErrors[id] = nil
    }
    public func editRename(_ id: String, text: String? = nil, selected: Bool? = nil) {
        guard var value = review(id), canEdit(value.sessionID), !inFlight.contains(id), case .metadata(var body) = value.body,
              var rename = body.rename else { return }
        if let text { rename.draft = text; rename.edited = true; rename.selected = true }
        if let selected { rename.selected = selected }
        body.rename = rename; value.body = .metadata(body); update(value)
        renameFeedback[id] = nil; renameErrors[id] = nil
    }
    public func selectedMetadataFields(_ id: String, _ body: AIMetadataReviewValue) -> [AIMetadataFieldReview] {
        body.fields.compactMap { field in
            var field = field; field.current = metadataCurrent(id, field: field)
            if field.kind == .tags {
                let current = Set(field.current.split(separator: "\n").map(String.init))
                let offered = Set(field.draft.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                field.selectedTags = field.selectedTags.intersection(current.symmetricDifference(offered))
                if field.tagsMode == .merge { field.selectedTags.formIntersection(offered) }
                return field.selectedTags.isEmpty ? nil : field
            }
            field.draft = field.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            return field.selected && field.draft != field.current ? field : nil
        }
    }
    public func metadataChangeCount(_ id: String, _ body: AIMetadataReviewValue) -> Int {
        selectedMetadataFields(id, body).count + (body.rename?.changes == true ? 1 : 0)
    }
    public func applyMetadata(_ ids: [String]) async {
        let captured = ids.compactMap(review).compactMap { value -> (AIReviewValue, AIMetadataReviewValue, [AIMetadataFieldReview])? in
            guard !inFlight.contains(value.id), case .metadata(let body) = value.body else { return nil }
            let fields = selectedMetadataFields(value.id, body)
            return fields.isEmpty && body.rename?.changes != true ? nil : (value, body, fields)
        }
        for (value, body, fields) in captured {
            let token: UUID
            do { token = try beginApplication(value.sessionID) } catch { lastErrors[value.id] = AIRequestError.message(error); continue }
            inFlight.insert(value.id); lastErrors[value.id] = nil; feedback[value.id] = nil
            renameFeedback[value.id] = nil; renameErrors[value.id] = nil
            defer { inFlight.remove(value.id); endApplication(value.sessionID, token) }
            // Independent business operations: either may succeed even when the other fails.
            if !fields.isEmpty {
                do {
                    let sha = try AIReadingReferences.parseBookReference(body.bookRef).sha, base = try await details(sha: sha).metadata
                    guard fields.allSatisfy({ Self.metadataValue($0.kind, base) == $0.current }) else {
                        liveMetadata[value.id] = base
                        throw AIToolError("stale_reference", message: String(localized: "当前资料已更新，请再次确认。"))
                    }
                    var edited = base
                    for field in fields {
                        switch field.kind {
                        case .author: edited.author = field.draft
                        case .synopsis: edited.synopsis = field.draft
                        case .tags:
                            let offered = Set(field.draft.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }); var tags = Set(base.tags)
                            for tag in field.selectedTags { if offered.contains(tag) { tags.insert(tag) } else if field.tagsMode == .replace { tags.remove(tag) } }
                            edited.tags = tags.sorted()
                        case .readingStatus:
                            switch field.draft { case "unread": edited.status = .unread; case "reading": edited.status = .reading; case "paused": edited.status = .paused; case "finished": edited.status = .finished; default: throw AIToolError("invalid_argument") }
                        }
                    }
                    try await host.saveMetadata(base, edited)
                    liveMetadata[value.id] = edited.normalizedForSaving; feedback[value.id] = String(localized: "资料已更新")
                    await refreshLive(value.id)
                } catch { lastErrors[value.id] = AIRequestError.message(error) }
            }
            if let rename = body.rename, rename.changes {
                do {
                    let refs = AIReadingReferences(access: host.reading)
                    guard let entry = try? await refs.file(rename.proposal.fileRef), entry.name == rename.proposal.originalName,
                          entry.metadata?.sha == (try refs.sha(body.bookRef)) else {
                        throw AIToolError("stale_reference", message: String(localized: "文件已变化，请重新生成重命名建议。"))
                    }
                    let name = try rename.proposal.filename(stem: rename.draft)
                    try await host.renameFile(entry, name, rename.proposal.source)
                    if var latest = review(value.id), case .metadata(var metadata) = latest.body {
                        metadata.rename?.currentName = name; metadata.title = (name as NSString).deletingPathExtension
                        latest.body = .metadata(metadata); update(latest)
                    }
                    renameFeedback[value.id] = String(localized: "文件已重命名")
                } catch { renameErrors[value.id] = AIRequestError.message(error) }
            }
        }
    }
    public func saveNote(_ id: String) async -> AINoteEditorRequest? {
        guard let value = review(id), case .note(let note) = value.body, case .note(let proposal) = value.result.body,
              note.selected, note.canSave, !inFlight.contains(id) else { return nil }
        let token: UUID
        do { token = try beginApplication(value.sessionID) } catch { lastErrors[id] = AIRequestError.message(error); return nil }
        inFlight.insert(id); lastErrors[id] = nil
        defer { inFlight.remove(id); endApplication(value.sessionID, token) }
        do {
            let admission = try await host.annotationAdmission()
            let reading = try await AIReadingReferences(access: host.reading).available(proposal.bookRef)
            if proposal.kind == .bookmark {
                _ = try await host.ensureBookmark(reading, proposal.startUtf8, admission)
                markNoteSaved(id, feedback: String(localized: "书签已保存"))
                return nil
            }
            var edit = try await host.prepareUserAnnotation(reading, proposal.startUtf8, proposal.endUtf8, admission)
            if !edit.marks.isEmpty || edit.baselines.values.contains(where: { !$0.isEmpty }) {
                edit.note = [edit.note, note.draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
                return .init(id: id, sessionID: value.sessionID, edit: edit)
            }
            _ = try await host.saveUserNote(edit, note.draft)
            markNoteSaved(id, feedback: String(localized: "批注已保存"))
        } catch is CancellationError {} catch { lastErrors[id] = AIRequestError.message(error) }
        return nil
    }
    private func markNoteSaved(_ id: String, feedback message: String) {
        feedback[id] = message
        guard var value = review(id), case .note(var note) = value.body else { return }
        note.status = .saved
        note.selected = false
        value.body = .note(note)
        update(value)
    }
    public func annotationHooks(_ result: AIResultValue) -> AIAnnotationCommitHooks {
        let id = result.id
        return .init(begin: {
            guard !self.inFlight.contains(id) else { throw AIToolError("busy") }
            let token = try self.beginApplication(result.sessionID); self.inFlight.insert(id)
            return .init(owner: result.sessionID, token: token)
        }, saved: { self.markNoteSaved(id, feedback: String(localized: "批注已保存")) },
        finish: { ticket in self.inFlight.remove(id); self.endApplication(ticket.owner, ticket.token) })
    }
    public func setCover(_ id: String, attachmentRef: String) async -> Bool {
        guard let value = review(id), case .cover(let body) = value.body, body.candidateAssetIDs.contains(attachmentRef), !inFlight.contains(id) else { return false }
        let token: UUID
        do { token = try beginApplication(value.sessionID) } catch { lastErrors[id] = AIRequestError.message(error); return false }
        inFlight.insert(id); lastErrors[id] = nil; feedback[id] = nil
        defer { inFlight.remove(id); endApplication(value.sessionID, token) }
        do {
            let sha = try AIReadingReferences.parseBookReference(body.bookRef).sha, base = try await details(sha: sha).metadata
            if let known = liveMetadata[id], known.cover != base.cover { liveMetadata[id] = base; throw AIToolError("stale_reference", message: String(localized: "当前封面已更新")) }
            let bytes = try await AIImageStore.shared.read(owner: value.sessionID, ref: attachmentRef), cover = try await host.makeCover(bytes)
            var edited = base; edited.cover = cover
            do { try await host.saveMetadata(base, edited) } catch { await host.discardCoverDraft(cover); throw error }
            liveMetadata[id] = edited; feedback[id] = String(localized: "封面已更新"); await refreshLive(id); return true
        } catch { lastErrors[id] = AIRequestError.message(error); return false }
    }
    public func useImage(_ result: AIResultValue, attachmentRef: String) async throws {
        guard canEdit(result.sessionID), Self.coverCandidates(result).contains(where: { $0.id == attachmentRef }) else { throw AIToolError("not_found") }
        _ = try await AIImageStore.shared.attachment(owner: result.sessionID, ref: attachmentRef)
        let origin = try await imageOrigin(owner: result.sessionID, ref: attachmentRef)
        try await attach(result.sessionID, .init(kind: .image, origin: "cover", title: String(localized: "封面参考"), attachmentRef: attachmentRef, imageOrigin: origin), nil)
    }
    public func useCurrentCover(_ id: String) async throws {
        guard let value = review(id), canEdit(value.sessionID), case .cover(let body) = value.body else { throw AIToolError("not_found") }
        let sha = try AIReadingReferences.parseBookReference(body.bookRef).sha
        guard let cover = try await details(sha: sha).metadata.cover else { throw AIToolError("not_found") }
        let bytes = try await host.coverBytes(cover), asset = try await AIImageStore.shared.prepareInput(bytes, owner: value.sessionID)
        try await attach(value.sessionID, .init(kind: .image, origin: "cover", title: String(localized: "当前封面"), attachmentRef: asset.attachment.id, imageOrigin: .currentCover), asset)
    }
    public func editOrganization(_ id: String, node: String, name: String? = nil, included: Bool? = nil) {
        guard let value = review(id), canEdit(value.sessionID), !inFlight.contains(id), case .organization(let plan) = value.body,
              let item = plan.nodes.first(where: { $0.id == node }) else { return }
        if let name { item.name = name }; if let included { item.included = included }
        plan.recomputeConflicts(); lastErrors[id] = nil
    }
    public func executeOrganization(_ id: String, confirmedIDs: Set<String>) async {
        guard let value = review(id), case .organization(let plan) = value.body, !inFlight.contains(id) else { return }
        let token: UUID
        do { token = try beginApplication(value.sessionID) } catch { lastErrors[id] = AIRequestError.message(error); return }
        inFlight.insert(id); lastErrors[id] = nil
        defer { inFlight.remove(id); endApplication(value.sessionID, token) }
        _ = await plan.executeRemaining(confirmedIDs: confirmedIDs)
    }
}
