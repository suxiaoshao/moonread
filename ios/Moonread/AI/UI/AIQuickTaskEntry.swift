import SwiftUI

/// What an entry asks for: the task kind, the object it works on, and the attachments
/// the first request carries.
struct AIQuickTaskRequest: Identifiable {
    enum Family: Hashable { case metadata, cover, organization, statistics }
    let family: Family
    let origin: AITaskOrigin
    let object: AITaskObject
    let attachments: [AIReadingAttachment]
    var id: String { "\(family)-\(origin.hashValue)" }
    var title: LocalizedStringKey {
        switch family { case .metadata: "完善资料"; case .cover: "封面"; case .organization: "整理"; case .statistics: "分析阅读" }
    }
    var runningLabel: LocalizedStringKey {
        switch family { case .metadata: "正在完善"; case .cover: "正在处理封面"; case .organization: "正在整理"; case .statistics: "正在分析" }
    }
    @MainActor func task(_ ai: AIService) -> AISessionSummary? {
        ai.session(origin: origin, family: family)
    }
    static func family(_ kind: AITaskKind) -> Family {
        switch kind { case .metadata: .metadata; case .cover: .cover; case .organization: .organization; case .statistics: .statistics }
    }
}

/// The entry-side sheet: the setup form until Start, then the task, and after transfer
/// the conversation it became. Closing never stops anything.
struct AIQuickTaskSheet: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let request: AIQuickTaskRequest
    @State private var startedID: String?
    @State private var starting = false
    @State private var coverMode: AICoverMode = .find
    @State private var notice: AIActionNotice?
    @State private var visible = false
    @State private var transferring = false
    @State private var detent = PresentationDetent.large
    private var sessionID: String? { startedID ?? request.task(ai)?.id }
    var body: some View {
        NavigationStack {
            Group {
                if let id = sessionID, let session = ai.conversation(id) {
                    AIChatView(conversationID: id, placement: .sheet, taskObject: request.object)
                        .toolbar {
                            if !session.listed {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("转入对话") {
                                        transferring = true
                                        Task {
                                            defer { transferring = false }
                                            do { _ = try await ai.transferTask(id) } catch { ai.notify(error) }
                                        }
                                    }.disabled(transferring || session.deleting).accessibilityIdentifier("transferAITask")
                                }
                            }
                        }
                } else {
                    AITaskSetup(object: request.object, canStart: request.family != .cover || AICoverModePicker.canStart(coverMode, ai), starting: starting) {
                        if request.family == .cover { AICoverModePicker(mode: $coverMode) }
                    } start: { instruction, selection in start(instruction, selection) }
                        .modifier(AIDataSharingPresentation(owner: request.id))
                }
            }
            .navigationTitle(request.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", systemImage: "xmark") { dismiss() }.toolbarGlyph().accessibilityIdentifier("closeAITask") } }

        }
        .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
        .onAppear { visible = true }.onDisappear { visible = false; notice = nil }
        .onReceive(NotificationCenter.default.publisher(for: .aiActionFailed).receive(on: DispatchQueue.main)) { notification in
            guard visible, let event = notification.object as? AIActionNotice, event.sessionID == nil else { return }
            notice = event
        }
        .alert("暂时无法完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice?.message ?? "") }
        .task { await ai.load(); if startedID == nil { startedID = request.task(ai)?.id } }
    }
    private func start(_ instruction: String, _ selection: AIModelSelection) {
        guard !starting else { return }
        // Reserve before creating the asynchronous work, including repeated clicks in this run loop.
        starting = true
        let kind: AITaskKind = switch request.family {
        case .metadata: .metadata
        case .cover: .cover(mode: coverMode)
        case .organization: .organization
        case .statistics: .statistics
        }
        Task {
            defer { starting = false }
            do {
                startedID = try await ai.startTask(origin: request.origin, kind: kind, attachments: request.attachments, instruction: instruction, selection: selection, consentOwner: request.id).id
            } catch { ai.notify(error) }
        }
    }
}

