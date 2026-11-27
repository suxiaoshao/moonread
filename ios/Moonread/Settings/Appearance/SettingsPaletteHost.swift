import MoonreadReader
import MoonreadCoreBindings
import MoonreadDesign
import MoonreadSettings
import SwiftUI

struct PaletteEditor: View {
    @Environment(ThemeStore.self) private var themes
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var draft: PaletteDraft
    let showsAppPreview: Bool
    init(draft: PaletteDraft, showsAppPreview: Bool = true) { self.draft = draft; self.showsAppPreview = showsAppPreview }
    var body: some View {
        NavigationStack {
            PaletteEditorContent(draft: draft, showsAppPreview: showsAppPreview, highContrast: themes.highContrast,
                                 saving: themes.saving, save: themes.savePalette, close: { dismiss() })
        }
        .modifier(SystemReadingConfirmation(editor: true))
        .interactiveDismissDisabled(themes.saving || draft.saving).preferredColorScheme(theme.scheme)
    }
}

/// App owns theme persistence and supplies a system-opening-aware editor.
struct PalettePicker: View {
    let reader: Bool
    let appearance: ThemeAppearance
    var embedded = false
    var bottomContentInset: CGFloat = 0
    var editPalette: ((PaletteDraft) -> Void)?
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        PalettePickerPage(reader: reader, appearance: appearance, embedded: embedded,
                          bottomContentInset: bottomContentInset, editPalette: editPalette,
                          snapshot: themes.snapshot, system: themes.system, highContrast: themes.highContrast,
                          saving: themes.saving, creationIssue: themes.paletteCreationIssue?.errorDescription,
                          update: themes.update, delete: themes.deletePalette,
                          deletionMessage: { themes.paletteDeletionImpact($0).message }) {
            PaletteEditor(draft: $0)
        }
    }
}
