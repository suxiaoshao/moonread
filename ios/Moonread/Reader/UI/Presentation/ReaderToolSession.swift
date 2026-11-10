import SwiftUI
import UIKit
import AVFoundation

@MainActor @Observable final class ReaderToolSession {
    enum Action {
        case showChrome, hideChrome, toggleChrome
        case quick(ReaderQuickTool)
        case open(ReaderToolRoute)
        case openSearch, openListening, openAutomatic
        case expand, collapse, endSearch, hideAccessory
        case closeVisit(UUID)
        case noteChanged(NoteEditorModel?)
        case showVoices(Bool)
        case startListening, pauseListening, stopListening
        case startAutomatic, pauseAutomatic, endAutomatic
        case systemRequest, sourceChanged, backgrounded
        case encode(String?)
        case navigate(ReaderNavigationIntent)
        case returnToSpeech, returnToPreview, continueHere
        case positionHandoff, manualInteraction, selectionChanged, ordinaryEdit
        case remote(ListeningSession, ListeningCommand)
        case startAutomaticAfterRelease(Bool)
        case rate(Float), timer(Int), chooseVoice(AVSpeechSynthesisVoice), previewVoice(AVSpeechSynthesisVoice)
        case finishedBrowse(ReaderActionContext)
        case nativeConfirmed(ReaderHostToken), nativeDismissed(ReaderHostToken), nativeClose(ReaderHostToken)
    }

    @ObservationIgnored weak var reader: ReaderSession?
    private(set) var tools: ReaderToolsModel
    private(set) var intent: ReaderSurfaceIntent = .reading(.hidden)
    private(set) var revision: UInt64 = 0
    private(set) var opening = UUID()
    private var valid = true
    let host = ReaderPresentationHost()
    let libraryEditing = ReaderLibraryEditing()
    private(set) var settingsEditing = ReadingSettingsEditing()

    init(reader: ReaderSession? = nil) {
        self.reader = reader
        self.tools = ReaderToolsModel(service: reader?.service ?? .shared)
        libraryEditing.readerTools = self
        settingsEditing.readerTools = self
    }

    var render: ReaderRenderSnapshot {
        let visit: UUID? = if case .tool(let visit) = intent { visit.id } else { nil }
        return ReaderRenderSnapshot(intent: intent, context: .init(opening: opening, visit: visit, revision: revision),
                                    hasUndo: tools.deletedIDs != nil)
    }
    var editor: ReaderEditSession? { render.editor }
    var settingsPreviewPresented: Bool {
        switch render.visit?.route {
        case .settings(.preview), .settings(.palette(_, fromPreview: true)): true
        default: false
        }
    }
    var listeningVoicesPresented: Bool {
        if case .listeningSettings(_, .voices) = render.visit?.route { return true }
        return false
    }

    func beginOpening(_ id: UUID) {
        guard id != opening else { return }
        tools.leave()
        tools = ReaderToolsModel(service: reader?.service ?? .shared)
        settingsEditing = ReadingSettingsEditing()
        settingsEditing.readerTools = self
        opening = id
        valid = true
        publish(.reading(.hidden))
    }

    func invalidateOpening() {
        valid = false
        tools.leave()
        publish(.reading(.hidden))
    }

    private func publish(_ next: ReaderSurfaceIntent) {
        intent = next
        revision &+= 1
    }

