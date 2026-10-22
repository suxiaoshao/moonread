import SwiftUI
import UIKit

/// A dynamic UIColor retained by attributed text. Updating the paint does not
/// touch NSTextStorage, whose edit notifications can move native selections.
final class ReadingInk: @unchecked Sendable {
    private let lock = NSLock()
    private var color: UIColor = .label
    func set(_ value: UIColor) { lock.lock(); defer { lock.unlock() }; color = value }
    func get() -> UIColor { lock.lock(); defer { lock.unlock() }; return color }
    var dynamic: UIColor { UIColor { [self] _ in get() } }
}

@MainActor
enum ReadingTextMetrics {
    // Pages stop above the home indicator; scrolling text extends behind its fade.
    static let insets = UIEdgeInsets(top: 16, left: 16, bottom: 4, right: 16)

    static func scrollFadeHeight(bottomSafeArea: CGFloat) -> CGFloat {
        bottomSafeArea > 0 ? bottomSafeArea : 24
    }

    static func contentSize(in size: CGSize, insets: UIEdgeInsets = ReadingTextMetrics.insets) -> CGSize {
        CGSize(width: max(1, size.width - insets.left - insets.right),
               height: max(1, size.height - insets.top - insets.bottom))
    }

    static func fadeOpacity(remaining: CGFloat, isEndOfBook: Bool, isPreparedTail: Bool = false, height: CGFloat = 24) -> Float {
        (isEndOfBook || isPreparedTail) ? Float(min(1, max(0, remaining) / max(1, height))) : 1
    }
}

enum ReadingTargetPlacement { case start, context, cover }

/// Transient display geometry, kept only for the current reader's return point.
/// Persistent locations remain Rust-owned UTF-8 offsets.
@MainActor
struct ReadingViewport {
    let offset: UInt64
    let lineY: CGFloat
    let size: CGSize
    let settings: ReaderSettings
    let typeSize: DynamicTypeSize
    let pages: [TextPage]
    var isCover = false
}

@MainActor
struct ReadingNavigation {
    var placement: ReadingTargetPlacement = .start
    var bottomObstruction: CGFloat = 0
    var restoring: ReadingViewport?
}

@MainActor
final class ReadingViewportAccess {
    weak var controller: ReadingController?
    private let captureOverride: (() -> ReadingViewport?)?
    private let rangeOverride: (() -> (UInt64, UInt64)?)?
    init(capture: (() -> ReadingViewport?)? = nil, range: (() -> (UInt64, UInt64)?)? = nil) { captureOverride = capture; rangeOverride = range }
    func statisticsRange() -> (UInt64, UInt64)? { rangeOverride.map { $0() } ?? controller?.statisticsRange() }
    func capture() -> ReadingViewport? { captureOverride.map { $0() } ?? controller?.captureViewport() }
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

/// TextKit 1 is explicit here: the same native glyph layout drives text selection,
/// visible-line anchors and fixed-height page containers. Rust bounds retained
/// payload independently of confirmed blank gaps; layout never scales with the book.
@MainActor
final class ReadingController: UIViewController, UITextViewDelegate, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    var openingID: UUID?
    var requestWindow: (ReadingDirection, SourceSpan) -> Bool = { _,_ in false }
    private var requestedFrontiers = ReadingFrontierAdmissions()
    private var diagnosedOpening: UUID?
    #if READER_OPEN_DIAGNOSTICS
    private var displayProbe: ReaderDisplayProbe?
    #endif
    var statisticsInteraction: () -> Void = {}

    func statisticsRange() -> (UInt64, UInt64)? {
        guard !isCoverVisible, !rebuilding, !needsRebuild, !pageTransitioning,
              viewIfLoaded?.window != nil, let text = activeTextView, !text.text.isEmpty else { return nil }
        let rect = text.bounds.offsetBy(dx: -text.textContainerInset.left, dy: -text.textContainerInset.top)
        let glyphs = text.layoutManager.glyphRange(forBoundingRect: rect, in: text.textContainer)
        let chars = text.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0 else { return nil }
        let mapping = textCoordinates(text), base = textBase(text)
        let clipped = NSIntersectionRange(chars, (text as! ReadingTextView).readingText.selectableRange)
        guard let envelope = mapping.sourceRange(clipped), !envelope.isEmpty else { return nil }
        return (base+UInt64(envelope.lowerBound), base+UInt64(envelope.upperBound))
    }
    func selectedSourceRange() -> (UInt64, UInt64)? {
        guard let text = activeTextView else { return nil }
        let range = text.selectedRange
        guard range.length > 0, NSMaxRange(range) <= text.textStorage.length else { return nil }
        let mapping = textCoordinates(text)
        let base = textBase(text)
        guard let envelope = mapping.sourceRange(range) else { return nil }
        return (min(selectionStart ?? (base + UInt64(envelope.lowerBound)), base + UInt64(envelope.lowerBound)), max(selectionStart ?? (base + UInt64(envelope.upperBound)), base + UInt64(envelope.upperBound)))
    }
    let backNavigation = ReaderBackNavigation()
    let deviceControls = ReaderDeviceControls()
    var allowsChapterEditing = true
    var allowsSelection = true {
        didSet { if allowsSelection != oldValue { visibleTextViews.forEach { $0.isSelectable = allowsSelection && !isCoverVisible } } }
    }
    var allowsBackGesture = false
    private let readingSurface = UIView()
    private let bottomFade = CAGradientLayer()
    private var stableInsets = UIEdgeInsets.zero
    private var insetSize = CGSize.zero
    /// Only an inline first-use guide reserves space. Sheets still keep the full reader viewport.
    var guideHeight: CGFloat = 0 {
        didSet { if guideHeight != oldValue { view.setNeedsLayout() } }
    }
    private var controlsVisible = false
    private var toggleControls: (() -> Void)?
    private var readingBegan: (() -> Void)?
    private var window: ReadingWindow?
    private var settings: ReaderSettings?
    private var anchor: UInt64 = 0
    private var dark = false
    private var theme = ThemeSurface.initial
    private let ink = ReadingInk()
    private var reduceMotion = false
    private var typeSize: DynamicTypeSize = .large
    private var changed: ((UInt64, Bool) -> Void)?
    private var scrollText: ScrollReadingTextView?
    private var pageController: UIPageViewController?
    private var pages: [TextPage] = []
    private var renderedSize: CGSize = .zero
    private var rebuilding = false
    private var needsRebuild = true
    private var reportGeneration = 0
    private var pageTransitioning = false
    private var programmaticPageTransition = false
    private var compactHeaderHeight: CGFloat = 0
    private var preservePageBoundaries = false
    private var pendingWindow: ReadingWindow?
    private var navigationRevision = 0
    private var pendingNavigation: (request: ReadingNavigation, keepVisible: Bool)?
    private var edgeChanged: ((Bool) -> Void)?
    private var reportedEdge = false
    private var annotations: [ReaderMark] = []
    private var preparingAnnotationMenu = false
    private weak var annotationMenuText: UITextView?
    private var tappedAnnotation: (context: AnnotationSelection, range: NSRange)?
    private var bookmarkPositions: [UInt64] = []
    private var focusRange: TextRange?
    private var selectionStart: UInt64?
    private var selection: ((UInt64, UInt64, ReaderSelectionAction) -> Void)?
    private var coverTitle: String?
    private var coverInformation: BookDetails?
    private var showBookDetails: () -> Void = {}
    private var isCoverVisible = false
    private var coverChanged: ((Bool) -> Void)?
    private var scrollCover: ReaderCoverController?
    private var hasCover: Bool { coverTitle != nil && window?.isStartOfBook == true }

