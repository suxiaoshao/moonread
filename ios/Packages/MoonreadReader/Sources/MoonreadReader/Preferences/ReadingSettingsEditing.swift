import MoonreadCoreBindings
import MoonreadDesign
import SwiftUI

public enum ReadingSettingsTab: String, CaseIterable {
    case typography, colors, controls
    public var title: LocalizedStringKey {
        switch self {
        case .typography: "排版"
        case .colors: "配色与纹理"
        case .controls: "屏幕"
        }
    }
}

@MainActor @Observable public final class ReadingSettingsEditing {
    public var editedAppearance: ThemeAppearance?
    private var localPreviewPresented = false
    public var previewPresented: Bool {
        get { readerTools?.settingsPreviewPresented ?? localPreviewPresented }
        set {
            if let readerTools { readerTools.setSettingsPreview(newValue) }
            else { localPreviewPresented = newValue }
        }
    }
    public var previewDetent = PresentationDetent.height(60)
    public init() {}

    @ObservationIgnored weak var readerTools: ReaderToolSession?
    private var localEditor: ReaderEditSession?
    var paletteSession: ReaderEditSession? {
        let value = readerTools.map { $0.editor } ?? localEditor
        guard let value, case .palette = value.payload else { return nil }
        return value
    }
    public var draft: PaletteDraft? {
        guard let value = paletteSession, case let .palette(draft) = value.payload else { return nil }
        return draft
    }
    public func beginPalette(_ draft: PaletteDraft, presenter: ReaderEditPresenter) {
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
    public var previewPalettePresented: Bool { paletteSession?.presenter == .preview }

    public func paletteBinding(_ presenter: ReaderEditPresenter) -> Binding<PaletteDraft?> {
        let current = paletteSession(for: presenter)
        return Binding(get: {
            guard let visit = self.paletteSession(for: presenter), case .palette(let draft) = visit.payload else { return nil }
            return draft
        }, set: {
            if $0 == nil, let current { self.finishPalette(current.id) }
        })
    }

    public var navigation = NavigationPresentationState()
    public var previewPosition = ReadingPreviewPosition()
    public var previewVisible = false
    public var appeared = false
}