    func send(_ action: Action, from context: ReaderActionContext? = nil) {
        if case .nativeDismissed(let token) = action { host.completed(token); return }
        guard valid, reader?.isLeaving != true, context == nil || context == render.context else { return }
        switch action {
        case .showChrome:
            showChrome()
        case .hideChrome:
            hideChrome()
        case .toggleChrome:
            if render.controls { hideChrome() } else { showChrome() }
        case .quick(let tool):
            if let visit = render.visit, case .quick(let current) = visit.route, current == tool {
                finish(visit)
            } else {
                if tool == .more { reader?.autoReading?.pause() } else { reader?.autoReading?.end() }
                replace(.quick(tool), returnTo: .init(chrome: .visible))
            }
        case .open(let route):
            reader?.autoReading?.end()
            var resume = ReaderReturnContext()
            if case .library = route, case .quick(.more) = render.visit?.route {
                resume = .init(target: .more, chrome: .visible)
            }
            if case .library(let visit) = route { tools.select(visit.tab) }
            replace(route, returnTo: resume)
        case .openSearch:
            reader?.autoReading?.end()
            tools.beginSearchSession()
            replace(.search(tools))
        case .openListening:
            guard let reader else { return }
            tools.stopSearch()
            publish(.accessory(.listening(reader.selectListening()), .hidden))
        case .openAutomatic:
            guard let reader else { return }
            let automatic = reader.selectAutomaticReading()
            automatic.pause()
            tools.stopSearch()
            publish(.accessory(.automatic(automatic), .hidden))
        case .expand:
            expand()
        case .collapse:
            collapse()
        case .closeVisit(let id):
            if let visit = render.visit, visit.id == id { finish(visit) }
        case .endSearch:
            guard render.compact == .search else { return }
            tools.stopSearch()
            publish(resolveResume(.init()))
        case .hideAccessory:
            hideAccessory()
        case .noteChanged(let note):
            updateNote(note)
        case .showVoices(let shown):
            guard var visit = render.visit, case .listeningSettings(let player, _) = visit.route else { return }
            if shown { player.pause() } else { player.stopPreview() }
            visit.route = .listeningSettings(player, shown ? .voices : .controls)
            publish(.tool(visit))
        case .startListening:
            guard let player = reader?.activeListening else { return }
            player.start()
            if player.active, render.expanded { collapse() }
        case .pauseListening:
            reader?.pauseListening()
        case .stopListening:
            reader?.stopListening()
            if render.compact == .listening { hideAccessory() }
        case .startAutomatic:
            guard let reader, reader.settings?.mode == .scroll, let automatic = reader.autoReading else { return }
            automatic.requestStart(opening: opening)
            hideAccessory()
        case .startAutomaticAfterRelease(let ready):
            guard host.token == nil, let reader, let automatic = reader.autoReading,
                  let request = automatic.pendingStart, request.opening == opening else { return }
            guard ready, render.target == .none else { automatic.pause(); return }
            reader.beganReadingInteraction()
            automatic.startAfterDismissal(opening: opening, speed: reader.settings?.autoReadingSpeed ?? autoReadingControl().defaultValue,
                                          requestID: request.id)
        case .pauseAutomatic:
            reader?.autoReading?.pause()
        case .endAutomatic:
            reader?.autoReading?.end()
            if render.compact == .automatic { hideAccessory() }
        case .systemRequest:
            reader?.autoReading?.pause(); reader?.pauseListening()
            if render.visit == nil && render.compact == .progress { hideChrome() }
        case .sourceChanged:
            reader?.autoReading?.pause(); reader?.pauseListening()
        case .backgrounded:
            reader?.autoReading?.pause()
        case .encode(let encoding):
            tools.stopSearch()
            publish(.reading(.hidden))
            reader?.restart(encoding: encoding)
        case .navigate(let intent):
            requestNavigation(intent)
        case .positionHandoff:
            prepareJump()
        case .manualInteraction:
            guard let reader else { return }
            if let player = reader.activeListening {
                if player.ownsPosition && !player.active { reader.cancelNavigation() }
                player.userNavigated()
            }
        case .selectionChanged:
            reader?.pauseListening()
            reader?.autoReading?.end()
        case .ordinaryEdit:
            reader?.autoReading?.end()
        case .returnToSpeech, .returnToPreview, .continueHere:
            finishPositionAction(action)
        case .remote(let player, let command):
            guard player === reader?.activeListening, player.active else { return }
            player.execute(command)
            if !player.active, render.compact == .listening { hideAccessory() }
        case .rate(let rate): reader?.activeListening?.setRate(rate)
        case .timer(let minutes): reader?.activeListening?.setTimer(minutes)
        case .chooseVoice(let voice): reader?.activeListening?.selectVoice(voice)
        case .previewVoice(let voice): reader?.activeListening?.preview(voice)
        case .finishedBrowse(let source):
            guard source == render.context else { return }
            if render.compact == .search { tools.stopSearch() }
            publish(resolveResume(.init()))
        case .nativeConfirmed(let token):
            host.confirmed(token)
        case .nativeClose(let token):
            guard host.acceptsInput(token, opening: opening, generation: revision) else { return }
            host.installation.beginDismissal()
            if let visit = render.visit { finish(visit) } else { hideAccessory() }
        case .nativeDismissed: break
        }
    }