    override func loadView() {
        view = UIView()
        view.backgroundColor = theme.paper
        view.addSubview(readingSurface)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(tappedBody(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(ignoredDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        for recognizer in [singleTap, doubleTap] {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            readingSurface.addGestureRecognizer(recognizer)
        }
        // Wait for a possible second tap without stealing native word selection.
        singleTap.require(toFail: doubleTap)
        backNavigation.canBegin = { [weak self] in
            guard let self, allowsBackGesture,
                  selectionStart == nil, !rebuilding, !pageTransitioning else { return false }
            guard let text = activeTextView else { return isCoverVisible }
            // A new touch can interrupt scrolling and begin a native back gesture.
            // Gesture arbitration handles the text view pan; inertia is not a lock.
            return text.selectedRange.length == 0
        }
        backNavigation.readingPan = { [weak self] in
            self?.scrollText?.panGestureRecognizer ?? self?.pageController?.view.subviews.compactMap { $0 as? UIScrollView }.first?.panGestureRecognizer
        }
        backNavigation.allowsContentGesture = { [weak self] in self?.settings?.mode == .scroll }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        backNavigation.install(on: self)
        deviceControls.start(in: view.window?.windowScene)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        backNavigation.uninstall()
        deviceControls.stop()
    }

    func configure(window: ReadingWindow, settings: ReaderSettings, anchor: UInt64,
                   dark: Bool, typeSize: DynamicTypeSize, theme: ThemeSurface? = nil, reduceMotion: Bool = false,
                   navigationRevision: Int = 0, navigation: ReadingNavigation? = nil,
                   annotations: [ReaderMark] = [], bookmarkPositions: [UInt64] = [], focusRange: TextRange? = nil,
                   selectionStart: UInt64? = nil, selection: @escaping (UInt64, UInt64, ReaderSelectionAction) -> Void = { _, _, _ in },
                   edgeChanged: @escaping (Bool) -> Void = { _ in },
                   coverTitle: String? = nil, coverInformation: BookDetails? = nil, showBookDetails: @escaping () -> Void = {},
                   showingCover: Bool = false, coverChanged: @escaping (Bool) -> Void = { _ in },
                   compactHeaderHeight: CGFloat,
                   controlsVisible: Bool, toggleControls: @escaping () -> Void,
                   readingBegan: @escaping () -> Void, changed: @escaping (UInt64, Bool) -> Void) {
        let contentsChanged = self.window != window
        if contentsChanged { requestedFrontiers.reset() }
        let oldWindow = self.window
        let navigating = self.navigationRevision != navigationRevision
        let layoutChanged = !settings.hasSameLayout(as: self.settings) || self.typeSize != typeSize
            || (self.window?.chunks == window.chunks && self.window?.paragraphs != window.paragraphs)
            || self.compactHeaderHeight != compactHeaderHeight
        if navigating {
            reportGeneration += 1 // Ignore movement callbacks queued before the jump.
            pageTransitioning = false
            programmaticPageTransition = false
            pendingNavigation = (navigation ?? ReadingNavigation(), !contentsChanged && !layoutChanged && !needsRebuild)
        }
        let nextTheme = theme ?? ThemeSurface(plan: try! resolveThemes(value: defaultThemeSnapshot(), system: dark ? .dark : .light, highContrast: false).reader)
        let appearanceChanged = self.theme != nextTheme
        self.theme = nextTheme
        self.reduceMotion = reduceMotion
        ink.set(nextTheme.ink)
        overrideUserInterfaceStyle = nextTheme.style
        view.backgroundColor = nextTheme.paper
        if layoutChanged { preservePageBoundaries = false }
        else if contentsChanged { preservePageBoundaries = true }
        self.settings = settings
        self.anchor = anchor
        self.dark = dark
        self.typeSize = typeSize
        self.changed = changed
        self.controlsVisible = controlsVisible
        self.toggleControls = toggleControls
        self.readingBegan = readingBegan
        self.compactHeaderHeight = compactHeaderHeight
        self.navigationRevision = navigationRevision
        self.edgeChanged = edgeChanged
        self.coverTitle = coverTitle
        self.coverInformation = coverInformation; self.showBookDetails = showBookDetails
        self.coverChanged = coverChanged
        if !isInteracting { isCoverVisible = showingCover }
        scrollCover?.update(title: coverTitle ?? "", information: coverInformation, showDetails: showBookDetails, theme: nextTheme)
        for case let cover as ReaderCoverController in pageController?.children ?? [] { cover.update(title: coverTitle ?? "", information: coverInformation, showDetails: showBookDetails, theme: nextTheme) }
        // Note text and drafts do not change the visible highlight ranges.
        let sameRanges = self.annotations.count == annotations.count
            && zip(self.annotations, annotations).allSatisfy {
                $0.startUtf8 == $1.startUtf8 && $0.endUtf8 == $1.endUtf8
            }
        let decorationsChanged = !sameRanges || self.focusRange != focusRange || self.bookmarkPositions != bookmarkPositions
        self.annotations = annotations; self.focusRange = focusRange
        self.bookmarkPositions = bookmarkPositions
        self.selectionStart = selectionStart; self.selection = selection
        if contentsChanged && !layoutChanged && !navigating && isInteracting {
            pendingWindow = window
            if let previous = oldWindow, let text = scrollText, text.selectedRange.length == 0, window.end > previous.end {
                // Even an append can make UITextView reveal its selection.
                // Keep the document fixed until native handle dragging ends.
                let merged = previous.chunks + window.chunks.filter { $0.startUtf8 >= previous.end }
                if Set(merged.map(\.index)).count <= 256 && merged.reduce(0, { $0+$1.text.utf8.count }) <= 65536 {
                    let paragraphs = previous.paragraphs.filter { $0.startUtf8 < window.start } + window.paragraphs
                    var combined = window
                    combined.chunks = merged; combined.paragraphs = paragraphs
                    combined.sourceStart = previous.start; combined.omitted = previous.omitted + window.omitted
                    combined.previousCursor = previous.previousCursor; combined.isStartOfBook = previous.isStartOfBook
                    appendScrollContents(combined)
                }
            }
        } else {
            pendingWindow = nil
            self.window = window
            if contentsChanged && !layoutChanged, let oldWindow, !needsRebuild {
                if navigating {
                    replaceNavigationContents()
                } else if scrollText != nil, window.start == oldWindow.start, window.end > oldWindow.end {
                    self.window = oldWindow
                    if !appendScrollContents(window) { self.window = window; replaceContents(from: oldWindow) }
                } else {
                    replaceContents(from: oldWindow)
                }
            }
        }
        if layoutChanged || (contentsChanged && oldWindow == nil) {
            needsRebuild = true
            view.setNeedsLayout()
        }
        if navigating { view.setNeedsLayout() }
        if let text = activeTextView { configureAccessibility(text) }
        updateBottomFade()
        if decorationsChanged || appearanceChanged { decorateVisibleText() }
        if appearanceChanged {
            // Dynamic foreground paint affects drawing, never text storage or
            // pagination. Selection, line geometry and position stay intact.
            for text in visibleTextViews {
                text.layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: text.textStorage.length))
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let window = view.window, view.bounds.width > 60, view.bounds.height > 60 else { return }
        // SwiftUI fills the window even when the status bar appears. Reserve the
        // hardware safe area here, independently of the overlay controls. Keep
        // the larger inset for this size so status-bar changes cannot reflow text.
        let insets = window.safeAreaInsets
        // This controller is the full-screen reader. A presented sheet can
        // animate SwiftUI's container height by the bottom safe area; that is
        // chrome motion, not a new text viewport. Use this scene's actual size.
        let viewport = CGRect(origin: .zero, size: window.bounds.size)
        if insetSize != viewport.size {
            insetSize = viewport.size
            stableInsets = insets
        }
        stableInsets.top = max(stableInsets.top, insets.top)
        stableInsets.bottom = max(stableInsets.bottom, insets.bottom)
        stableInsets.left = max(stableInsets.left, insets.left)
        stableInsets.right = max(stableInsets.right, insets.right)
        if viewport.height > viewport.width {
            stableInsets.top = max(stableInsets.top, 20)
        }
        var contentInsets = stableInsets
        contentInsets.top += compactHeaderHeight
        // The bottom safe area is a drawing overlay in scroll mode, not an
        // empty strip removed from the text viewport.
        if settings?.mode == .scroll { contentInsets.bottom = 0 }
        if guideHeight > 0 { contentInsets.bottom = max(contentInsets.bottom, guideHeight + insets.bottom) }
        readingSurface.frame = viewport.inset(by: contentInsets)
        updateBottomFade()
        if needsRebuild || renderedSize != readingSurface.bounds.size {
            if renderedSize != readingSurface.bounds.size { preservePageBoundaries = false }
            renderedSize = readingSurface.bounds.size
            rebuild()
            pendingNavigation?.keepVisible = false
        }
        applyNavigation()
        if let id = openingID, diagnosedOpening != id, !needsRebuild {
            diagnosedOpening = id
            ReaderOpenDiagnostics.mark(id, "layoutCompleted")
            ReaderOpenDiagnostics.mark(id, isCoverVisible ? "coverLayout" : "bodyLayout")
            #if READER_OPEN_DIAGNOSTICS
            displayProbe = ReaderDisplayProbe(view: view, id: id, cover: isCoverVisible, glyphsVisible: { [weak self] in self?.diagnosticGlyphsVisible() ?? false }) { [weak self] in self?.displayProbe = nil }
            #endif
        }
    }

    #if READER_OPEN_DIAGNOSTICS
    private func diagnosticGlyphsVisible() -> Bool {
        guard let text = activeTextView, let window = text.window else { return false }
        let visible = text.convert(window.bounds, from: window).intersection(text.bounds)
            .offsetBy(dx: -text.textContainerInset.left, dy: -text.textContainerInset.top)
        guard !visible.isEmpty else { return false }
        let glyphs = text.layoutManager.glyphRange(forBoundingRect: visible, in: text.textContainer)
        guard glyphs.length > 0 else { return false }
        let chars = text.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        guard chars.length > 0, NSMaxRange(chars) <= text.textStorage.length else { return false }
        return !(text.textStorage.string as NSString).substring(with: chars).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    #endif

    private var activeTextView: UITextView? {
        scrollText ?? pageController?.viewControllers?.first?.view as? UITextView
    }

    @objc private func tappedBody(_ gesture: UITapGestureRecognizer) {
        statisticsInteraction()
        if let text = activeTextView {
            let ids = annotationIDs(at: gesture.location(in: text), in: text)
            if !ids.isEmpty { showAnnotations(ids, in: text); return }
        }
        if controlsVisible || settings?.mode != .pages { toggleControls?(); return }
        let fraction = gesture.location(in: readingSurface).x / max(1, readingSurface.bounds.width)
        if fraction < 0.28 { movePage(-1) }
        else if fraction > 0.72 { movePage(1) }
        else { toggleControls?() }
    }
    @objc private func ignoredDoubleTap() { statisticsInteraction() }

    // Glyph hit testing rejects the blank margin and line spacing. A tap on
    // highlighted text wins over edge paging, while long presses still select.
    func annotationIDs(at point: CGPoint, in text: UITextView) -> [String] {
        let local = CGPoint(x: point.x - text.textContainerInset.left, y: point.y - text.textContainerInset.top)
        guard local.x >= 0, local.y >= 0, text.textStorage.length > 0 else { return [] }
        let manager = text.layoutManager
        let glyph = manager.glyphIndex(for: local, in: text.textContainer)
        guard glyph < manager.numberOfGlyphs else { return [] }
        let glyphRange = NSRange(location: glyph, length: 1)
        let rect = manager.boundingRect(forGlyphRange: glyphRange, in: text.textContainer)
        guard rect.width > 0, rect.contains(local) else { return [] }
        let chars = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let mapping = textCoordinates(text)
        let base = textBase(text)
        guard let envelope = mapping.sourceRange(chars) else { return [] }
        let start = base+UInt64(envelope.lowerBound), end = base+UInt64(envelope.upperBound)
        return annotations.filter { $0.startUtf8 < end && $0.endUtf8 > start }.map(\.id)
    }

    private func showAnnotations(_ ids: [String], in text: UITextView, choosing: Bool = false) {
        guard let first = annotations.first(where: { ids.contains($0.id) }) else { return }
        if !choosing || ids.count == 1 { showAnnotationMenu(first, in: text); return }
        let menu = UIAlertController(title: String(localized: "选择标注"), message: nil, preferredStyle: .actionSheet)
        for mark in annotations where ids.contains(mark.id) {
            let summary = (mark.note.isEmpty ? mark.excerpt : mark.note)
            menu.addAction(UIAlertAction(title: String(summary.prefix(80)), style: .default) { [weak self, weak text] _ in
                if let text { self?.showAnnotationMenu(mark, in: text) }
            })
        }
        menu.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        menu.popoverPresentationController?.sourceView = text
        menu.popoverPresentationController?.sourceRect = CGRect(x: text.bounds.midX, y: text.bounds.midY, width: 1, height: 1)
        present(menu, animated: true)
    }

    func showAnnotationMenu(_ mark: ReaderMark, in text: UITextView) {
        guard let text = text as? ReadingTextView else { return }
        let context = AnnotationSelection(start: mark.startUtf8, end: mark.endUtf8, annotations: annotations)
        guard !context.marks.isEmpty else { return }
        let mapping = textCoordinates(text), base = textBase(text)
        guard context.end > base, context.start < base+UInt64(mapping.byteCount),
              let range = mapping.displayRange(Int(max(base,context.start)-base)..<Int(min(base+UInt64(mapping.byteCount),context.end)-base)), range.length > 0 else { return }
        let from = range.location, to = NSMaxRange(range)
        let offset = text.contentOffset
        preparingAnnotationMenu = true
        defer { preparingAnnotationMenu = false }
        text.becomeFirstResponder()
        annotationMenuText = text
        tappedAnnotation = (context, NSRange(location: from, length: to - from))
        // Enter through UITextView's native selection command so it supplies
        // the same deferred lookup/translation actions as a long press.
        text.presentSelectionMenu(for: NSRange(location: from, length: to - from))
        setSelectionDisplay(text, active: false)
        text.setContentOffset(offset, animated: false)
    }

    private func setSelectionDisplay(_ text: UITextView, active: Bool) {
        for interaction in text.interactions.compactMap({ $0 as? UITextSelectionDisplayInteraction }) {
            // Keep native interaction active so its edit menu and text services
            // still work. Hide only its public display views for a tap.
            interaction.highlightView.alpha = active ? 1 : 0
            interaction.cursorView.alpha = active ? 1 : 0
            interaction.handleViews.forEach { $0.alpha = active ? 1 : 0 }
        }
    }

    private func endAnnotationMenu(clearSelection: Bool) {
        guard let text = annotationMenuText else { return }
        tappedAnnotation = nil; annotationMenuText = nil
        if clearSelection {
            text.selectedRange = NSRange(location: text.selectedRange.location, length: 0)
            text.resignFirstResponder()
        }
        setSelectionDisplay(text, active: true)
    }

    func textView(_ textView: UITextView, willPresentEditMenuWith animator: any UIEditMenuInteractionAnimating) {
        guard textView === annotationMenuText else { return }
        setSelectionDisplay(textView, active: false)
        animator.addCompletion { [weak self, weak textView] in
            if let self, let textView, textView === self.annotationMenuText { self.setSelectionDisplay(textView, active: false) }
        }
    }

    func textView(_ textView: UITextView, willDismissEditMenuWith animator: any UIEditMenuInteractionAnimating) {
        if !preparingAnnotationMenu, textView === annotationMenuText { endAnnotationMenu(clearSelection: true) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard !UIAccessibility.isVoiceOverRunning, !pageTransitioning else { return false }
        if let text = activeTextView {
            guard text.selectedRange.length == 0, !text.isDragging, !text.isDecelerating else { return false }
        } else if !isCoverVisible { return false }
        var touchedView = touch.view
        while let candidate = touchedView {
            if candidate is UIControl { return false }
            if candidate === readingSurface { break }
            touchedView = candidate.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Native multi-tap selection must still receive the same touches.
        otherGestureRecognizer is UITapGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 1 else { return false }
        if let otherTap = otherGestureRecognizer as? UITapGestureRecognizer {
            return otherTap.numberOfTapsRequired > 1
        }
        return otherGestureRecognizer is UILongPressGestureRecognizer
    }

    private func configureAccessibility(_ text: UITextView) {
        (text as? ReadingTextView)?.copySelection = { [weak self] start, end in
            guard let self else { return }
            selection?(min(selectionStart ?? start, start), max(selectionStart ?? end, end), .copy)
        }
        text.isSelectable = allowsSelection && !isCoverVisible
        text.accessibilityLabel = isCoverVisible ? String(localized: "封面，\(coverTitle ?? "")") : (text as? ReadingTextView)?.readingText.text
        text.accessibilityValue = isCoverVisible ? "" : nil
        text.accessibilityCustomActions = [UIAccessibilityCustomAction(name: controlsVisible ? String(localized: "隐藏阅读工具") : String(localized: "显示阅读工具")) { [weak self] _ in
            self?.toggleControls?()
            return true
        }]
        if isCoverVisible {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { text.accessibilityValue = String(anchor) }
            text.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: String(localized: "开始阅读")) { [weak self, weak text] _ in
                guard let self, let text else { return false }
                text.setContentOffset(CGPoint(x: 0, y: self.scrollCoverHeight), animated: !reduceMotion)
                reportCover(false); report(window.flatMap { ReadingText($0).firstVisibleOffset } ?? anchor, settled: true)
                return true
            })
            return
        }
        if settings?.mode == .pages {
            text.accessibilityCustomActions?.append(contentsOf: [
                UIAccessibilityCustomAction(name: String(localized: "上一页")) { [weak self] _ in
                    self?.movePage(-1)
                    return true
                },
                UIAccessibilityCustomAction(name: String(localized: "下一页")) { [weak self] _ in
                    self?.movePage(1)
                    return true
                }
            ])
        }
        if !annotations.isEmpty {
            text.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: String(localized: "查看屏幕内标注")) { [weak self, weak text] _ in
                guard let self, let text else { return false }
                let visible = text.bounds.offsetBy(dx: -text.textContainerInset.left, dy: -text.textContainerInset.top)
                let glyphs = text.layoutManager.glyphRange(forBoundingRect: visible, in: text.textContainer)
                let chars = text.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
                let mapping = self.textCoordinates(text)
                let base = self.textBase(text)
                let clipped = NSIntersectionRange(chars,(text as! ReadingTextView).readingText.selectableRange)
                guard let envelope = mapping.sourceRange(clipped) else { return false }
                let start = base+UInt64(envelope.lowerBound), end = base+UInt64(envelope.upperBound)
                let ids = self.annotations.filter { $0.startUtf8 < end && $0.endUtf8 > start }.map(\.id)
                guard !ids.isEmpty else { return false }
                self.showAnnotations(ids, in: text, choosing: true)
                return true
            })
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            text.accessibilityValue = String(anchor)
        }
    }

    private func makePage(at index: Int) -> UIViewController {
        if index == -1 { return makeCover() }
        let controller = PageController(page: pages[index], index: index)
        if let text = controller.view as? UITextView { text.delegate = self; configureAccessibility(text); decorate(text, base: controller.page.start) }
        return controller
    }

    private func makeCover() -> ReaderCoverController {
        let cover = ReaderCoverController(title: coverTitle ?? "", information: coverInformation, showDetails: showBookDetails, theme: theme)
        cover.view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "显示阅读工具")) { [weak self] _ in self?.toggleControls?(); return true },
            UIAccessibilityCustomAction(name: String(localized: "开始阅读")) { [weak self] _ in
                guard let self else { return false }
                if let text = scrollText {
                    text.setContentOffset(CGPoint(x: 0, y: self.scrollCoverHeight), animated: !reduceMotion)
                    reportCover(false); report(window.flatMap { ReadingText($0).firstVisibleOffset } ?? anchor, settled: true)
                } else { movePage(1) }
                return true
            }
        ]
        return cover
    }

    private var scrollCoverHeight: CGFloat { hasCover ? readingSurface.bounds.height : 0 }

    private func updateScrollCover(in text: UITextView) {
        (text as? ScrollReadingTextView)?.bodyStart = hasCover ? 2 : 0
        if hasCover {
            if scrollCover == nil {
                let cover = makeCover()
                addChild(cover); text.addSubview(cover.view); cover.didMove(toParent: self)
                scrollCover = cover
            }
            let height = readingSurface.bounds.height
            if text.textContainerInset != textInsets { text.textContainerInset = textInsets }
            scrollCover?.view.frame = CGRect(x: 0, y: 0, width: text.bounds.width, height: height)
        } else {
            removeScrollCover()
            if text.textContainerInset != textInsets { text.textContainerInset = textInsets }
        }
    }

    private func removeScrollCover() {
        scrollCover?.willMove(toParent: nil)
        scrollCover?.view.removeFromSuperview()
        scrollCover?.removeFromParent()
        scrollCover = nil
    }

    private func reportCover(_ visible: Bool) {
        guard isCoverVisible != visible else { return }
        isCoverVisible = visible
        if let text = activeTextView { configureAccessibility(text) }
        let generation = reportGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == reportGeneration else { return }
            coverChanged?(visible)
        }
    }

    private func pageIndex(_ controller: UIViewController?) -> Int? {
        if controller is ReaderCoverController { return -1 }
        return (controller as? PageController)?.index
    }

    private func reportPage(_ index: Int) {
        reportCover(index == -1)
        if pages.indices.contains(index) {
            report(pages[index].firstVisibleOffset, settled: true)
            if index >= pages.count-2 { requestMore(.forward) }
            if index <= 1 { requestMore(.backward) }
        }
    }

    private func textBase(_ text: UITextView) -> UInt64 {
        // During deferred replacement the native view still owns its old
        // projection. Never pair that mapping with the new window's base.
        (text as! ReadingTextView).readingText.sourceStart
    }

    private func textCoordinates(_ text: UITextView) -> TextCoordinates {
        (text as! ReadingTextView).readingText.coordinates
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0 else { return UIMenu(children: suggestedActions) }
        let context: AnnotationSelection
        if textView === annotationMenuText, let tappedAnnotation { context = tappedAnnotation.context }
        else {
            let mapping = textCoordinates(textView), base = textBase(textView)
            guard let envelope = mapping.sourceRange(range) else { return UIMenu(children: suggestedActions) }
            let from = base + UInt64(envelope.lowerBound)
            let to = base + UInt64(envelope.upperBound)
            context = AnnotationSelection(start: min(selectionStart ?? from, from), end: max(selectionStart ?? to, to), annotations: annotations)
        }
        return selectionMenu(for: context, suggestedActions: suggestedActions) { [weak self, weak textView] kind in
            self?.endAnnotationMenu(clearSelection: true)
            textView?.selectedRange = NSRange(location: range.location, length: 0)
            textView?.resignFirstResponder()
            self?.selection?(context.start, context.end, kind)
        }
    }

    /// One menu policy for both native long-press selection and annotation taps.
    func selectionMenu(for context: AnnotationSelection, suggestedActions: [UIMenuElement], perform: @escaping (ReaderSelectionAction) -> Void) -> UIMenu {
        func action(_ title: String, _ symbol: String, _ kind: ReaderSelectionAction, destructive: Bool = false) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? .destructive : []) { _ in perform(kind) }
        }
        let overlaps = !context.marks.isEmpty
        var primary: [UIMenuElement] = overlaps
            ? [action(String(localized: "编辑批注"), "square.and.pencil", .comment),
               action(String(localized: "移除批注"), "trash", .removeAnnotations, destructive: true)]
            : [action(String(localized: "标注"), "highlighter", .highlight)]
        primary += [action(String(localized: "拷贝"), "doc.on.doc", .copy),
                    action(String(localized: "全文搜索"), "magnifyingglass", .search)]
        // Preserve the native lookup group, including deferred system commands
        // such as Search Web. Both entry points reach UITextView's responder chain.
        var lookup: [UIMenuElement] = [], secondary: [UIMenuElement] = []
        for element in mergingLearnAndShare(suggestedActions) {
            if let menu = element as? UIMenu, menu.identifier == .standardEdit {
                secondary += menu.children.filter { element in
                    guard let command = element as? UICommand else { return true }
                    return command.action != #selector(UIResponderStandardEditActions.copy(_:))
                }
            } else if let menu = element as? UIMenu, menu.identifier == .lookup { lookup.append(menu) }
            else { secondary.append(element) }
        }
        var notes: [UIMenuElement] = []
        if !overlaps { notes.append(action(selectionStart != nil ? String(localized: "批注到这里") : String(localized: "写批注"), "square.and.pencil", .comment)) }
        notes.append(action(String(localized: "批注整段"), "paragraphsign", .paragraph))
        var tools: [UIMenuElement] = [action(String(localized: "从这里跨页选取"), "text.cursor", .beginRange)]
        if allowsChapterEditing { tools.append(action(String(localized: "设为章节"), "list.bullet", .chapter)) }
        // Notes and tools share one inline group: one separator fewer before the last reader actions.
        return UIMenu(children: [UIMenu(options: .displayInline, children: primary)] + lookup + secondary
                      + [UIMenu(options: .displayInline, children: notes + tools)])
    }

    /// 学习… and 共享… arrive as separate inline groups, at times with the speech group between
    /// them. One untitled inline group holds their original items, and the speech group itself,
    /// in the same order. Any other arrangement is left as supplied.
    private func mergingLearnAndShare(_ elements: [UIMenuElement]) -> [UIMenuElement] {
        func inline(_ element: UIMenuElement, _ identifier: UIMenu.Identifier) -> UIMenu? {
            guard let menu = element as? UIMenu, menu.identifier == identifier, menu.options == .displayInline else { return nil }
            return menu
        }
        guard let start = elements.firstIndex(where: { inline($0, .learn) != nil }), let learn = inline(elements[start], .learn) else { return elements }
        var end = start + 1, middle: [UIMenuElement] = []
        if end < elements.count, let speech = inline(elements[end], .speech) { middle = [speech]; end += 1 }
        guard end < elements.count, let share = inline(elements[end], .share) else { return elements }
        var merged = elements
        merged.replaceSubrange(start...end, with: [UIMenu(options: .displayInline, children: learn.children + middle + share.children)])
        return merged
    }

    private var visibleTextViews: [UITextView] {
        if let scrollText { return [scrollText] }
        return pageController?.children.compactMap { $0.viewIfLoaded as? UITextView } ?? []
    }

    private func decorateVisibleText() {
        if let text = scrollText { decorate(text, base: window?.start ?? 0) }
        for case let page as PageController in pageController?.children ?? [] {
            if let text = page.viewIfLoaded as? UITextView { decorate(text, base: page.page.start) }
        }
    }
    private func decorate(_ text: UITextView, base: UInt64) {
        guard let layout = text.layoutManager as? ReadingLayoutManager else { return }
        text.backgroundColor = theme.paper
        text.tintColor = theme.selection
        let mapping = textCoordinates(text)
        let end = base + UInt64(mapping.byteCount)
        func local(_ start: UInt64, _ finish: UInt64) -> NSRange? {
            guard start < end, finish > base else { return nil }
            return mapping.displayRange(Int(max(base,start)-base)..<Int(min(end,finish)-base))
        }
        // Merge overlapping annotations so their translucent fills do not stack.
        var ranges: [NSRange] = []
        for range in annotations.compactMap({ local($0.startUtf8, $0.endUtf8) }).sorted(by: { $0.location < $1.location }) {
            if let last = ranges.last, NSMaxRange(last) >= range.location {
                ranges[ranges.count - 1] = NSUnionRange(last, range)
            } else {
                ranges.append(range)
            }
        }
        var decorations: [ReadingLayoutManager.Decoration] = []
        let source = text.textStorage.string as NSString
        func add(_ range: NSRange, color: UIColor) {
            // Paragraph separators must not color blank space to the margin.
            var cursor = range.location
            while cursor < NSMaxRange(range) {
                let separator = source.rangeOfCharacter(from: .newlines, range: NSRange(location: cursor, length: NSMaxRange(range) - cursor))
                let end = separator.location == NSNotFound ? NSMaxRange(range) : separator.location
                if end > cursor {
                    decorations.append(.init(range: NSRange(location: cursor, length: end - cursor), color: color))
                }
                if separator.location == NSNotFound { break }
                cursor = NSMaxRange(separator)
            }
        }
        for range in ranges { add(range, color: theme.annotation) }
        if let focusRange, let range = local(focusRange.startUtf8, focusRange.endUtf8) {
            add(range, color: theme.searchCurrent)
        }
        layout.setDecorations(decorations)
        if let text = text as? ReadingTextView {
            // Page storage includes hidden lookahead for typography. Its marks
            // belong to the next page, even when the current layout sees them.
            let visibleLength = (text as? PageReadingTextView)?.visibleLength ?? text.textStorage.length
            let positions = bookmarkPositions.compactMap { position -> Int? in
                guard position >= base, position < end else { return nil }
                guard let index = mapping.displayPoint(Int(position-base)) else { return nil }
                return index < visibleLength ? index : nil
            }
            text.setBookmarks(positions, color: theme.accent)
        }
    }

    private func attributes() -> [NSAttributedString.Key: Any] {
        ReadingTypography.attributes(settings ?? defaultReaderSettings(), ink: ink.dynamic)
    }

    private var textInsets: UIEdgeInsets {
        ReadingTypography.insets(settings ?? defaultReaderSettings(), width: readingSurface.bounds.width)
    }

    private func styledText(_ window: ReadingWindow) -> NSAttributedString {
        ReadingTypography.text(window, settings: settings ?? defaultReaderSettings(), ink: ink.dynamic)
    }

    private func scrollProjection(_ window: ReadingWindow) -> ReadingText {
        let body = ReadingText(window)
        return hasCover ? body.prefixed("\u{fffc}\n") : body
    }

    private func styledScrollText(_ window: ReadingWindow) -> NSAttributedString {
        guard hasCover else { return styledText(window) }
        // A native attachment occupies document layout space. Insets stay small
        // so UIKit can autoscroll selection against the actual viewport edges.
        let attachment = NSTextAttachment()
        attachment.bounds = CGRect(x: 0, y: 0, width: 1, height: scrollCoverHeight)
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "\n"))
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = scrollCoverHeight
        paragraph.maximumLineHeight = scrollCoverHeight
        result.addAttributes([.font: UIFont.systemFont(ofSize: 1), .paragraphStyle: paragraph], range: NSRange(location: 0, length: result.length))
        result.append(styledText(window))
        return result
    }

    private func paginate(_ window: ReadingWindow, preserving previous: [TextPage] = [], keeping anchor: UInt64? = nil,
                         layout: ((ReadingText, Bool) -> [NSRange])? = nil) -> [TextPage] {
        TextPage.paginate(window, size: readingSurface.bounds.size, attributes: attributes(), source: styledText(window),
                          insets: textInsets, preserving: previous, keeping: anchor)
    }

    private var isInteracting: Bool {
        pageTransitioning || scrollText?.isDragging == true || scrollText?.isDecelerating == true
            || (activeTextView?.selectedRange.length ?? 0) > 0
    }

    private struct ScrollLineGeometry {
        let offset: UInt64
        let lineY: CGFloat
    }

    /// A reading anchor is a visible body line, not the nearest glyph to a
    /// point in the indentation or paragraph spacing. Keep source and Y paired.
    private func scrollLineGeometry(_ text: ReadingTextView) -> ScrollLineGeometry? {
        let visible = text.bounds.offsetBy(dx: -text.textContainerInset.left, dy: -text.textContainerInset.top)
        let manager = text.layoutManager
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: text.textContainer)
        guard glyphs.length > 0 else { return nil }
        var full: ScrollLineGeometry?, partial: ScrollLineGeometry?
        manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, range, stop in
            // Retained paragraph spaces still have line geometry even without
            // ink or used width. Paragraph spacing alone is not a line.
            guard used.height > 0, used.minY < visible.maxY, used.maxY > visible.minY else { return }
            let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            let body = NSIntersectionRange(characters, text.readingText.selectableRange)
            guard body.length > 0, let source = text.readingText.coordinates.sourcePoint(body.location) else { return }
            let line = ScrollLineGeometry(offset: text.readingText.sourceStart + UInt64(source), lineY: fragment.minY - visible.minY)
            if partial == nil { partial = line }
            if used.minY >= visible.minY && used.maxY <= visible.maxY {
                full = line; stop.pointee = true
            }
        }
        return full ?? partial
    }

    func captureViewport() -> ReadingViewport? {
        guard let settings, window != nil else { return nil }
        if isCoverVisible {
            return ReadingViewport(offset: 0, lineY: scrollText?.contentOffset.y ?? 0, size: renderedSize, settings: settings, typeSize: typeSize, pages: pages, isCover: true)
        }
        if let text = scrollText, text.textStorage.length > 0 {
            guard let line = scrollLineGeometry(text) else { return nil }
            return ReadingViewport(offset: line.offset, lineY: line.lineY,
                                   size: renderedSize, settings: settings, typeSize: typeSize, pages: [])
        }
        guard let current = pageController?.viewControllers?.first as? PageController else { return nil }
        return ReadingViewport(offset: current.page.firstVisibleOffset, lineY: 0, size: renderedSize,
                               settings: settings, typeSize: typeSize, pages: pages)
    }

    private var matchingRestoration: ReadingViewport? {
        guard let saved = pendingNavigation?.request.restoring,
              saved.size == readingSurface.bounds.size, saved.settings == settings, saved.typeSize == typeSize else { return nil }
        return saved
    }

    private func replaceNavigationContents() {
        guard let window else { return }
        rebuilding = true
        defer { rebuilding = false }
        if let text = scrollText {
            text.selectedRange = NSRange(location: 0, length: 0)
            updateScrollCover(in: text)
            text.textStorage.setAttributedString(styledScrollText(window))
            text.readingText = scrollProjection(window)
            text.layoutManager.ensureLayout(for: text.textContainer)
            text.layoutIfNeeded()
        } else {
            pages = paginate(window, preserving: pages)
        }
    }

    /// Coordinates here include the text container's inset, unlike TextKit's rectangles.
    private func targetRect(_ offset: UInt64, end: UInt64? = nil, in text: ReadingTextView) -> CGRect? {
        let projection = text.readingText
        guard offset >= projection.sourceStart, offset < projection.sourceEnd, text.textStorage.length > 0 else { return nil }
        guard let start = projection.coordinates.displayPoint(Int(offset - projection.sourceStart)) else { return nil }
        let finish = end.flatMap { projection.coordinates.displayPoint(Int(min(projection.sourceEnd,max(offset,$0))-projection.sourceStart)) } ?? start
        let range = NSRange(location: min(start, text.textStorage.length - 1), length: max(1, finish - start))
        let glyphs = text.layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = text.layoutManager.boundingRect(forGlyphRange: glyphs, in: text.textContainer)
        return rect.offsetBy(dx: text.textContainerInset.left, dy: text.textContainerInset.top)
    }

    private func contextViewport(in text: UITextView, bottomObstruction: CGFloat) -> CGRect {
        // A collapsed search sheet excludes the home-indicator safe area from
        // its detent height. The ordinary return pill needs the same clearance.
        let obstruction = max(bottomObstruction, UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: 60))
            + stableInsets.bottom + 12
        return CGRect(x: 0, y: text.contentOffset.y + ReadingTextMetrics.insets.top,
                      width: text.bounds.width,
                      height: max(44, text.bounds.height - ReadingTextMetrics.insets.top - obstruction))
    }

    func visibleWindow(containing offset: UInt64, end: UInt64?, bottomObstruction: CGFloat) -> ReadingWindow? {
        if let text = scrollText, let rect = targetRect(offset, end: end, in: text) {
            let visible = contextViewport(in: text, bottomObstruction: bottomObstruction).insetBy(dx: 0, dy: 8)
            if rect.minY >= visible.minY && rect.maxY <= visible.maxY { return window }
        } else if let current = pageController?.viewControllers?.first as? PageController,
                  offset >= current.page.start, offset < current.page.end { return window }
        return nil
    }

    private func applyNavigation() {
        guard let pending = pendingNavigation else { return }
        let restoration = matchingRestoration
        rebuilding = true
        defer {
            rebuilding = false
            pendingNavigation = nil
            decorateVisibleText()
            updateBottomFade()
            if let text = activeTextView { configureAccessibility(text) }
        }
        if let text = scrollText {
            if hasCover && (pending.request.placement == .cover || pending.request.restoring?.isCover == true) {
                let y: CGFloat
                if let restoration, restoration.isCover { y = max(0, min(scrollCoverHeight, restoration.lineY)) }
                else { y = 0 }
                text.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                reportCover(true)
                return
            }
            reportCover(false)
            let target = restoration?.offset ?? anchor
            guard let rect = targetRect(target, in: text) else { return }
            let desired: CGFloat
            if let restoration {
                // Restore the exact line position, including a partly clipped line.
                let character = text.readingText.coordinates.displayPoint(Int(target - text.readingText.sourceStart)) ?? 0
                let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
                let line = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                desired = line.minY + text.textContainerInset.top - restoration.lineY
            } else if pending.request.placement == .context {
                let visible = contextViewport(in: text, bottomObstruction: pending.request.bottomObstruction)
                let match = targetRect(target, end: focusRange?.endUtf8, in: text) ?? rect
                if pending.keepVisible && match.minY >= visible.minY + 8 && match.maxY <= visible.maxY - 8 { return }
                desired = rect.minY - ReadingTextMetrics.insets.top - visible.height / 3
            } else {
                // Align the line, not the glyph's ascender, to the normal top inset.
                let character = text.readingText.coordinates.displayPoint(Int(target - text.readingText.sourceStart)) ?? 0
                let glyph = text.layoutManager.glyphIndexForCharacter(at: character)
                desired = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            }
            let maximum = max(0, text.contentSize.height + text.contentInset.bottom - text.bounds.height)
            text.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, desired))), animated: false)
        } else if let paging = pageController, let window {
            if hasCover && (pending.request.placement == .cover || pending.request.restoring?.isCover == true) {
                paging.setViewControllers([makeCover()], direction: .reverse, animated: false)
                reportCover(true)
                updateEdge(false)
                return
            }
            reportCover(false)
            if let restoration {
                pages = paginate(window, preserving: restoration.pages, keeping: restoration.offset)
            }
            guard !pages.isEmpty else { return }
            let target = restoration?.offset ?? anchor
            let index = pages.lastIndex(where: { $0.start <= target }) ?? 0
            if let current = paging.viewControllers?.first as? PageController,
               current.page.start == pages[index].start, current.page.end == pages[index].end {
                current.update(page: pages[index], index: index)
            } else {
                let current = (paging.viewControllers?.first as? PageController)?.index ?? index
                paging.setViewControllers([makePage(at: index)], direction: index >= current ? .forward : .reverse, animated: false)
            }
            updateEdge(index == pages.count - 1)
        }
    }

    private func applyPendingWindow() {
        guard !isInteracting, let next = pendingWindow, let previous = window else { return }
        pendingWindow = nil
        let visible = captureViewport()?.offset ?? anchor
        guard next.chunks.contains(where:{visible >= $0.startUtf8 && visible < $0.endUtf8}) else { requestMore(visible < next.start ? .backward : .forward); return }
        window = next
        replaceContents(from: previous)
    }

    @discardableResult private func appendScrollContents(_ next: ReadingWindow) -> Bool {
        guard let previous = window, let text = scrollText, next.start == previous.start else { return false }
        let projection = scrollProjection(next)
        guard let start = projection.coordinates.displayPoint(Int(previous.end-next.start)), start < projection.coordinates.length,
              (projection.text as NSString).substring(to: start) == text.readingText.text else { return false }
        rebuilding = true
        let styled = styledScrollText(next)
        text.textStorage.append(styled.attributedSubstring(from: NSRange(location: start, length: styled.length - start)))
        text.readingText = projection
        window = next
        decorateVisibleText()
        configureAccessibility(text)
        // Appending below the viewport preserves its offset. Setting even the
        // same offset here cancels UIScrollView's ongoing touch/deceleration.
        rebuilding = false
        updateBottomFade()
        return true
    }

    // Keep the native view, visible line's baseline and selected text. Only the
    // bounded text window changes; ordinary background progress never gets here.
    private func replaceContents(from previous: ReadingWindow) {
        guard let window, let settings else { return }
        rebuilding = true
        defer {
            rebuilding = false; decorateVisibleText(); updateBottomFade()
            if let text = activeTextView { configureAccessibility(text) }
        }
        if let text = scrollText, text.textStorage.length > 0 {
            let coverOffset = previous.isStartOfBook && scrollCover != nil && isCoverVisible ? text.contentOffset.y : nil
            let line = scrollLineGeometry(text)
            guard coverOffset != nil || line != nil else { self.window = previous; return }
            if coverOffset == nil, let line, !(line.offset >= window.start && line.offset < window.end) {
                self.window = previous
                requestMore(line.offset < window.start ? .backward : .forward)
                return
            }
            text.textStorage.setAttributedString(styledScrollText(window))
            updateScrollCover(in: text)
            text.readingText = scrollProjection(window)
            text.layoutManager.ensureLayout(for: text.textContainer)
            text.layoutIfNeeded()
            if let coverOffset { text.setContentOffset(CGPoint(x: 0, y: coverOffset), animated: false); return }
            guard let line, let newCharacter = text.readingText.coordinates.displayPoint(Int(line.offset-text.readingText.sourceStart)) else { return }
            let newGlyph = text.layoutManager.glyphIndexForCharacter(at: min(newCharacter, text.textStorage.length - 1))
            let rect = text.layoutManager.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil)
            text.setContentOffset(CGPoint(x: 0, y: max(0, rect.minY + text.textContainerInset.top - line.lineY)), animated: false)
        } else if settings.mode == .pages, let paging = pageController,
                  let current = paging.viewControllers?.first as? PageController {
            guard current.page.start >= window.start, current.page.start < window.end else {
                self.window = previous; requestMore(current.page.firstVisibleOffset < window.start ? .backward : .forward); return
            }
            let visible = current.page.firstVisibleOffset
            pages = paginate(window,preserving:pages,keeping:visible)
            guard !pages.isEmpty else { return }
            let index = pages.lastIndex(where:{$0.start<=visible}) ?? 0
            current.update(page: pages[index], index: index)
            // Clear cached neighbours while retaining the visible controller.
            paging.setViewControllers([current], direction: .forward, animated: false)
            updateEdge(index == pages.count - 1)
        } else if let paging = pageController, paging.viewControllers?.first is ReaderCoverController {
            pages = paginate(window, preserving: pages)
            if let cover = paging.viewControllers?.first { paging.setViewControllers([cover], direction: .forward, animated: false) }
        }
    }

    private func rebuild() {
        guard let window, let settings else { return }
        rebuilding = true
        pageTransitioning = false
        programmaticPageTransition = false
        reportGeneration += 1
        defer { rebuilding = false; needsRebuild = false }
        removeScrollCover()
        scrollText?.removeFromSuperview()
        scrollText = nil
        if let pageController {
            pageController.delegate = nil
            pageController.dataSource = nil
            pageController.willMove(toParent: nil)
            pageController.view.removeFromSuperview()
            pageController.removeFromParent()
        }
        pageController = nil
        let previousPages = preservePageBoundaries ? pages : []
        pages = []
        preservePageBoundaries = false
        if settings.mode == .scroll {
            let storage = NSTextStorage()
            let manager = ReadingLayoutManager()
            let container = NSTextContainer(size: CGSize(width: ReadingTextMetrics.contentSize(in: readingSurface.bounds.size, insets: textInsets).width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            let text = ScrollReadingTextView(frame: readingSurface.bounds, textContainer: container)
            text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            text.isEditable = false
            text.isSelectable = allowsSelection
            text.alwaysBounceVertical = true
            text.showsVerticalScrollIndicator = false
            text.showsHorizontalScrollIndicator = false
            text.backgroundColor = theme.paper
            text.contentInsetAdjustmentBehavior = .never
            text.contentInset.bottom = ReadingTextMetrics.scrollFadeHeight(bottomSafeArea: stableInsets.bottom)
            text.textContainerInset = textInsets
            // Populate after UITextView has configured the typesetter, just as
            // for later window replacements (including fallback emoji fonts).
            storage.setAttributedString(styledScrollText(window))
            text.accessibilityIdentifier = "scrollText"
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { text.accessibilityValue = String(anchor) }
            readingSurface.addSubview(text)
            updateScrollCover(in: text)
            readingSurface.layer.addSublayer(bottomFade)
            text.layoutManager.ensureLayout(for: container)
            text.layoutIfNeeded()
            text.readingText = scrollProjection(window)
            let local = Int(min(anchor - min(anchor, text.readingText.sourceStart), UInt64(text.readingText.coordinates.byteCount)))
            let character = text.readingText.coordinates.displayPoint(local) ?? 0
            if storage.length > 0 {
                let glyph = manager.glyphIndexForCharacter(at: min(character, storage.length - 1))
                let rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let y = min(max(0, rect.minY), max(0, text.contentSize.height + text.contentInset.bottom - text.bounds.height))
                text.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            }
            if hasCover && isCoverVisible { text.setContentOffset(.zero, animated: false) }
            scrollText = text
            text.onLayout = { [weak self] in self?.updateBottomFade() }
            text.delegate = self
            configureAccessibility(text)
        } else {
            pages = paginate(window, preserving: previousPages)
            guard !pages.isEmpty else { return }
            let paging = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
            paging.dataSource = self
            paging.delegate = self
            addChild(paging)
            paging.view.frame = readingSurface.bounds
            paging.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            readingSurface.addSubview(paging.view)
            paging.didMove(toParent: self)
            pageController = paging
            let index = hasCover && isCoverVisible ? -1 : (pages.lastIndex(where: { $0.start <= anchor }) ?? 0)
            paging.setViewControllers([makePage(at: index)], direction: .forward, animated: false)
        }
        decorateVisibleText()
        updateBottomFade()

    }

    private func updateBottomFade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        bottomFade.isHidden = settings?.mode != .scroll
        let height = min(ReadingTextMetrics.scrollFadeHeight(bottomSafeArea: stableInsets.bottom), readingSurface.bounds.height)
        bottomFade.frame = CGRect(x: 0, y: readingSurface.bounds.height - height,
                                  width: readingSurface.bounds.width, height: height)
        let paper = theme.paper
        bottomFade.colors = [paper.withAlphaComponent(0).cgColor, paper.cgColor]
        bottomFade.locations = [0, 1]
        guard let text = scrollText else { bottomFade.opacity = 0; return }
        // End padding is scrollable, so the final line can leave the fade. It
        // does not shorten the viewport while reading the rest of the book.
        if text.contentInset.bottom != height { text.contentInset.bottom = height }
        // At the end of text, leave the final complete line fully readable.
        let remaining = max(0, text.contentSize.height + text.contentInset.bottom - text.bounds.height - text.contentOffset.y)
        bottomFade.opacity = ReadingTextMetrics.fadeOpacity(remaining: remaining, isEndOfBook: window?.isEndOfBook == true,
                                                          isPreparedTail: window?.isPreparedTail == true, height: height)
        updateEdge(remaining < 100)
    }

    private func updateEdge(_ edge: Bool) {
        guard edge != reportedEdge else { return }
        reportedEdge = edge
        DispatchQueue.main.async { [weak self] in self?.edgeChanged?(edge) }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        if !preparingAnnotationMenu, textView === annotationMenuText, let tappedAnnotation, textView.selectedRange != tappedAnnotation.range {
            endAnnotationMenu(clearSelection: false)
        }
        if !rebuilding, textView.selectedRange.length > 0 {
            statisticsInteraction(); Onboarding.shared.didSelectText()
        }
        guard textView.selectedRange.length == 0 else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPendingWindow(); self?.reevaluateWindowRequests() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { endAnnotationMenu(clearSelection: true); statisticsInteraction(); readingBegan?() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView.isDragging { statisticsInteraction() }
        updateBottomFade()
        guard !rebuilding, scrollView.isDragging || scrollView.isDecelerating else { return }
        reportScroll(settled: false)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportScroll(settled: true); applyPendingWindow() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportScroll(settled: true); applyPendingWindow() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { reportScroll(settled: true) }

    private func reportScroll(settled: Bool) {
        guard let text = scrollText, window != nil, text.textStorage.length > 0 else { return }
        let cover = hasCover && text.contentOffset.y < scrollCoverHeight / 2
        reportCover(cover)
        if cover { return }
        guard let line = scrollLineGeometry(text) else { return }
        report(line.offset, settled: settled)
        let height = max(1,text.bounds.height)
        if text.contentOffset.y + height*2 >= text.contentSize.height { requestMore(.forward) }
        if text.contentOffset.y < height { requestMore(.backward) }
    }

    func protectedSourceRange() -> SourceSpan? {
        guard let visible=statisticsRange(), let viewport=captureViewport(), !viewport.isCover else { return nil }
        let selected=selectedSourceRange()
        return SourceSpan(startUtf8:min(viewport.offset,min(visible.0,selected?.0 ?? visible.0)),endUtf8:max(visible.1,selected?.1 ?? visible.1))
    }
    func reevaluateWindowRequests() {
        if let text=scrollText {
            if text.contentOffset.y+text.bounds.height*2>=text.contentSize.height { requestMore(.forward) }
            if text.contentOffset.y<text.bounds.height { requestMore(.backward) }
        } else if let page=pageController?.viewControllers?.first as? PageController {
            if page.index>=pages.count-2 { requestMore(.forward) }
            if page.index<=1 { requestMore(.backward) }
        }
    }
    private func requestMore(_ direction: ReadingDirection) {
        guard let window, let cursor=direction == .forward ? window.nextCursor : window.previousCursor,
              let keep=protectedSourceRange() else { return }
        let admit = requestWindow
        requestedFrontiers.request(direction, cursor: cursor, keeping: keep) { admit(direction, keep) }

    }

    private func report(_ offset: UInt64, settled: Bool) {
        anchor = offset
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            scrollText?.accessibilityValue = String(offset)
            pageController?.viewControllers?.first?.view.accessibilityValue = String(offset)
        }
        let generation = reportGeneration
        // Delegate callbacks may occur during a SwiftUI representable update.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == reportGeneration else { return }
            changed?(offset, settled)
        }
    }

    private func movePage(_ direction: Int) {
        guard !rebuilding, !pageTransitioning, let paging = pageController,
              let current = pageIndex(paging.viewControllers?.first) else { return }
        let index = current + direction
        guard pages.indices.contains(index) || (index == -1 && hasCover) else { updateEdge(direction > 0); requestMore(direction > 0 ? .forward : .backward); return }
        pageTransitioning = true
        programmaticPageTransition = true
        let generation = reportGeneration
        paging.setViewControllers([makePage(at: index)],
                                  direction: direction > 0 ? .forward : .reverse,
                                  animated: !reduceMotion && !UIAccessibility.isReduceMotionEnabled) { [weak self] complete in
            guard let self, generation == self.reportGeneration else { return }
            self.pageTransitioning = false
            self.programmaticPageTransition = false
            if complete { self.reportPage(index) }
            self.updateEdge(index == self.pages.count - 1)
            self.applyPendingWindow()
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let current = pageIndex(viewController), current > (hasCover ? -1 : 0) else { return nil }
        return makePage(at: current - 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let current = pageIndex(viewController), current + 1 < pages.count else { return nil }
        return makePage(at: current + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === pageController else { return }
        pageTransitioning = false
        guard completed, let current = pageIndex(pageViewController.viewControllers?.first) else { applyPendingWindow(); return }
        if let text = activeTextView { configureAccessibility(text) }
        reportPage(current)
        updateEdge(current == pages.count - 1)
        applyPendingWindow()
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard pageViewController === pageController else { return }
        pageTransitioning = true
        if !programmaticPageTransition { statisticsInteraction(); readingBegan?() }
    }
}

@MainActor
/// Admission belongs to the application, independently of native viewport geometry.
struct ReadingFrontierAdmissions {
    private var accepted = Set<String>()
    mutating func reset() { accepted.removeAll() }
    mutating func request(_ direction: ReadingDirection, cursor: UInt64, keeping span: SourceSpan, admit: () -> Bool) {
        let key = "\(direction)-\(cursor)-\(span.startUtf8)-\(span.endUtf8)"
        guard !accepted.contains(key) else { return }
        if admit() { accepted.insert(key) }
    }
}

struct TextPage {
    // Page views own their text storage/container. UIPageViewController can ask
    // for the same page twice; sharing a container would detach visible text.
    let text: NSAttributedString
    let start: UInt64
    let end: UInt64
    let lineCount: Int
    let readingText: ReadingText
    var layoutVersion = ReadingTypography.layoutVersion
    var firstVisibleOffset: UInt64 { readingText.firstVisibleOffset ?? start }
    init(text: NSAttributedString, start: UInt64, end: UInt64, lineCount: Int,
         projection: ReadingText? = nil, insets: UIEdgeInsets = ReadingTextMetrics.insets) {
        self.text = text; self.start = start; self.end = end; self.lineCount = lineCount
        self.readingText = projection ?? ReadingText(text: text.string, sourceStart: start)
        self.insets = insets
    }
    var insets = ReadingTextMetrics.insets
    var continuation = NSAttributedString(string: "")

    var layoutText: NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        result.append(continuation)
        if result.length > 0,
           let paragraphStart = result.attribute(.readingParagraphStart, at: 0, effectiveRange: nil) as? NSNumber,
           paragraphStart.uint64Value < start,
           let style = result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle,
           let continued = style.mutableCopy() as? NSMutableParagraphStyle {
            continued.firstLineHeadIndent = continued.headIndent
            continued.paragraphSpacingBefore = 0
            let first = (result.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
            result.addAttribute(.paragraphStyle, value: continued, range: first)
        }
        return result
    }

    func makeTextView(frame: CGRect) -> UITextView {
        let storage = NSTextStorage(attributedString: layoutText)
        let manager = ReadingLayoutManager()
        let container = NSTextContainer(size: CGSize(width: ReadingTextMetrics.contentSize(in: frame.size, insets: insets).width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        container.maximumNumberOfLines = lineCount
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = PageReadingTextView(frame: frame, textContainer: container)
        view.readingText = readingText
        view.visibleLength = text.length
        view.accessibilityLabel = text.string
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = insets
        view.backgroundColor = .clear
        return view
    }

    static func paginate(_ window: ReadingWindow, size: CGSize,
                         attributes: [NSAttributedString.Key: Any], source styled: NSAttributedString? = nil,
                         insets: UIEdgeInsets = ReadingTextMetrics.insets,
                         preserving previous: [TextPage] = [], keeping anchor: UInt64? = nil,
                         layout: ((ReadingText, Bool) -> [NSRange])? = nil) -> [TextPage] {
        guard !window.chunks.isEmpty else { return [] }
        let projection = ReadingText(window)
        let coordinates = projection.coordinates
        let source = styled ?? NSAttributedString(string: projection.text, attributes: attributes)
        func slice(from start: UInt64, to end: UInt64) -> (NSAttributedString, ReadingText) {
            let first = coordinates.displayPoint(Int(start-window.start)) ?? 0
            let last = end == window.end ? coordinates.length : (coordinates.displayPoint(Int(end-window.start)) ?? coordinates.length)
            let range = NSRange(location: first, length: last-first)
            return (source.attributedSubstring(from: range), projection.slice(range))
        }
        var retained = previous.filter { $0.layoutVersion == ReadingTypography.layoutVersion && $0.start >= window.start && $0.end <= window.end && slice(from: $0.start, to: $0.end).1 == $0.readingText }
        if let oldStart = previous.first?.start, window.start < oldStart,
           retained.first?.start == oldStart, retained.first?.firstVisibleOffset != anchor { retained.removeFirst() }
        // The previous window's last page may have ended only because loaded
        // text ran out. Extend it into the new chunk instead of keeping a gap.
        if let oldEnd = previous.last?.end, window.end > oldEnd,
           retained.last?.end == oldEnd, retained.last?.firstVisibleOffset != anchor { retained.removeLast() }
        guard let first = retained.first, let last = retained.last else {
            return paginate(source, projection: projection, size: size, insets: insets, layout: layout)
        }
        let earlier = slice(from: window.start, to: first.start), later = slice(from: last.end, to: window.end)
        let prefix = paginateBackward(earlier.0, projection: earlier.1, size: size, insets: insets, layout: layout)
        let suffix = paginate(later.0, projection: later.1, size: size, insets: insets, layout: layout)
        return contextualized(prefix + retained + suffix, source: source, projection: projection)
    }

    static func paginate(_ chunk: TextChunk, size: CGSize, attributes: [NSAttributedString.Key: Any]) -> [TextPage] {
        paginate(NSAttributedString(string: chunk.text, attributes: attributes), projection: ReadingText(text: chunk.text, sourceStart: chunk.startUtf8), size: size, insets: ReadingTextMetrics.insets)
    }

    private static func paginate(_ source: NSAttributedString, projection: ReadingText, size: CGSize, insets: UIEdgeInsets, layout: ((ReadingText, Bool) -> [NSRange])? = nil) -> [TextPage] {
        if let layout { return contextualized(layout(projection, false).map { page(source, projection: projection, range: $0, lines: 1, insets: insets) }, source: source, projection: projection) }
        // A suffix can begin inside a paragraph. Apply the same continuation
        // style used by visible pages before asking TextKit for page boundaries.
        let storage = NSTextStorage(attributedString: TextPage(text: source, start: projection.sourceStart, end: projection.sourceEnd, lineCount: 0, projection: projection).layoutText)
        let manager = ReadingLayoutManager()
        storage.addLayoutManager(manager)
        var result: [TextPage] = []
        var consumed = 0
        while consumed < storage.length {
            let container = NSTextContainer(size: ReadingTextMetrics.contentSize(in: size, insets: insets))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
            let glyphRange = manager.glyphRange(for: container)
            let range = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard range.length > 0, NSMaxRange(range) > consumed else { break }
            var lineCount = 0
            manager.enumerateLineFragments(forGlyphRange: glyphRange) { _, _, _, _, _ in lineCount += 1 }
            result.append(page(storage, projection: projection, range: range, lines: lineCount, insets: insets))
            consumed = NSMaxRange(range)
        }
        return contextualized(result, source: storage, projection: projection)
    }

    /// Lay newly loaded earlier text backwards from an established page start.
    /// Full lines are grouped from the end, keeping the join page full; only the
    /// temporary window's first page can be partial. Recentring happens before
    /// that edge is reached, and existing overlap pages keep identical ranges.
    private static func paginateBackward(_ source: NSAttributedString, projection: ReadingText, size: CGSize, insets: UIEdgeInsets, layout: ((ReadingText, Bool) -> [NSRange])? = nil) -> [TextPage] {
        if let layout { return layout(projection, true).map { page(source, projection: projection, range: $0, lines: 1, insets: insets) } }
        guard source.length > 0 else { return [] }
        let storage = NSTextStorage(attributedString: TextPage(text: source, start: projection.sourceStart, end: projection.sourceEnd, lineCount: 0, projection: projection).layoutText)
        let manager = ReadingLayoutManager()
        let container = NSTextContainer(size: CGSize(width: ReadingTextMetrics.contentSize(in: size, insets: insets).width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        var lines: [(range: NSRange, rect: CGRect)] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { rect, _, _, glyphs, _ in
            lines.append((manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), rect))
        }
        let coordinates = projection.coordinates
        let base = projection.sourceStart
        let height = ReadingTextMetrics.contentSize(in: size, insets: insets).height
        var end = lines.count
        var result: [TextPage] = []
        while end > 0 {
            var start = end - 1
            func leadingSpace(_ index: Int) -> CGFloat {
                let location = lines[index].range.location
                guard let position = storage.attribute(.readingParagraphStart, at: location, effectiveRange: nil) as? NSNumber,
                      let source = coordinates.sourcePoint(location), position.uint64Value == base+UInt64(source) else { return 0 }
                return (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacingBefore ?? 0
            }
            while start > 0, lines[end - 1].rect.maxY - lines[start - 1].rect.minY + leadingSpace(start - 1) <= height { start -= 1 }
            let range = NSRange(location: lines[start].range.location,
                                length: NSMaxRange(lines[end - 1].range) - lines[start].range.location)
            result.append(page(storage, projection: projection, range: range, lines: end-start, insets: insets))
            end = start
        }
        return Array(result.reversed())
    }

    private static func page(_ source: NSAttributedString, projection: ReadingText, range: NSRange, lines: Int, insets: UIEdgeInsets) -> TextPage {
        let visible = projection.slice(range)
        return TextPage(text: source.attributedSubstring(from: range), start: visible.sourceStart,
                        end: visible.sourceEnd, lineCount: lines, projection: visible, insets: insets)
    }

    /// Keep real lookahead for the typesetter when a page ends inside a paragraph.
    /// The line limit excludes it from rendering; selection stays on visible text.
    /// No invented characters enter copying or the UTF-8 anchor coordinates.
    private static func contextualized(_ pages: [TextPage], source: NSAttributedString, projection: ReadingText) -> [TextPage] {
        let coordinates = projection.coordinates
        let base = projection.sourceStart
        let string = source.string as NSString
        return pages.map { page in
            var page = page
            page.continuation = NSAttributedString(string: "")
            guard let end = coordinates.displayPoint(Int(page.end-base)) else { return page }
            guard end < source.length, !page.text.string.hasSuffix("\n") else { return page }
            let range = string.rangeOfComposedCharacterSequences(for: NSRange(location: end, length: min(512, source.length - end)))
            page.continuation = source.attributedSubstring(from: range)
            return page
        }
    }

}

/// Native glyph layout plus paint-only annotation decoration.
final class ReadingLayoutManager: NSLayoutManager {
    override func setExtraLineFragmentRect(_ fragmentRect: CGRect, usedRect: CGRect, textContainer: NSTextContainer) {
        // The terminal insertion line has no source characters and is not readable content.
        var fragment = fragmentRect, used = usedRect
        fragment.size.height = 0; used.size.height = 0
        super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: textContainer)
    }

    struct Decoration: Equatable {
        let range: NSRange
        let color: UIColor
    }
    private(set) var decorations: [Decoration] = []

    func setDecorations(_ decorations: [Decoration]) {
        guard self.decorations != decorations else { return }
        self.decorations = decorations
        // Paint-only state must never edit NSTextStorage, invalidate glyph layout,
        // change the selection, or restore a scroll offset after the fact.
        invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage?.length ?? 0))
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        // Draw annotations first so native selection/search emphasis stays above them.
        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            for fill in decorationBackgrounds(forGlyphRange: glyphsToShow) {
                fill.color.setFill()
                let rect = fill.rect.offsetBy(dx: origin.x, dy: origin.y)
                UIBezierPath(roundedRect: rect, cornerRadius: min(2, rect.height * 0.1)).fill()
            }
            context.restoreGState()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    func decorationBackgrounds(forGlyphRange glyphs: NSRange) -> [(rect: CGRect, color: UIColor)] {
        guard glyphs.length > 0, let storage = textStorage else { return [] }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var fills: [(rect: CGRect, color: UIColor)] = []
        for decoration in decorations {
            let range = NSIntersectionRange(decoration.range, characters)
            guard range.length > 0 else { continue }
            let marked = NSIntersectionRange(self.glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphs)
            guard marked.length > 0 else { continue }
            self.enumerateLineFragments(forGlyphRange: marked) { line, _, container, lineGlyphs, _ in
                let part = NSIntersectionRange(marked, lineGlyphs)
                guard part.length > 0 else { return }
                let character = self.characterIndexForGlyph(at: part.location)
                let font = storage.attribute(.font, at: character, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 20)
                let baseline = line.minY + self.location(forGlyphAt: part.location).y
                // An em-sized band follows the letters, independent of line spacing.
                // Enclosing rects preserve native wrapping and bidirectional ranges.
                self.enumerateEnclosingRects(forGlyphRange: part,
                                             withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                             in: container) { bounds, _ in
                    let left = max(0, bounds.minX - 0.75)
                    let right = min(container.size.width, bounds.maxX + 0.75)
                    guard right > left else { return }
                    let rect = CGRect(x: left, y: baseline - font.pointSize * 0.86,
                                      width: right - left, height: font.pointSize)
                    fills.append((rect, decoration.color))
                }
            }
        }
        return fills
    }


}

@MainActor
class ReadingTextView: UITextView {
    var readingText = ReadingText(text: "")
    var copySelection: ((UInt64, UInt64) -> Void)?
    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        guard let position = super.closestPosition(to: point) else { return nil }
        let limit = min(textStorage.length, (self as? PageReadingTextView)?.visibleLength ?? textStorage.length)
        return self.position(from: beginningOfDocument, offset: min(limit, offset(from: beginningOfDocument, to: position))) ?? position
    }

    override func copy(_ sender: Any?) {
        let range = NSIntersectionRange(selectedRange, readingText.selectableRange)
        guard range.length > 0 else { return }
        guard let envelope = readingText.coordinates.sourceRange(range) else { return }
        copySelection?(readingText.sourceStart + UInt64(envelope.lowerBound), readingText.sourceStart + UInt64(envelope.upperBound))
    }

    private var menuSelectionRange: UITextRange?

    /// The native Select command normally narrows to a word. During this one
    /// synchronous command, use the annotation's specified range instead. Native
    /// selection gestures and handle dragging keep their normal behavior.
    func presentSelectionMenu(for range: NSRange) {
        selectedRange = range
        menuSelectionRange = selectedTextRange
        defer { menuSelectionRange = nil }
        super.select(nil)
    }

    override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set { super.selectedTextRange = menuSelectionRange ?? newValue }
    }

    private var bookmarkCharacters: [Int] = []
    private var bookmarkColor = UIColor.clear
    private(set) var bookmarkIndicators: [UIImageView] = []
    private let bookmarkImage = UIImage(systemName: "bookmark.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))

    func setBookmarks(_ characters: [Int], color: UIColor) {
        guard bookmarkCharacters != characters || bookmarkColor != color else { return }
        bookmarkCharacters = characters
        bookmarkColor = color
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bookmarkCharacters.isEmpty else {
            bookmarkIndicators.forEach { $0.removeFromSuperview() }
            bookmarkIndicators.removeAll(keepingCapacity: true)
            return
        }
        // These views live in scroll-content coordinates, inside the existing
        // margin. They neither participate in typesetting nor intercept taps.
        let visible = bounds.offsetBy(dx: -textContainerInset.left, dy: -textContainerInset.top)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var lines = Set<Int>()
        var frames: [CGRect] = []
        for original in bookmarkCharacters where NSLocationInRange(original, characters) && original < textStorage.length {
            let character = original
            let glyph = layoutManager.glyphIndexForCharacter(at: character)
            var lineRange = NSRange()
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
            guard lines.insert(lineRange.location).inserted else { continue }
            let font = textStorage.attribute(.font, at: character, effectiveRange: nil) as? UIFont ?? .systemFont(ofSize: 20)
            let baseline = line.minY + layoutManager.location(forGlyphAt: glyph).y
            let width = min(12, max(0, textContainerInset.right - 4))
            let frame = CGRect(x: bounds.width - (textContainerInset.right + width) / 2,
                               y: textContainerInset.top + baseline - font.capHeight / 2 - 10,
                               width: width, height: 20)
            if frame.intersects(bounds) { frames.append(frame) }
        }
        while bookmarkIndicators.count > frames.count { bookmarkIndicators.removeLast().removeFromSuperview() }
        while bookmarkIndicators.count < frames.count {
            let indicator = UIImageView(image: bookmarkImage)
            indicator.contentMode = .scaleAspectFit
            indicator.isUserInteractionEnabled = false
            // The accessible bookmark list and toolbar remain the controls.
            indicator.isAccessibilityElement = false
            addSubview(indicator)
            bookmarkIndicators.append(indicator)
        }
        for (indicator, frame) in zip(bookmarkIndicators, frames) {
            indicator.frame = frame
            indicator.tintColor = bookmarkColor
        }
    }
}

@MainActor
private final class ScrollReadingTextView: ReadingTextView {
    var onLayout: (() -> Void)?
    var bodyStart = 0

    override func selectAll(_ sender: Any?) {
        selectedRange = NSRange(location: bodyStart, length: max(0, textStorage.length - bodyStart))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

@MainActor
final class PageReadingTextView: ReadingTextView {
    var visibleLength: Int?

    override var selectedTextRange: UITextRange? {
        get { super.selectedTextRange }
        set {
            guard let range = newValue, let limit = visibleLength,
                  offset(from: beginningOfDocument, to: range.end) > limit,
                  let start = position(from: beginningOfDocument, offset: min(limit, offset(from: beginningOfDocument, to: range.start))),
                  let end = position(from: beginningOfDocument, offset: limit) else {
                super.selectedTextRange = newValue
                return
            }
            super.selectedTextRange = textRange(from: start, to: end)
        }
    }

    override func selectAll(_ sender: Any?) {
        selectedRange = NSRange(location: 0, length: visibleLength ?? textStorage.length)
    }
}

@MainActor
private final class ReaderCoverController: UIHostingController<AnyView> {
    private var currentTitle: String
    private var currentTheme: ThemeSurface
    private var information: BookDetails?
    init(title: String, information: BookDetails?, showDetails: @escaping () -> Void, theme: ThemeSurface) {
        currentTitle = title; currentTheme = theme; self.information = information
        super.init(rootView: AnyView(ReaderTitlePage(title: title, information: information, showDetails: showDetails).themeScope(theme)))
        safeAreaRegions = []
        view.backgroundColor = theme.paper
        view.isAccessibilityElement = false
        view.accessibilityIdentifier = "readerCover"
        view.accessibilityLabel = String(localized: "封面，\(title)")
    }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(title: String, information: BookDetails?, showDetails: @escaping () -> Void, theme: ThemeSurface) {
        guard currentTitle != title || currentTheme != theme || self.information != information else { return }
        currentTitle = title; currentTheme = theme; self.information = information
        rootView = AnyView(ReaderTitlePage(title: title, information: information, showDetails: showDetails).themeScope(theme))
        view.backgroundColor = theme.paper
        view.accessibilityLabel = String(localized: "封面，\(title)")
    }
}

@MainActor
private final class PageController: UIViewController {
    private(set) var page: TextPage
    private(set) var index: Int
    init(page: TextPage, index: Int) { self.page = page; self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let text = page.makeTextView(frame: .zero)
        text.accessibilityIdentifier = "pageText"
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { text.accessibilityValue = String(page.start) }
        view = text
    }
    func update(page: TextPage, index: Int) {
        let changed = self.page.start != page.start || self.page.end != page.end || self.page.continuation != page.continuation
            || self.page.text != page.text || self.page.lineCount != page.lineCount || self.page.readingText != page.readingText || self.page.layoutVersion != page.layoutVersion
        self.page = page; self.index = index
        if changed, let text = view as? PageReadingTextView {
            text.readingText = page.readingText
            text.visibleLength = page.text.length
            text.textContainer.maximumNumberOfLines = page.lineCount
            text.textStorage.setAttributedString(page.layoutText)
            text.accessibilityLabel = page.text.string
        }
    }
}
