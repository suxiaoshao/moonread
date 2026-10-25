import Foundation
import Observation
import AISDKProvider
import AISDKProviderUtils

@MainActor @Observable final class AIConversation {
    nonisolated let id: String
    var title: String
    let context: AIContext
    var updated: Date
    var connectionID: String? { head.selection?.connectionID }
    var modelID: String? { head.selection?.modelID }
    var thinking: String? { head.selection?.thinking }
    var draft = ""
    var readingDraft: [AIReadingAttachment] = []
    var readingDraftInitialized = false
    private(set) var entries: [AIAgentEntry] = []
    var head = AIAgentHead()
    var partialText = ""
    var confirmations: [AIAgentConfirmation] = []
    var activity = AIAgentActivity(status: .idle)
    var hasEarlier = false
    /// The loaded entries are a window that ends before the newest message.
    var hasLater = false
    var historyLoaded = false
    @ObservationIgnored private var entryResults: [String: [AIResultValue]] = [:]
    // Live output belongs after the newest message, so a window above it omits it.
    @ObservationIgnored private var committedTurns: [AIConversationTurn] = []
    var turns: [AIConversationTurn] {
        _ = entries
        return hasLater ? committedTurns : AIConversationTurn.live(committedTurns, head: head, parts: activity.parts, step: activity.step, reasoningActive: activity.reasoningActive, running: running)
    }
    var processExpansion: [String: Bool] = [:]
    var processItemExpansion = Set<AIProcessExpansionID>()
    @ObservationIgnored var presentedActiveTurns = Set<String>()
    @ObservationIgnored var messageTurnCache: [String: AIMessageTurnCache] = [:]
    @ObservationIgnored var messageVersions: [String: AIMessageRow] = [:]
    @ObservationIgnored var messageRevision = 0
    @ObservationIgnored let streamDisplay = AIStreamDisplayBuffer()
    @ObservationIgnored let nativeMarkdown = AINativeMarkdownCache()
    @ObservationIgnored var messageHeights: [AIMessageHeightKey: CGFloat] = [:]
    var running = false
    /// The latest visible message, from the newest page that connecting already loads.
    var preview: String {
        if running, !partialText.isEmpty { return Self.plain(partialText) }
        for entry in entries.reversed() {
            let object = entry.message.object
            switch object["role"]?.string {
            case "assistant":
                let parts = object["content"]?.object["parts"]?.array ?? []
                let text = parts.filter { $0.object["type"]?.string == "text" }.compactMap { $0.object["text"]?.string }.joined()
                    + (object["content"]?.object["value"]?.string ?? "")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Self.plain(text) }
            case "user":
                return Self.plain(entry.userText ?? AIConversationTurn.text(object["content"]))
            default: break
            }
        }
        return ""
    }
    private static func plain(_ markdown: String) -> String {
        // A one-line list preview, not a Markdown rendering.
        let symbols = CharacterSet(charactersIn: "#*_`>|")
        return markdown.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: symbols).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }.joined(separator: " ").replacingOccurrences(of: "**", with: "")
    }
    /// Committed deltas replace only their identity; pages cannot overwrite a newer live delta.
    /// A window above the newest message takes no new live entries; they load with later pages.
    func mergeEntries(_ incoming: [AIAgentEntry], updatingExisting: Bool = true, insertingNew: Bool = true) {
        defer { committedTurns = AIConversationTurn.committed(entries, resultsByEntry: entryResults) }
        for entry in incoming {
            if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                if updatingExisting {
                    if entries[index].message != entry.message { decodeResults(entry) }
                    entries[index] = entry
                }
            } else if insertingNew {
                decodeResults(entry)
                if let index = entries.firstIndex(where: { $0.sequence > entry.sequence }) { entries.insert(entry, at: index) }
                else { entries.append(entry) }
            }
        }
    }
    /// Replaces the loaded history with one contiguous page window.
    func showWindow(_ page: [AIAgentEntry], newestSequence: Int) {
        entries = []; entryResults = [:]
        messageTurnCache = [:]; messageVersions = [:]; messageHeights = [:]; nativeMarkdown.reset()
        mergeEntries(page, updatingExisting: false)
        hasEarlier = (entries.first?.sequence ?? 0) > 0
        hasLater = (entries.last?.sequence ?? -1) < newestSequence
    }
    private func decodeResults(_ entry: AIAgentEntry) {
        let values = AICommittedResultDecoder.results(entry, sessionID: id)
        entryResults[entry.id] = values.isEmpty ? nil : values
    }
    var origin: AITaskOrigin?
    var kind: AITaskKind?
    var listed: Bool
    var deleting = false
    var persisted = true
    var sendTask: Task<Void, Never>?
    var submitting: Bool { sendTask != nil }
    init(_ value: AISessionValue) {
        id = value.id; title = value.title; context = value.context; updated = value.updated
        origin = value.origin; kind = value.kind; listed = value.listed
    }
}