    var listeningAdmission: ListeningAdmission {
        guard valid, let reader, !reader.isLeaving else { return .blocked(.leaving) }
        if reader.error != nil { return .blocked(.readingError) }
        if reader.selectionStart != nil || reader.viewportAccess.controller?.selectedSourceRange() != nil {
            return .blocked(.selection)
        }
        if listeningVoicesPresented || reader.activeListening?.previewing == true { return .blocked(.voice) }
        if let work = reader.navigationWork {
            switch work.intent {
            case .returnToSpeech: return .keepCurrentOnly(.returning)
            case .userJump, .returnToPreview, .syncedContinuation: return .keepCurrentOnly(.locating)
            case .listeningFollow, .speechExit: break
            }
        }
        if reader.viewportAccess.hasBlockingListeningPresentation(opening: opening, awaitingToolContent: true) {
            return .blocked(.externalPresentation)
        }
        if reader.viewportAccess.hasBlockingListeningPresentation(opening: opening) {
            return .keepCurrentOnly(.presentingTool)
        }
        return .allowed
    }

    private func prepareJump() {
        reader?.pauseListening()
        reader?.activeListening?.userNavigated()
        reader?.autoReading?.end()
    }

    private func requestNavigation(_ intent: ReaderNavigationIntent) {
        guard let reader, !reader.navigating else { return }
        let source = render.context
        let previous = reader.navigationRevision
        switch intent {
        case .userJump(let target):
            prepareJump()
            reader.executeBrowse(target, intent: intent)
        case .returnToPreview(let target):
            reader.executeBrowse(target, intent: intent)
            return
        default: return
        }
        let request = reader.navigationGeneration
        let task = reader.navigationTask
        Task { [weak self, weak reader] in
            await task?.value
            guard let self, let reader, valid, render.context == source,
                  reader.navigationGeneration == request, reader.navigationRevision > previous else { return }
            if render.compact == .search { collapse() }
            else if let visit = render.visit, visit.route.container == .task { finish(visit, returningToReader: true) }
            else if render.compact == .progress { publish(resolveResume(.init())) }
        }
    }

    private func finishPositionAction(_ action: Action) {
        guard let reader, !reader.navigating else { return }
        let source = render.context
        let wasBrowsing = reader.browseOrigin != nil
        Task { [weak self, weak reader] in
            guard let self, let reader else { return }
            switch action {
            case .returnToSpeech:
                guard await reader.returnToListening() else { return }
            case .returnToPreview: await reader.returnFromBrowse()
            case .continueHere: await reader.continueReading()
            default: return
            }
            if wasBrowsing, reader.browseOrigin == nil { send(.finishedBrowse(source)) }
        }
    }

    private func showChrome() {
        reader?.autoReading?.pause()
        switch intent {
        case .accessory(let accessory, _): publish(.accessory(accessory, .visible))
        case .reading: publish(resolveResume(.init(chrome: .visible)))
        case .tool: break
        }
    }

