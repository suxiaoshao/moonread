import SwiftUI
import UIKit

@MainActor @Observable final class ReaderToolSession {
    let presentation = ReaderPresentationState()
    let host = ReaderPresentationHost()
    func acceptsNativeInput(_ token: ReaderHostToken?, generation: UInt64) -> Bool {
        guard let token, generation == presentation.revision else { return false }
        return host.acceptsInput(token, opening: token.opening, generation: generation)
    }
    private var editors: [UUID: ReaderEditSession] = [:]
    var editor: ReaderEditSession? {
        presentation.location.path.reversed().compactMap { $0.editorID.flatMap { editors[$0] } }.first
    }
    let libraryEditing = ReaderLibraryEditing()
    let settingsEditing = ReadingSettingsEditing()
    init() { libraryEditing.readerTools = self; settingsEditing.readerTools = self }
    func beginEditing(_ payload: ReaderEditSession.Payload, presenter: ReaderEditPresenter) {
        guard editor == nil else { return }
        let value = ReaderEditSession(payload: payload, presenter: presenter)
        editors[value.id] = value
        switch payload {
        case .palette: presentation.push(.palette(value.id))
        case .chapter: presentation.push(.chapter(value.id))
        case .rebuild: presentation.push(.rebuild(value.id))
        }
    }
    func finishEditing(_ id: UUID) {
        guard editor?.id == id, let current = editors[id] else { return }
        if case let .rebuild(model) = current.payload { model.cancel() }
        presentation.finishEditor(id)
    }
    func editor(_ id: UUID) -> ReaderEditSession? { editors[id] }
    func releaseFinishedEditors() {
        let active = Set(presentation.location.path.compactMap(\.editorID))
        editors = editors.filter { active.contains($0.key) }
    }
    func releaseEditor(_ id: UUID) {
        guard !presentation.location.path.contains(where: { $0.editorID == id }) else { return }
        editors.removeValue(forKey: id)
    }
    func setPath(_ path: [ReaderDestination]) {
        let removed = presentation.location.path.compactMap(\.editorID).filter { id in !path.contains(where: { $0.editorID == id }) }
        for id in removed { finishEditing(id) }
        presentation.location.path = path
    }
    var savingDraft: Bool {
        guard let editor else { return false }
        switch editor.payload { case .palette(let draft): return draft.saving; case .chapter(let draft): return draft.saving; case .rebuild: return false }
    }
    var hasEditableDraft: Bool {
        guard let editor else { return false }
        switch editor.payload { case .palette, .chapter: return true; case .rebuild: return false }
    }
    var hasUnsavedChanges: Bool {
        guard let editor else { return false }
        switch editor.payload { case .palette(let draft): return draft.hasUnsavedChanges; case .chapter(let draft): return draft.hasUnsavedChanges; case .rebuild: return false }
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
    var source: ReaderSourceNavigation? = nil
    final class Probe: UIViewController {
        weak var host: ReaderPresentationHost?
        weak var source: ReaderSourceNavigation?
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
            guard let host, let installationID, (source?.token?.id ?? host.token?.id) == installationID, (source?.hasModalChild ?? host.hasModalChild) != hasChild else { return }
            Task { @MainActor [weak self, weak host] in
                guard self?.viewIfLoaded?.window != nil, (self?.source?.token?.id ?? host?.token?.id) == installationID else { return }
                if let source = self?.source { source.hasModalChild = hasChild } else { host?.hasModalChild = hasChild }
            }
        }
    }
    func makeUIViewController(context: Context) -> Probe {
        let value = Probe(); value.host = host; value.source = source; value.installationID = source?.token?.id ?? host.token?.id; return value
    }
    func updateUIViewController(_ controller: Probe, context: Context) {
        controller.host = host; controller.source = source
        controller.installationID = source?.token?.id ?? host.token?.id
        if controller.viewIfLoaded?.window != nil { controller.publish() }
    }
}