extension Notification.Name { static let aiActionFailed = Notification.Name("Moonread.aiActionFailed") }

struct AIActionNotice: Identifiable {
    let id = UUID()
    let sessionID: String?
    let message: String
}

struct AIConversationAnchor: Hashable {
    let sequence: Int
    let turn: String
}

struct AIConversationSearchHit: Identifiable {
    let id: String
    let title: String
    /// One line around the newest matching message; nil when only the title matches.
    let snippet: String?
    let fromUser: Bool
    let anchor: AIConversationAnchor?
    static func snippet(_ text: String, term: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map(String.init)
            .first { $0.localizedStandardContains(term) } ?? text
        let flat = line.trimmingCharacters(in: .whitespaces)
        guard let range = flat.localizedStandardRange(of: term) else { return flat }
        // Keep a little context before the match so the term stays on screen.
        let start = flat.index(range.lowerBound, offsetBy: -12, limitedBy: flat.startIndex) ?? flat.startIndex
        return (start > flat.startIndex ? "…" : "") + flat[start...]
    }
}

struct AISessionSummary: Identifiable {
    let id: String
    let title: String
    let origin: AITaskOrigin?
    let kind: AITaskKind?
    let listed: Bool
    let running: Bool
    let waitingConfirmation: Bool
    let deleting: Bool
}
@MainActor @Observable final class AIService {
    let proposals: AIProposalRegistry
    let availability: AIAvailability
    let providers: AIConnectionService
    let sharing: AIDataSharingConsent
    private(set) var sessions: [AIConversation] = []
    var conversations: [AIConversation] { sessions.filter(\.listed).sorted { $0.updated > $1.updated } }
    var selectedID: String?
    var error: String?
    func notify(_ error: Error, sessionID: String? = nil) {
        guard availability.isAvailable, !(error is CancellationError) else { return }
        NotificationCenter.default.post(name: .aiActionFailed, object: AIActionNotice(sessionID: sessionID, message: AIRequestError.message(error)))
    }
    var loaded = false
    @ObservationIgnored private var repository: AIRepository?
    @ObservationIgnored private var coordinator: AIAgentCoordinator?
    @ObservationIgnored private let reader: AppDataService
    @ObservationIgnored private let makeTransport: @Sendable () -> AITransport
    @ObservationIgnored private var loading: Task<Void, Never>?
    private var closedOwners: Set<String> = []
    private var admittedApplications: [String: Set<UUID>] = [:]
    #if DEBUG
    @ObservationIgnored private var fixtureObserver: NSObjectProtocol?
    @ObservationIgnored var fixtureSeeding = false
    @ObservationIgnored var fixtureSeeded = false
    #endif
    init(repository: AIRepository? = nil, defaults suppliedDefaults: UserDefaults? = nil, storefront: AIStorefrontSource = .live, auth: AIAuthentication = AIAuthentication(), reader: AppDataService = .shared, makeTransport: @escaping @Sendable () -> AITransport = { AITransport() }) {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let session = arguments.firstIndex(of: "--ui-test-session").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let defaults = suppliedDefaults ?? session.flatMap { UserDefaults(suiteName: "Moonread.AI.UITest-\($0)") } ?? .standard
        #else
        let defaults = suppliedDefaults ?? .standard
        #endif
        self.repository = repository; self.makeTransport = makeTransport; self.reader = reader
        proposals = AIProposalRegistry(reader: reader)
        availability = AIAvailability(defaults: defaults, storefront: storefront)
        sharing = AIDataSharingConsent(defaults: defaults)
        providers = AIConnectionService(defaults: defaults, auth: auth, sharing: sharing, availability: availability)
        availability.didDisable = { [weak self] in
            guard let self else { return }
            for value in self.sessions { self.stop(value.id) }
            self.coordinator?.stopAll()
            self.providers.cancelAIWork()
        }
        sharing.waitingChanged = { [weak self] owner, waiting in self?.coordinator?.setSharingWaiting(owner, waiting: waiting) }
        sharing.revoked = { [weak self] connectionID, owners in
            guard let self else { return }
            self.providers.cancelNativeRequests(connectionID: connectionID)
            for value in self.sessions where owners.contains(value.id) || value.connectionID == connectionID { self.stop(value.id) }
        }
    }
    func load() async {
        if loaded { return }
        if let loading { await loading.value; return }
        let work = Task { @MainActor in
            do {
                if self.repository == nil { self.repository = try await AIRepository.open() }
                guard let repository = self.repository else { return }
                self.proposals.canEdit = { [weak self] id in self?.admissionOpen(id) == true }
                self.proposals.beginApplication = { [weak self] id in guard let self else { throw AIError.storage }; return try self.beginApplication(id) }
                self.proposals.endApplication = { [weak self] id, token in self?.endApplication(id, token: token) }
                self.proposals.attach = { [weak self] id, attachment, staged in try await self?.addReadingAttachment(id, attachment: attachment, staged: staged) }
                self.coordinator = AIAgentCoordinator(repository: repository, providers: self.providers, reader: self.reader, proposals: self.proposals, isOpen: { [weak self] id in self?.ownsSession(id) == true }, entriesCommitted: { [weak self] id, entries, head in
                    guard let value = self?.conversation(id) else { return }
                    value.head = head; value.mergeEntries(entries, insertingNew: !value.hasLater)
                }, makeTransport: self.makeTransport)
                self.sessions = try await repository.sessions().map(AIConversation.init)
                for value in self.sessions {
                    await AIImageStore.shared.bind(value.id, repository: repository)
                    try await self.connect(value)
                }
                self.error = nil; self.loaded = true
                #if DEBUG
                self.installTaskFixturesIfRequested()
                #endif
            } catch { self.error = AIRequestError.message(error) }
        }
        loading = work; await work.value; loading = nil
    }
    #if DEBUG
    private func installTaskFixturesIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--ui-test-ai-tasks") else { return }
        fixtureObserver = NotificationCenter.default.addObserver(forName: .aiTaskFixtureReady, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in do { try await self?.seedTaskFixturesIfReady() } catch { self?.error = AIRequestError.message(error) } }
        }
        Task { do { try await seedTaskFixturesIfReady() } catch { self.error = AIRequestError.message(error) } }
    }
    #endif
    #if DEBUG || AI_TESTING
    func fixtureRepository(_ value: AISessionValue) async throws -> AIRepository {
        guard let repository else { throw AIError.storage }
        if conversation(value.id) == nil {
            try await repository.create(value)
            sessions.append(AIConversation(value))
        }
        await AIImageStore.shared.bind(value.id, repository: repository)
        return repository
    }
    func installFixtureSession(_ value: AISessionValue, entries: [AIAgentEntry]) async throws {
        guard let repository else { throw AIError.storage }
        if conversation(value.id) == nil {
            try await repository.create(value)
            sessions.append(AIConversation(value))
        }
        await AIImageStore.shared.bind(value.id, repository: repository)
        let store = AIAgentStore(repository: repository)
        var head = AIAgentHead(); head.nextSequence = entries.count; head.status = .completed
        let changes = try await store.commit(value.id, head: head, entries: entries)
        guard let projection = conversation(value.id) else { return }
        if projection.historyLoaded { projection.mergeEntries(changes) }
        try await connect(projection)
    }
    #endif
    #if DEBUG || AI_TESTING
    @ObservationIgnored var taskPersisted: (@MainActor () -> Void)?
    #endif
    private func ownsSession(_ id: String) -> Bool { !closedOwners.contains(id) && conversation(id) != nil }
    private func admissionOpen(_ id: String) -> Bool { availability.isAvailable && ownsSession(id) }
    private func requireAdmission(_ id: String) throws {
        try availability.requireAvailable()
        guard admissionOpen(id) else { throw AIToolError("not_found") }
    }
    private func beginApplication(_ id: String) throws -> UUID {
        try requireAdmission(id)
        let token = UUID(); admittedApplications[id, default: []].insert(token); return token
    }
    private func endApplication(_ id: String, token: UUID) { admittedApplications[id]?.remove(token) }
    func summary(_ id: String) -> AISessionSummary? {
        guard let value = conversation(id) else { return nil }
        return .init(id: id, title: value.title, origin: value.origin, kind: value.kind, listed: value.listed,
            running: value.running, waitingConfirmation: !value.confirmations.isEmpty || value.activity.status == .waitingDataSharing,
            deleting: value.deleting)
    }
    func session(origin: AITaskOrigin, family: AIQuickTaskRequest.Family) -> AISessionSummary? {
        guard let locator = try? origin.locator(), let value = sessions.last(where: {
            !$0.listed && $0.kind.map(AIQuickTaskRequest.family) == family && (try? $0.origin?.locator()) == locator
        }) else { return nil }
        return summary(value.id)
    }
    func conversation(_ id: String) -> AIConversation? { sessions.first { $0.id == id } }
    @discardableResult func create(context: AIContext = .general, noticeOwner: String? = nil) async -> AIConversation? {
        guard availability.isAvailable else { return nil }
        await load()
        do {
            try availability.requireAvailable()
            guard let repository else { throw AIError.storage }
            let value = AISessionValue(title: context.title ?? String(localized: "新对话"), context: context, listed: false)
            let projection = AIConversation(value); projection.persisted = false
            sessions.append(projection); selectedID = value.id
            await AIImageStore.shared.bind(value.id, repository: repository)
            return projection
        } catch { notify(error, sessionID: noticeOwner); return nil }
    }
    func openDraft(context: AIContext = .general) async -> AIConversation? {
        guard availability.isAvailable else { return nil }
        await load()
        if let draft = sessions.last(where: { !$0.listed && $0.kind == nil && $0.context == context }) { return draft }
        return await create(context: context)
    }
    @discardableResult func startTask(origin: AITaskOrigin, kind: AITaskKind, attachments: [AIReadingAttachment], instruction: String, selection: AIModelSelection, consentOwner: String? = nil) async throws -> AIConversation {
        try await availability.perform {
            try await self.startAvailableTask(origin: origin, kind: kind, attachments: attachments, instruction: instruction, selection: selection, consentOwner: consentOwner)
        }
    }
    private func startAvailableTask(origin: AITaskOrigin, kind: AITaskKind, attachments: [AIReadingAttachment], instruction: String, selection: AIModelSelection, consentOwner: String?) async throws -> AIConversation {
        try availability.requireAvailable()
        await load()
        try availability.requireAvailable()
        guard let repository, let coordinator else { throw AIError.storage }
        if let existing = session(origin: origin, family: AIQuickTaskRequest.family(kind)), let value = conversation(existing.id) {
            let runtime = try await coordinator.session(value.id)
            try requireAdmission(value.id)
            runtime.resumeQueued()
            return value
        }
        let value = AISessionValue(title: attachments.first?.title ?? kind.purpose, origin: origin, kind: kind, listed: false)
        try await authorizeSubmission(selection, owner: consentOwner ?? value.id, attachments: attachments,
                                      purpose: kind.purpose, webSources: kind == .cover(mode: .find))
        try Task.checkCancellation()
        var head = AIAgentHead(); head.selection = .init(connectionID: selection.connectionID, modelID: selection.modelID, thinking: selection.thinking)
        head.queue = [.init(text: kind.initialRequest(instruction), mode: .steering, readingAttachments: attachments)]
        await AIImageStore.shared.bind(value.id, repository: repository)
        let refs = AIAssetReferences.head(head)
        let staged = await AIImageStore.shared.staged(owner: value.id, refs: refs)
        do {
            try await repository.create(value, head: head, assets: staged)
            await AIImageStore.shared.didCommit(owner: value.id, refs: refs)
        } catch { await AIImageStore.shared.forget(value.id); throw error }
        let projection = AIConversation(value); projection.head = head; sessions.append(projection)
        #if DEBUG || AI_TESTING
        taskPersisted?()
        #endif
        try await connect(projection)
        try availability.requireAvailable()
        let runtime = try await coordinator.session(value.id)
        try availability.requireAvailable()
        runtime.resumeQueued()
        return projection
    }
    func transferTask(_ id: String) async throws -> String {
        try requireAdmission(id)
        guard let repository, let value = conversation(id) else { throw AIError.storage }
        let reservation = try beginApplication(id)
        defer { endApplication(id, token: reservation) }
        try await repository.list(id)
        guard admissionOpen(id), conversation(id) === value else { throw CancellationError() }
        value.listed = true; value.origin = nil
        return id
    }
    func removeTask(_ id: String) async throws {
        guard conversation(id)?.listed == false else { throw AIError.storage }
        try await deleteSession(id)
    }
    func delete(_ id: String) {
        Task { do { try await deleteSession(id) } catch { notify(error) } }
    }
    func deleteSession(_ id: String) async throws {
        try requireAdmission(id)
        guard admittedApplications[id, default: []].isEmpty else { throw AIToolError("busy", message: String(localized: "操作正在保存，请完成后再删除。")) }
        guard let repository, let value = conversation(id) else { throw AIError.storage }
        // Close synchronously before any suspension; terminal persistence still drains.
        closedOwners.insert(id); value.deleting = true
        sharing.cancel(owner: id); value.sendTask?.cancel()
        await value.sendTask?.value
        await coordinator?.stopAndWait(id)
        await AIImageStore.shared.close(id)
        do {
            if value.persisted { try await repository.delete(id) }
            coordinator?.forget(id); proposals.remove(id)
            sessions.removeAll { $0.id == id }; admittedApplications[id] = nil
            await AIImageStore.shared.forget(id)
            closedOwners.remove(id); if selectedID == id { selectedID = nil }
        } catch {
            value.running = false; value.deleting = false; closedOwners.remove(id)
            await AIImageStore.shared.reopen(id)
            throw error
        }
    }
    private func connect(_ value: AIConversation) async throws {
        guard let coordinator else { throw AIError.storage }
        let runtime = try await coordinator.session(value.id)
        runtime.setObserver { [weak self, weak value, weak runtime] activity in
            guard self != nil, let value, let runtime else { return }
            value.activity = activity; value.partialText = activity.text
            if value.head != runtime.head { value.head = runtime.head }
            if value.running != runtime.isRunning { value.running = runtime.isRunning }
            if value.confirmations != runtime.pendingConfirmations { value.confirmations = runtime.pendingConfirmations }
        }
        if !value.historyLoaded {
            let entries = try await runtime.history(before: Int.max)
            guard conversation(value.id) === value else { return }
            value.mergeEntries(entries, updatingExisting: false)
            value.historyLoaded = true; value.hasEarlier = (value.entries.first?.sequence ?? 0) > 0
        }
    }
    func loadEarlier(_ id: String) {
        Task {
            guard let value = conversation(id), let coordinator else { return }
            do {
                let runtime = try await coordinator.session(id)
                let entries = try await runtime.history(before: value.entries.first?.sequence ?? Int.max)
                guard conversation(id) === value else { return }
                value.mergeEntries(entries, updatingExisting: false); value.hasEarlier = (value.entries.first?.sequence ?? 0) > 0
            } catch { notify(error, sessionID: value.id) }
        }
    }
    /// Opens history around a search match: the page that ends at it and the page after it.
    func showMessage(_ id: String, around anchor: AIConversationAnchor) async {
        guard let value = conversation(id), let coordinator else { return }
        do {
            let runtime = try await coordinator.session(id)
            let before = try await runtime.history(before: anchor.sequence + 1)
            let after = try await runtime.history(after: anchor.sequence)
            guard conversation(id) === value else { return }
            value.showWindow(before + after, newestSequence: runtime.head.nextSequence - 1)
        } catch { notify(error, sessionID: id) }
    }
    func loadLater(_ id: String) {
        Task {
            guard let value = conversation(id), let last = value.entries.last?.sequence, let coordinator else { return }
            do {
                let runtime = try await coordinator.session(id)
                let entries = try await runtime.history(after: last)
                guard conversation(id) === value else { return }
                value.mergeEntries(entries, updatingExisting: false)
                value.hasLater = (value.entries.last?.sequence ?? -1) < runtime.head.nextSequence - 1
            } catch { notify(error, sessionID: id) }
        }
    }
    /// Returns a window to the newest page, where live output continues.
    func showLatest(_ id: String) async {
        guard let value = conversation(id), value.hasLater, let coordinator else { return }
        do {
            let runtime = try await coordinator.session(id)
            let page = try await runtime.history(before: Int.max)
            guard conversation(id) === value else { return }
            value.showWindow(page, newestSequence: runtime.head.nextSequence - 1)
        } catch { notify(error, sessionID: id) }
    }
    /// Listed conversations whose title or visible messages contain the text, newest first;
    /// each carries its newest matching message. Drafts and unlisted tasks are not searched.
    func searchConversations(_ text: String) async throws -> [AIConversationSearchHit] {
        guard availability.isAvailable else { return [] }
        await load()
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        guard let repository else { throw AIError.storage }
        let listed = conversations
        let matches = try await repository.newestMatches(term, in: Set(listed.map(\.id)))
        return listed.compactMap { value in
            let entry = matches[value.id]
            guard entry != nil || value.title.localizedStandardContains(term) else { return nil }
            return AIConversationSearchHit(id: value.id, title: value.title,
                                           snippet: entry.map { AIConversationSearchHit.snippet($0.searchableText, term: term) },
                                           fromUser: entry?.message.object["role"]?.string == "user",
                                           anchor: entry.map { AIConversationAnchor(sequence: $0.sequence, turn: $0.turn) })
        }
    }
    private func requireEditableDraft(_ id: String) throws -> AIConversation {
        try requireAdmission(id)
        guard let value = conversation(id), !value.submitting else { throw AIToolError("busy") }
        return value
    }
    func seedReadingDraft(_ id: String, attachments: [AIReadingAttachment]) {
        guard admissionOpen(id), let value = conversation(id), !value.submitting,
              !value.readingDraftInitialized, value.draft.isEmpty, value.readingDraft.isEmpty else { return }
        value.readingDraft = attachments; value.readingDraftInitialized = true
    }
    func addReadingAttachment(_ id: String, attachment: AIReadingAttachment, staged: AIStagedAsset? = nil) async throws {
        _ = try requireEditableDraft(id)
        if let staged { try await AIImageStore.shared.stageInput(staged) }
        let value = try requireEditableDraft(id)
        var occurrence = attachment; occurrence.id = UUID().uuidString
        value.readingDraft.append(occurrence); value.readingDraftInitialized = true
    }
    func removeReadingAttachment(_ id: String, attachmentID: String) {
        guard let value = try? requireEditableDraft(id) else { return }
        value.readingDraft.removeAll { $0.id == attachmentID }; value.readingDraftInitialized = true
    }
    func updateDraft(_ id: String, text: String) {
        guard let value = try? requireEditableDraft(id) else { return }
        value.draft = text
    }
    func send(_ id: String, mode: AIAgentQueueMode = .steering) {
        guard admissionOpen(id), let value = conversation(id), !value.submitting, let coordinator, let repository else { return }
        let text = value.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let selection = modelSelection(for: .session(id)) else { notify(AIError.noModel, sessionID: id); return }
        let attachments = value.readingDraft
        value.sendTask = Task {
            defer { value.sendTask = nil }
            do {
                try requireAdmission(id)
                try await authorizeSubmission(selection, owner: id, attachments: attachments, purpose: String(localized: "阅读问答"), entries: value.entries)
                try requireAdmission(id)
                guard modelSelection(for: .session(id)) == selection else { throw CancellationError() }
                if !value.persisted {
                    var head = value.head
                    head.selection = .init(connectionID: selection.connectionID, modelID: selection.modelID, thinking: selection.thinking)
                    head.queue = [.init(text: text, mode: mode, readingAttachments: attachments)]
                    let session = AISessionValue(id: id, title: value.context == .general ? String(text.prefix(40)) : value.title, context: value.context)
                    let refs = AIAssetReferences.head(head)
                    let staged = await AIImageStore.shared.staged(owner: id, refs: refs)
                    try requireAdmission(id)
                    try await repository.create(session, head: head, assets: staged)
                    value.persisted = true; value.listed = true; value.title = session.title; value.head = head
                    value.draft = ""; value.readingDraft = []; value.readingDraftInitialized = false
                    await AIImageStore.shared.didCommit(owner: id, refs: refs)
                    try requireAdmission(id)
                    try await connect(value)
                    let runtime = try await coordinator.session(id)
                    runtime.resume()
                    value.updated = Date()
                    return
                }
                let runtime = try await coordinator.session(id)
                try requireAdmission(id)
                try await runtime.enqueue(text, mode: mode, attachments: attachments,
                    selection: .init(connectionID: selection.connectionID, modelID: selection.modelID, thinking: selection.thinking),
                    listed: value.kind == nil ? true : nil)
                value.draft = ""; value.readingDraft = []; value.readingDraftInitialized = false
                value.title = try await repository.session(id).title
                if value.kind == nil { value.listed = true }
                value.updated = Date()
            } catch { notify(error, sessionID: value.id) }
        }
    }
    private func authorizeSubmission(_ selection: AIModelSelection, owner: String, attachments: [AIReadingAttachment], purpose: String, webSources: Bool = false, entries: [AIAgentEntry] = []) async throws {
        guard let connection = providers.connections.first(where: { $0.id == selection.connectionID }),
              let model = providers.model(selection.modelID, in: connection) else { throw AIError.noModel }
        let tools = providers.catalog.resolve(model, providerID: connection.catalogID, authentication: connection.authMethod).capabilities.tools == true
        var scopes = AIDataSharingConsent.chatScopes(tools: tools, attachments: attachments, entries: entries)
        if webSources { scopes.insert(.webSources) }
        let sharingGeneration = try providers.sharing.destination(connection).accountGeneration
        let credential = try await providers.credential(connection)
        try await providers.authorizeSharing(connection: connection, model: model, credential: credential,
                                             owner: owner, purpose: purpose, scopes: scopes, accountGeneration: sharingGeneration)
    }
    func selectRuntime(_ selection: AIModelSelection, conversation: AIConversation) async throws {
        _ = try requireEditableDraft(conversation.id); guard let coordinator else { throw AIError.storage }
        if !conversation.persisted { conversation.head.selection = .init(connectionID: selection.connectionID, modelID: selection.modelID, thinking: selection.thinking); return }
        try await coordinator.select(.init(connectionID: selection.connectionID, modelID: selection.modelID, thinking: selection.thinking), conversationID: conversation.id)
        conversation.head = try await coordinator.session(conversation.id).head
    }
    func stop(_ id: String) { sharing.cancel(owner: id); conversation(id)?.sendTask?.cancel(); coordinator?.stop(id) }
    func answer(_ id: String, confirmationID: String, approved: Bool) {
        guard admissionOpen(id), let coordinator else { return }
        Task { try? await coordinator.session(id).answer(confirmationID, approved: approved) }
    }
    func cancelQueued(_ id: String, inputID: String) {
        guard admissionOpen(id), let coordinator else { return }
        Task { try? await coordinator.session(id).cancelQueued(inputID) }
    }
    func removeConnection(_ id: String) async -> Bool {
        for value in sessions where value.connectionID == id { stop(value.id) }
        return await providers.removeConnection(id)
    }
    @discardableResult func logout(_ id: String) async -> Bool {
        for value in sessions where value.connectionID == id { stop(value.id) }
        return await providers.logout(id)
    }
    func resolveSources(_ refs: [String], session: String) async throws -> [AIResolvedSource] { try await proposals.resolveSources(refs, owner: session) }
}

/// Provider failures may contain private bodies/headers. Only expose known safe causes.
enum AIRequestError {
    static func message(_ error: Error) -> String {
        if let value = AIChatGPTResponses.failure(error) { return value.localizedDescription }
        if let value = error as? AIError { return value.localizedDescription }
        if let value = error as? URLError {
            switch value.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost:
                return String(localized: "网络连接中断")
            case .timedOut: return String(localized: "等待回复超时")
            default: break
            }
        }
        if let value = error as? APICallError {
            switch value.statusCode ?? 0 {
            case 401: return String(localized: "当前连接认证失效")
            case 429: return String(localized: "请求受到限制或额度不足")
            case 500...599: return String(localized: "服务暂时不可用")
            case 400, 403, 404, 422: return String(localized: "此次请求未被接受")
            default: break
            }
        }
        return String(localized: "请求未完成")
    }
}