    private func hideChrome() {
        switch intent {
        case .reading: publish(.reading(.hidden))
        case .accessory(let accessory, _):
            switch accessory {
            case .automatic, .progress: publish(resolveResume(.init()))
            default: publish(.accessory(accessory, .hidden))
            }
        case .tool(var visit):
            guard visit.route.container == .compact else { return }
            visit.resume.chrome = .hidden
            finish(visit)
        }
    }

    private func hideAccessory() {
        if render.compact == .search { tools.stopSearch() }
        publish(.reading(.hidden))
    }

    private func replace(_ route: ReaderToolRoute, returnTo resume: ReaderReturnContext = .init()) {
        guard editor == nil, reader?.noteEditorModel == nil else { return }
        publish(.tool(ReaderToolVisit(route: route, resume: resume)))
    }

    private func expand() {
        guard case .accessory(let accessory, let chrome) = intent else { return }
        let route: ReaderToolRoute
        switch accessory {
        case .search(let search): route = .search(search)
        case .automatic(let auto): route = .automaticSettings(auto)
        case .listening(let player): route = .listeningSettings(player, .controls)
        default: return
        }
        replace(route, returnTo: .init(chrome: chrome))
    }

    private func collapse() {
        guard let visit = render.visit else { return }
        let accessory: ReaderAccessory
        switch visit.route {
        case .search(let search): accessory = .search(search)
        case .listeningSettings(let player, _):
            player.stopPreview()
            accessory = .listening(player)
        case .automaticSettings(let auto): accessory = .automatic(auto)
        default: return
        }
        publish(.accessory(accessory, visit.resume.chrome))
    }

    private func finish(_ visit: ReaderToolVisit, returningToReader: Bool = false) {
        switch visit.route {
        case .library(.note(let tab, _)):
            reader?.editor = nil
            var parent = visit; parent.route = .library(.listing(tab))
            publish(.tool(parent))
            return
        case .library(.editing(_, let editor)):
            finishEditing(editor.id)
            return
        case .settings(.palette(let editor, _)):
            finishEditing(editor.id)
            return
        case .search:
            tools.stopSearch()
        case .note:
            reader?.editor = nil
        case .listeningSettings:
            collapse()
            return
        case .automaticSettings:
            hideAccessory()
            return
        default: break
        }
        reader?.notesChanged()
        publish(resolveResume(returningToReader ? .init() : visit.resume))
    }

    private func resolveResume(_ resume: ReaderReturnContext) -> ReaderSurfaceIntent {
        guard valid, reader?.isLeaving != true else { return .reading(.hidden) }
        if let player = reader?.activeListening, player.active { return .accessory(.listening(player), resume.chrome) }
        if resume.target == .more { return .tool(.init(route: .quick(.more), resume: resume)) }
        if tools.searchActive { return .accessory(.search(tools), resume.chrome) }
        if let origin = reader?.browseOrigin { return .accessory(.browse(origin), resume.chrome) }
        if resume.chrome == .visible { return .accessory(.progress, .visible) }
        return .reading(.hidden)
    }

    private func updateNote(_ note: NoteEditorModel?) {
        if let note {
            if var visit = render.visit, case .library(let library) = visit.route {
                visit.route = .library(.note(library.tab, note))
                publish(.tool(visit))
            } else { publish(.tool(.init(route: .note(note)))) }
        } else if let visit = render.visit {
            switch visit.route {
            case .note, .library(.note): finish(visit)
            default: break
            }
        }
    }

    func setSettingsPreview(_ shown: Bool) {
        guard var visit = render.visit, case .settings(let page) = visit.route else { return }
        switch (shown, page) {
        case (true, .main): visit.route = .settings(.preview)
        case (false, .preview): visit.route = .settings(.main)
        default: return
        }
        publish(.tool(visit))
    }

    func acceptsNativeInput(_ token: ReaderHostToken?, generation: UInt64) -> Bool {
        guard let token, generation == revision else { return false }
        return host.acceptsInput(token, opening: opening, generation: generation)
    }

