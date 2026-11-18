import SwiftUI

enum ReadingSettingsTab: String, CaseIterable {
    case typography, colors, controls
    var title: LocalizedStringKey {
        switch self {
        case .typography: "排版"
        case .colors: "配色与纹理"
        case .controls: "屏幕"
        }
    }
}

@MainActor @Observable final class ReadingSettingsEditing {
    var editedAppearance: ThemeAppearance?
    private var localPreviewPresented = false
    var previewPresented: Bool {
        get { readerTools?.settingsPreviewPresented ?? localPreviewPresented }
        set {
            if let readerTools { readerTools.setSettingsPreview(newValue) }
            else { localPreviewPresented = newValue }
        }
    }
    var previewDetent = PresentationDetent.height(60)
    @ObservationIgnored weak var readerTools: ReaderToolSession?
    private var localEditor: ReaderEditSession?
    var paletteSession: ReaderEditSession? {
        let value = readerTools.map { $0.editor } ?? localEditor
        guard let value, case .palette = value.payload else { return nil }
        return value
    }
    var draft: PaletteDraft? {
        guard let value = paletteSession, case let .palette(draft) = value.payload else { return nil }
        return draft
    }
    func beginPalette(_ draft: PaletteDraft, presenter: ReaderEditPresenter) {
        if let readerTools { readerTools.beginEditing(.palette(draft), presenter: presenter) }
        else if localEditor == nil { localEditor = ReaderEditSession(payload: .palette(draft), presenter: presenter) }
    }
    func finishPalette(_ id: UUID) {
        if let readerTools { readerTools.finishEditing(id) }
        else if localEditor?.id == id { localEditor = nil }
    }
    func paletteSession(for presenter: ReaderEditPresenter) -> ReaderEditSession? {
        paletteSession.flatMap { $0.presenter == presenter ? $0 : nil }
    }
    var navigation = NavigationPresentationState()
    var previewPosition = ReadingPreviewPosition()
    var previewVisible = false
    var appeared = false
}
