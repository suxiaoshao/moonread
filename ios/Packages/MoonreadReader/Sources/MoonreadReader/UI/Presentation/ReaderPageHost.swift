import MoonreadAI
import MoonreadCoreBindings
import MoonreadDataTypes
import SwiftUI

public struct ReaderDetailsTarget: Hashable {
    public let target: BookTarget
    public let title: String
    public let fileID: String?
}

public struct ReaderSourceNavigation {
    public let selected: Bool
    public let containsReader: Bool
    public let depth: Int?
    public let tab: String
    public let routeCount: Int

    public init(selected: Bool, containsReader: Bool, depth: Int?, tab: String, routeCount: Int) {
        self.selected = selected
        self.containsReader = containsReader
        self.depth = depth
        self.tab = tab
        self.routeCount = routeCount
    }
}

@MainActor public struct ReaderEdits {
    public let saving: () -> Bool
    public let unsaved: () -> Bool
    public let hasEditor: () -> Bool
    public let discard: () -> Void
}

@MainActor public struct ReaderSettingsPresentation {
    public let settings: Binding<ReaderSettings>
    public let preview: ReadingPreviewSource
    public let encoding: String?
    public let restartingEncoding: Bool
    public let changeEncoding: (String?) -> Void
    public let editing: ReadingSettingsEditing
    public let editorClosed: () -> Void
}

@MainActor public struct ReaderAIPage {
    public let context: AIEntryContext
    public let selected: Binding<String?>
    public let close: () -> Void
    public let openingIsActive: () -> Bool
    public let isOpenBook: (LibraryEntry) -> Bool
}

@MainActor public struct ReaderQuickPaletteChoices {
    let selected: ReaderPaletteSource
    let palettes: [ThemePalette]
    let title: (ThemePalette) -> String
    let choose: (ReaderPaletteSource) -> Void

    public init(selected: ReaderPaletteSource, palettes: [ThemePalette], title: @escaping (ThemePalette) -> String,
                choose: @escaping (ReaderPaletteSource) -> Void) {
        self.selected = selected
        self.palettes = palettes
        self.title = title
        self.choose = choose
    }
}

typealias ReaderCoverRenderer = (String, BookCoverAsset?, String?, String?) -> AnyView

@MainActor public struct ReaderPageHost {
    let source: (UUID?) -> ReaderSourceNavigation
    let register: (ReaderSession, UUID?, ReaderEdits) -> Void
    let unregister: (ReaderSession) -> Void
    let storageReader: (UUID, String?, @escaping @MainActor () async -> Bool) -> Void
    let removeReader: (UUID) -> Void
    let pendingSystemRead: AnyHashable?
    let details: (ReaderDetailsTarget, @escaping () -> Void) -> AnyView
    let settings: (ReaderSettingsPresentation) -> AnyView
    let quickPaletteChoices: () -> ReaderQuickPaletteChoices
    let cover: ReaderCoverRenderer
    let listeningCover: (String, String?, String?, UIImage?) -> AnyView
    let aiAvailable: Bool
    let aiSnapshot: (String) -> AIMoonSnapshot?
    let aiProposes: (String) -> Bool
    let aiPage: (ReaderAIPage) -> AnyView
    let bookReference: (String) -> String
    let showsControlsTip: Bool
    let showsSelectionTip: Bool
    let controlsTip: () -> AnyView
    let selectionTip: () -> AnyView
    let didShowControls: () -> Void
    let didSelectText: () -> Void
    let smokeEnabled: Bool
    let annotationWitness: String?
    let bodyDisplayed: (ReaderSession) -> Void

    public init(
        source: @escaping (UUID?) -> ReaderSourceNavigation,
        register: @escaping (ReaderSession, UUID?, ReaderEdits) -> Void, unregister: @escaping (ReaderSession) -> Void,
        storageReader: @escaping (UUID, String?, @escaping @MainActor () async -> Bool) -> Void, removeReader: @escaping (UUID) -> Void,
        pendingSystemRead: AnyHashable?, details: @escaping (ReaderDetailsTarget, @escaping () -> Void) -> AnyView,
        settings: @escaping (ReaderSettingsPresentation) -> AnyView,
        quickPaletteChoices: @escaping () -> ReaderQuickPaletteChoices,
        cover: @escaping (String, BookCoverAsset?, String?, String?) -> AnyView,
        listeningCover: @escaping (String, String?, String?, UIImage?) -> AnyView,
        aiAvailable: Bool, aiSnapshot: @escaping (String) -> AIMoonSnapshot?, aiProposes: @escaping (String) -> Bool,
        aiPage: @escaping (ReaderAIPage) -> AnyView, bookReference: @escaping (String) -> String,
        showsControlsTip: Bool, showsSelectionTip: Bool, controlsTip: @escaping () -> AnyView,
        selectionTip: @escaping () -> AnyView, didShowControls: @escaping () -> Void, didSelectText: @escaping () -> Void,
        smokeEnabled: Bool = false, annotationWitness: String? = nil, bodyDisplayed: @escaping (ReaderSession) -> Void = { _ in }
    ) {
        self.source = source
        self.register = register
        self.unregister = unregister
        self.storageReader = storageReader
        self.removeReader = removeReader
        self.pendingSystemRead = pendingSystemRead
        self.details = details
        self.settings = settings
        self.quickPaletteChoices = quickPaletteChoices
        self.cover = cover
        self.listeningCover = listeningCover
        self.aiAvailable = aiAvailable
        self.aiSnapshot = aiSnapshot
        self.aiProposes = aiProposes
        self.aiPage = aiPage
        self.bookReference = bookReference
        self.showsControlsTip = showsControlsTip
        self.showsSelectionTip = showsSelectionTip
        self.controlsTip = controlsTip
        self.selectionTip = selectionTip
        self.didShowControls = didShowControls
        self.didSelectText = didSelectText
        self.smokeEnabled = smokeEnabled
        self.annotationWitness = annotationWitness
        self.bodyDisplayed = bodyDisplayed
    }
}
