import SwiftUI

import UIKit

struct ReadingContentGeometry: Equatable {
    let size: CGSize
}

struct ReadingView: UIViewControllerRepresentable {
    @Environment(\.theme) private var theme
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    let window: ReadingWindow
    let settings: ReaderSettings
    let anchor: UInt64
    var openingID: UUID? = nil
    var requestWindow: (ReadingDirection, SourceSpan) -> Bool = { _,_ in false }
    let dark: Bool
    let dynamicTypeSize: DynamicTypeSize
    var navigationRevision: Int = 0
    var navigation: ReadingNavigation?
    var viewportAccess: ReadingViewportAccess?
    var annotations: [ReaderMark] = []
    var bookmarkPositions: [UInt64] = []
    var focusRange: TextRange?
    var selectionStart: UInt64?
    var selection: (UInt64, UInt64, ReaderSelectionAction) -> Void = { _, _, _ in }
    var allowsBackGesture = false
    var allowsSelection = true
    var allowsChapterEditing = true
    var coverTitle: String? = nil
    var coverInformation: BookDetails? = nil
    var showBookDetails: () -> Void = {}
    var showingCover = false
    var coverChanged: (Bool) -> Void = { _ in }
    var brightnessChanged: (Double) -> Void = { _ in }
    var orientationFailed: () -> Void = {}
    var statisticsInteraction: () -> Void = {}
    var edgeChanged: (Bool) -> Void = { _ in }
    let compactHeaderHeight: CGFloat
    var guideHeight: CGFloat = 0
    var contentGeometry: ReadingContentGeometry? = nil
    var layoutStatus: ReadingLayoutStatus? = nil
    var headerPositionChanged: (CGFloat) -> Void = { _ in }
    let controlsVisible: Bool
    let toggleControls: () -> Void
    let readingBegan: () -> Void
    let positionChanged: (UInt64, Bool) -> Void

    func makeUIViewController(context: Context) -> ReadingController {
        let controller = ReadingController()
        viewportAccess?.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: ReadingController, context: Context) {
        controller.headerPositionChanged = headerPositionChanged
        controller.contentGeometry = contentGeometry
        controller.layoutStatus = layoutStatus
        controller.guideHeight = guideHeight
        controller.requestWindow = requestWindow
        controller.openingID = openingID
        controller.allowsBackGesture = allowsBackGesture
        controller.allowsSelection = allowsSelection
        controller.allowsChapterEditing = allowsChapterEditing
        controller.deviceControls.brightnessChanged = brightnessChanged
        controller.deviceControls.orientationFailed = orientationFailed
        controller.deviceControls.update(settings)
        controller.statisticsInteraction = statisticsInteraction
        controller.configure(window: window, settings: settings, anchor: anchor,
                             dark: dark, typeSize: dynamicTypeSize, theme: theme, reduceMotion: reduceMotion,
                             navigationRevision: navigationRevision, navigation: navigation, annotations: annotations,
                             bookmarkPositions: bookmarkPositions, focusRange: focusRange,
                             selectionStart: selectionStart, selection: selection, edgeChanged: edgeChanged,
                             coverTitle: coverTitle, coverInformation: coverInformation, showBookDetails: showBookDetails,
                             showingCover: showingCover, coverChanged: coverChanged,
                             compactHeaderHeight: compactHeaderHeight,
                             controlsVisible: controlsVisible, toggleControls: toggleControls,
                             readingBegan: readingBegan, changed: positionChanged)
    }
}