/// Entry for an existing task; status comes only from current runtime activity.
struct AIQuickTaskStatusRow: View {
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    let request: AIQuickTaskRequest
    let open: () -> Void
    var body: some View {
        if let task = request.task(ai) {
            let text = Self.text(task, family: request.family)
            Button(action: open) {
                HStack(spacing: LayoutTokens.compact) {
                    Image(systemName: "sparkles").foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
                    Text(verbatim: text).foregroundStyle(Color(uiColor: theme.ink))
                    Spacer(minLength: 0)
                    if task.running { ProgressView().accessibilityHidden(true) }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityHidden(true)
                }.frame(minHeight: LayoutTokens.hit).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("aiTaskStatusRow")
        }
    }
    @MainActor static func text(_ task: AISessionSummary, family: AIQuickTaskRequest.Family) -> String {
        let name: String = switch family {
        case .metadata: String(localized: "资料建议")
        case .cover: String(localized: "封面")
        case .organization: String(localized: "整理方案")
        case .statistics: String(localized: "阅读分析")
        }
        // A runtime waiting for confirmation is still running; the wait is what needs the person.
        if task.waitingConfirmation { return name + " · " + String(localized: "等待确认") }
        if task.running { return name + " · " + String(localized: "进行中") }
        return name
    }
}

enum AIQuickTaskDates {
    /// Statistics days are civil day numbers; the task carries explicit local dates.
    static func iso(_ day: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = StatisticsDates.civilCalendar; formatter.timeZone = StatisticsDates.civilCalendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: StatisticsDates.date(day))
    }
}

extension AIQuickTaskRequest {
    /// Library files: one file keeps the book origin shared with its detail page;
    /// several selected files form one task over exactly that selection.
    static func library(_ entries: [LibraryEntry], family: Family) -> AIQuickTaskRequest {
        let files = entries.filter { !$0.directory }
        let refs = files.map { AIReadingTools.ref("f", $0.id) }
        let attachments = zip(files, refs).map { entry, ref in
            AIReadingAttachment(kind: .book, origin: "library", fileRef: ref, title: entry.title)
        }
        if files.count == 1, family == .metadata, let entry = files.first {
            return AIQuickTaskRequest(family: family, origin: AITaskOrigin(bookSHA: nil, fileRef: refs[0]),
                                      object: AITaskObject(title: entry.title, cover: entry.metadata?.cover), attachments: attachments)
        }
        var selection = AIReadingAttachment(kind: .files, origin: "library", title: String(localized: "已选 \(files.count) 项"))
        selection.fileRefs = refs
        return AIQuickTaskRequest(family: family, origin: AITaskOrigin(fileRefs: Set(refs)),
                                  object: AITaskObject(title: selection.title, symbol: "books.vertical"),
                                  attachments: family == .organization ? [selection] : attachments)
    }
}

extension AIQuickTaskRequest {
    /// Captures the current period and optional book at sheet opening. A book page
    /// cannot silently fall back to an all-books attachment before its identity is ready.
    @MainActor static func statistics(window: StatisticsWindow, target: StatisticsRoute?, information: BookInformationModel) -> AIQuickTaskRequest? {
        let sha = target.flatMap { information.contentSHA(for: $0) }
        guard target == nil || sha != nil else { return nil }
        let bounds = window.bounds()
        let from = AIQuickTaskDates.iso(bounds.lowerBound), to = AIQuickTaskDates.iso(bounds.upperBound)
        let range = "\(StatisticsDates.dateLabel(bounds.lowerBound, full: true)) – \(StatisticsDates.dateLabel(bounds.upperBound, full: true))"
        return AIQuickTaskRequest(family: .statistics, origin: AITaskOrigin(from: from, to: to, bookSHA: sha),
                                  object: AITaskObject(title: target?.title ?? String(localized: "阅读统计"), subtitle: range, symbol: "chart.bar"),
                                  attachments: AIQuickTaskAttachments.statistics(from: from, to: to, bookSHA: sha, title: range))
    }
    /// A folder or shelf root, referenced the same way the reading tools resolve it.
    static func folder(_ location: LibraryLocation, title: String) -> AIQuickTaskRequest {
        let scopeRef = AIReadingTools.scopeRef(shelfID: location.shelfID, path: location.path)
        var scope = AIReadingAttachment(kind: .folder, origin: "library", title: title)
        scope.scopeRef = scopeRef
        return AIQuickTaskRequest(family: .organization, origin: AITaskOrigin(scopeRef: scopeRef),
                                  object: AITaskObject(title: title, symbol: "folder"), attachments: [scope])
    }
}

enum AIQuickTaskAttachments {
    static func statistics(from: String, to: String, bookSHA: String?, title: String) -> [AIReadingAttachment] {
        var period = AIReadingAttachment(kind: .statistics, origin: "statistics", bookRef: bookSHA.map(AIReadingTools.bookRef), title: title)
        period.fromDate = from; period.toDate = to
        return [period]
    }
}

enum AIQuickTaskRemoval {
    /// States only what removal changes for this task; applied changes are never reverted.
    @MainActor static func message(_ task: AISessionSummary) -> String {
        var parts: [String] = []
        if task.running { parts.append(String(localized: "正在进行的请求会停止。")) }
        parts.append(String(localized: "任务及其结果会删除。"))
        parts.append(String(localized: "已应用的修改会保留。"))
        return parts.joined(separator: "")
    }
}