    func beginEditing(_ payload: ReaderEditSession.Payload, presenter: ReaderEditPresenter) {
        guard valid, editor == nil else { return }
        let value = ReaderEditSession(payload: payload, presenter: presenter)
        if presenter == .readerTask {
            publish(.tool(.init(route: .chapter(value))))
            return
        }
        guard var visit = render.visit else { return }
        switch (presenter, visit.route) {
        case (.settings, .settings), (.preview, .settings):
            visit.route = .settings(.palette(value, fromPreview: presenter == .preview))
        case (.library, .library(let parent)):
            visit.route = .library(.editing(parent.tab, value))
        default: return
        }
        publish(.tool(visit))
    }

    func finishEditing(_ id: UUID) {
        guard var visit = render.visit, let editor = visit.route.editor, editor.id == id else { return }
        if case .rebuild(let model) = editor.payload { model.cancel() }
        switch visit.route {
        case .settings(.palette(_, let fromPreview)): visit.route = .settings(fromPreview ? .preview : .main)
        case .library(.editing(let tab, _)): visit.route = .library(.listing(tab))
        case .chapter: publish(resolveResume(visit.resume)); return
        default: return
        }
        publish(.tool(visit))
    }

    var savingDraft: Bool {
        guard let editor else { return false }
        switch editor.payload {
        case .palette(let draft): return draft.saving
        case .chapter(let draft): return draft.saving
        case .rebuild: return false
        }
    }
    var hasEditableDraft: Bool {
        guard let editor else { return false }
        switch editor.payload { case .palette, .chapter: return true; case .rebuild: return false }
    }
    var hasUnsavedChanges: Bool {
        guard let editor else { return false }
        switch editor.payload {
        case .palette(let draft): return draft.hasUnsavedChanges
        case .chapter(let draft): return draft.hasUnsavedChanges
        case .rebuild: return false
        }
    }
}

enum ReaderEditPresenter { case settings, preview, library, readerTask }

/// One draft identity, retained until its native editing context finishes.
@MainActor final class ReaderEditSession: Identifiable {
    enum Payload {
        case palette(PaletteDraft), chapter(ChapterEditDraft), rebuild(ChapterRebuildModel)
    }
    let id = UUID()
    let payload: Payload
    let presenter: ReaderEditPresenter
    init(payload: Payload, presenter: ReaderEditPresenter) {
        self.payload = payload; self.presenter = presenter
    }
}

struct ReaderUndoAction: View {
    let session: ReaderSession
    let tools: ReaderToolsModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "trash").accessibilityHidden(true)
                Text("已删除")
            }.foregroundStyle(Color(uiColor: theme.secondary))
            Spacer(minLength: 12)
            Button { Task { await tools.undoDelete(); session.notesChanged() } } label: {
                Text("撤销").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
                    .contentShape(.rect)
            }.accessibilityIdentifier("undoDeletedAnnotation")
        }
        .font(.subheadline).padding(.horizontal, LayoutTokens.page).padding(.vertical, 4)
    }
}


struct ReaderModalChildProbe: UIViewControllerRepresentable {
    let host: ReaderPresentationHost
    final class Probe: UIViewController {
        weak var host: ReaderPresentationHost?
        var installationID: UUID?
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); publish() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); publish() }
        func publish() {
            var ancestor = parent
            var hasChild = false
            while let controller = ancestor {
                if controller.presentedViewController != nil { hasChild = true; break }
                ancestor = controller.parent
            }
            guard let host, let installationID, host.token?.id == installationID, host.hasModalChild != hasChild else { return }
            Task { @MainActor [weak self, weak host] in
                guard self?.viewIfLoaded?.window != nil, host?.token?.id == installationID else { return }
                host?.hasModalChild = hasChild
            }
        }
    }
    func makeUIViewController(context: Context) -> Probe {
        let value = Probe(); value.host = host; value.installationID = host.token?.id; return value
    }
    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.host = host
        controller.installationID = host.token?.id
        if controller.viewIfLoaded?.window != nil { controller.publish() }
    }
}

