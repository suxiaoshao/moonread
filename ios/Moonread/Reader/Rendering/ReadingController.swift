import SwiftUI
import UIKit

/// TextKit 1 is explicit here: the same native glyph layout drives text selection,
/// visible-line anchors and fixed-height page containers. Rust bounds retained
/// payload independently of confirmed blank gaps; layout never scales with the book.
@MainActor
final class ReadingController: UIViewController, UITextViewDelegate, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    var openingID: UUID?
    var requestWindow: (ReadingDirection, SourceSpan) -> Bool = { _,_ in false }
    var requestedFrontiers = ReadingFrontierAdmissions()
    private var diagnosedOpening: UUID?
    #if READER_OPEN_DIAGNOSTICS
    private var displayProbe: ReaderDisplayProbe?
    #endif
    var statisticsInteraction: () -> Void = {}

    func statisticsRange() -> (UInt64, UInt64)? {
        guard !isCoverVisible, !rebuilding, !needsRebuild, !pageTransitioning,
              viewIfLoaded?.window != nil else { return nil }
        let ranges = visibleTextViews.compactMap { text -> (UInt64, UInt64)? in
            guard let body = text as? ReadingTextView, !text.text.isEmpty else { return nil }
            let rect = text.bounds.offsetBy(dx: -text.textContainerInset.left, dy: -text.textContainerInset.top)
            let glyphs = text.layoutManager.glyphRange(forBoundingRect: rect, in: text.textContainer)
            let chars = text.layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let clipped = NSIntersectionRange(chars, body.readingText.selectableRange)
            guard clipped.length > 0, let envelope = textCoordinates(text).sourceRange(clipped), !envelope.isEmpty else { return nil }
            let base = textBase(text)
            return (base + UInt64(envelope.lowerBound), base + UInt64(envelope.upperBound))
        }
        guard let start = ranges.map({ $0.0 }).min(), let end = ranges.map({ $0.1 }).max() else { return nil }
        return (start, end)
    }
    func selectedSourceRange() -> (UInt64, UInt64)? {
        if let retainedSelection { return retainedSelection }
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
    let readingSurface = UIView()
    let bottomFade = CAGradientLayer()
    var stableInsets = UIEdgeInsets.zero
    private var insetSize = CGSize.zero
    /// Only an inline first-use guide reserves space. Sheets still keep the full reader viewport.
    var guideHeight: CGFloat = 0 {
        didSet { if guideHeight != oldValue { view.setNeedsLayout() } }
    }
    var headerPositionChanged: (CGFloat) -> Void = { _ in }
    private var reportedHeaderTop: CGFloat?
    var layoutStatus: ReadingLayoutStatus?
    private var waitingForNativeLayout = false
    private var layoutEpoch: UInt64 = 0
    var contentGeometry: ReadingContentGeometry? {
        didSet { if contentGeometry != oldValue { viewIfLoaded?.setNeedsLayout() } }
    }
    var controlsVisible = false
    var toggleControls: (() -> Void)?
    var readingBegan: (() -> Void)?
    var window: ReadingWindow?
    var settings: ReaderSettings?
    var anchor: UInt64 = 0
    var layoutAnchor: UInt64?
    private var hadWideLayout = false
    private var dark = false
    var theme = ThemeSurface.initial
    let ink = ReadingInk()
    var reduceMotion = false
    var typeSize: DynamicTypeSize = .large
    var changed: ((UInt64, Bool) -> Void)?
    var scrollText: ScrollReadingTextView?
    var pageController: UIPageViewController?
    var pages: [TextPage] = []
    var leafFrames: [CGRect] = []
    var pageSize: CGSize { leafFrames.first?.size ?? readingSurface.bounds.size }
    var retainedSelection: (UInt64, UInt64)?
    private var selectionWasFirstResponder = false
    private var readingRegion: CGRect?
    var renderedSize: CGSize = .zero
    var rebuilding = false
    var needsRebuild = true
    var reportGeneration = 0
    var pageTransitioning = false
    var programmaticPageTransition = false
    private var compactHeaderHeight: CGFloat = 0
    var preservePageBoundaries = false
    var pendingWindow: ReadingWindow?
    private var navigationRevision = 0
    var pendingNavigation: (request: ReadingNavigation, keepVisible: Bool)?
    var edgeChanged: ((Bool) -> Void)?
    var reportedEdge = false
    var annotations: [ReaderMark] = []
    var preparingAnnotationMenu = false
    weak var annotationMenuText: UITextView?
    var tappedAnnotation: (context: AnnotationSelection, range: NSRange)?
    var bookmarkPositions: [UInt64] = []
    var focusRange: TextRange?
    var selectionStart: UInt64?
    var selection: ((UInt64, UInt64, ReaderSelectionAction) -> Void)?
    var coverTitle: String?
    var coverInformation: BookDetails?
    var showBookDetails: () -> Void = {}
    var isCoverVisible = false
    var coverChanged: ((Bool) -> Void)?
    var paperInput: ThemeSurface.PaperInput?
    var paperBackground = UIColor.clear
    var scrollCover: ReaderCoverController?
    var hasCover: Bool { coverTitle != nil && window?.isStartOfBook == true }

    override func loadView() {
        view = ReadingPaperView()
        view.contentMode = .redraw
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
            || (contentGeometry != nil && settings.widePageMode != self.settings?.widePageMode)
            || (self.window?.chunks == window.chunks && self.window?.paragraphs != window.paragraphs)
            || self.compactHeaderHeight != compactHeaderHeight
        if navigating {
            layoutAnchor = anchor
            retainedSelection = nil
            reportGeneration += 1 // Ignore movement callbacks queued before the jump.
            pageTransitioning = false
            programmaticPageTransition = false
            pendingNavigation = (navigation ?? ReadingNavigation(), !contentsChanged && !layoutChanged && !needsRebuild)
        }
        let nextTheme = theme ?? ThemeSurface(plan: try! resolveThemes(value: defaultThemeSnapshot(), system: dark ? .dark : .light, highContrast: false).reader)
        let appearanceChanged = self.theme.plan != nextTheme.plan
        self.theme = nextTheme
        self.reduceMotion = reduceMotion
        ink.set(nextTheme.ink)
        overrideUserInterfaceStyle = nextTheme.style
        view.backgroundColor = nextTheme.paper
        if layoutChanged { preservePageBoundaries = false }
        else if contentsChanged { preservePageBoundaries = true }
        self.settings = settings
        updatePaperSurface()
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
        scrollCover?.update(title: coverTitle ?? "", information: coverInformation, showDetails: showBookDetails, theme: nextTheme, background: .clear)
        for case let cover as ReaderCoverController in pageController?.children ?? [] { cover.update(title: coverTitle ?? "", information: coverInformation, showDetails: showBookDetails, theme: nextTheme, background: paperBackground) }
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
        visibleTextViews.forEach(configureAccessibility)
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
        updatePaperSurface()
        guard let window = view.window, view.bounds.width > 60, view.bounds.height > 60 else { return }
        let viewport: CGRect
        var contentInsets: UIEdgeInsets
        view.clipsToBounds = contentGeometry != nil
        if let geometry = contentGeometry {
            guard geometry.canCommit else {
                recordLayout("layout.suspended"); return
            }
            if let transition = transitionCoordinator, transition.isAnimated, !transition.isCancelled, transition.percentComplete < 1 {
                if !waitingForNativeLayout {
                    waitingForNativeLayout = true
                    transition.animate(alongsideTransition: nil) { [weak self] _ in
                        self?.waitingForNativeLayout = false; self?.view.setNeedsLayout()
                    }
                }
                return
            }
            // On-screen membership is a native readiness fact, not a source of
            // viewport height or a compensation for the parent's navigation.
            let visibleCanvas = view.convert(window.bounds, from: window)
            guard visibleCanvas.insetBy(dx: -1, dy: -1).contains(view.bounds) else {
                recordLayout("layout.awaitingOnscreenCanvas"); return
            }
            // The native parent allocates this local canvas. Its safe-area
            // guide already accounts for intersecting bars on either axis.
            // Never substitute window height or add another bar's bounds.
            viewport = view.bounds.intersection(view.safeAreaLayoutGuide.layoutFrame)
            guard abs(view.bounds.width - geometry.size.width) < 1,
                  abs(view.bounds.height - geometry.size.height) < 1 else {
                recordLayout("layout.awaitingLocalCanvas"); return
            }
            stableInsets = .zero // native safe-area exclusion is already in viewport
            contentInsets = UIEdgeInsets(top: compactHeaderHeight, left: 0, bottom: 0, right: 0)
            // The SwiftUI safe-area inset for the controls tip is already part
            // of this local allocation; do not subtract guideHeight again.
        } else {
            // SwiftUI fills the window even when the status bar appears. Reserve the
            // hardware safe area here, independently of the overlay controls. Keep
            // the larger inset for this size so status-bar changes cannot reflow text.
            let insets = window.safeAreaInsets
            // This controller is the full-screen reader. A presented sheet can
            // animate SwiftUI's container height by the bottom safe area; that is
            // chrome motion, not a new text viewport. Use this scene's actual size.
            viewport = CGRect(origin: .zero, size: window.bounds.size)
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
            contentInsets = stableInsets
            contentInsets.top += compactHeaderHeight
            // The bottom safe area is a drawing overlay in scroll mode, not an
            // empty strip removed from the text viewport.
            if settings?.mode == .scroll { contentInsets.bottom = 0 }
            if guideHeight > 0 { contentInsets.bottom = max(contentInsets.bottom, guideHeight + insets.bottom) }
        }
        if contentGeometry != nil { hadWideLayout = true }
        let surface = viewport.inset(by: contentInsets)
        if contentGeometry != nil {
            let font = settings.map { ReadingTypography.font($0) } ?? UIFont.preferredFont(forTextStyle: .body)
            guard ReadingContainerRegions.valid(surface, inside: view.bounds, minimumHeight: font.lineHeight + 20) else {
                recordLayout("layout.rejected", proposed: surface); return
            }
        }
        let regions = contentGeometry == nil ? [surface] : readingRegions(in: surface)
        guard !regions.isEmpty else {
            recordLayout("layout.rejectedRegion", proposed: surface); return
        }
        var nextSurface = surface
        var nextFrames = [CGRect(origin: .zero, size: surface.size)]
        if contentGeometry != nil, ReadingContainerRegions.permitsSpread(in: surface.size), settings?.mode == .pages, settings?.widePageMode == .double,
           let settings {
            let minimum = ReadingTypography.minimumColumnWidth(settings)
            let candidates: [CGRect]
            if regions.count == 1, regions[0] == surface {
                let width = (surface.width - 24) / 2
                candidates = [CGRect(x: surface.minX, y: surface.minY, width: width, height: surface.height),
                              CGRect(x: surface.minX + width + 24, y: surface.minY, width: width, height: surface.height)]
            } else { candidates = regions.sorted { $0.minX < $1.minX } }
            if candidates.count == 2, abs(candidates[0].minY - candidates[1].minY) < 1,
               candidates[0].maxX <= candidates[1].minX {
                let size = CGSize(width: min(candidates[0].width, candidates[1].width), height: min(candidates[0].height, candidates[1].height))
                let insets = ReadingTypography.insets(settings, width: size.width)
                if size.width - insets.left - insets.right >= minimum {
                    nextFrames = candidates.map { CGRect(x: $0.midX - size.width / 2 - surface.minX,
                        y: $0.midY - size.height / 2 - surface.minY, width: size.width, height: size.height) }
                }
            }
        }
        if nextFrames.count == 1, let region = preferredReadingRegion(regions) {
            nextSurface = region
            if region.minY > surface.minY {
                nextSurface.origin.y += compactHeaderHeight
                nextSurface.size.height = max(1, nextSurface.height - compactHeaderHeight)
            }
            nextFrames = [CGRect(origin: .zero, size: nextSurface.size)]
        }
        if contentGeometry != nil {
            let font = settings.map { ReadingTypography.font($0) } ?? UIFont.preferredFont(forTextStyle: .body)
            guard ReadingContainerRegions.valid(nextSurface, inside: view.bounds, minimumHeight: font.lineHeight + 20),
                  nextFrames.allSatisfy({ ReadingContainerRegions.valid($0, inside: CGRect(origin: .zero, size: nextSurface.size), minimumHeight: font.lineHeight + 20) }) else {
                recordLayout("layout.rejectedRegion", proposed: nextSurface); return
            }
        }
        let savedViewport = captureViewport()
        let savedSelection = selectedSourceRange()
        let selectionFocused = activeTextView?.isFirstResponder == true
        readingRegion = nextSurface
        let pageLayoutChanged = leafFrames != nextFrames
        readingSurface.frame = nextSurface
        leafFrames = nextFrames
        if contentGeometry != nil {
            let headerTop = max(0, nextSurface.minY - compactHeaderHeight)
            if reportedHeaderTop != headerTop {
                reportedHeaderTop = headerTop
                Task { @MainActor [weak self] in
                    guard let self, self.contentGeometry != nil, self.reportedHeaderTop == headerTop else { return }
                    self.headerPositionChanged(headerTop)
                }
            }
        }
        updatePaperBackdrop()
        updateBottomFade()
        let committedLayoutChanged = needsRebuild || renderedSize != readingSurface.bounds.size || pageLayoutChanged
        if committedLayoutChanged {
            layoutEpoch &+= 1
            if pendingNavigation == nil, let savedViewport {
                anchor = hadWideLayout ? (layoutAnchor ?? savedViewport.offset) : savedViewport.offset
                isCoverVisible = savedViewport.isCover
            }
            retainedSelection = savedSelection
            selectionWasFirstResponder = selectionFocused
            if renderedSize != readingSurface.bounds.size || pageLayoutChanged { preservePageBoundaries = false }
            renderedSize = readingSurface.bounds.size
            rebuild()
            if layoutAnchor == nil { layoutAnchor = anchorLeaf?.page.firstVisibleOffset }
            pendingNavigation?.keepVisible = false
        }
        applyNavigation()
        if contentGeometry != nil, layoutStatus?.hasValidLayout != true {
            let status = layoutStatus
            Task { @MainActor in status?.committed() }
        }
        recordLayout("layout.committed", proposed: nextSurface)
        if let id = openingID, diagnosedOpening != id, !needsRebuild {
            diagnosedOpening = id
            ReaderOpenDiagnostics.mark(id, "layoutCompleted")
            ReaderOpenDiagnostics.mark(id, isCoverVisible ? "coverLayout" : "bodyLayout")
            #if READER_OPEN_DIAGNOSTICS
            displayProbe = ReaderDisplayProbe(view: view, id: id, cover: isCoverVisible, glyphsVisible: { [weak self] in self?.diagnosticGlyphsVisible() ?? false }) { [weak self] in self?.displayProbe = nil }
            #endif
        }
    }

    private func recordLayout(_ event: String, proposed: CGRect? = nil) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MOONREAD_READER_EVENTS"] == "1" else { return }
        var bars: [[String: String]] = []
        for (name, bar) in [("navigation", navigationController?.navigationBar as UIView?), ("toolbar", navigationController?.toolbar as UIView?)] {
            if let bar {
                let rect = view.convert(bar.bounds, from: bar)
                let intersection = view.bounds.intersection(rect)
                bars.append(["name": name, "frame": String(describing: rect), "intersection": String(describing: intersection),
                    "axis": intersection.isNull ? "none" : (intersection.height > intersection.width ? "vertical" : "horizontal")])
            }
        }
        var reserved: [String] = []
        if #available(iOS 27.1, *) {
            reserved = [UIView.ReservedRegion.Kind.division, .occlusion].flatMap { kind in
                view.reservedRegions(kind: kind).filter(\.isActive).map { String(describing: $0.frame) }
            }
        }
        ReaderSceneDiagnostics.record(event, opening: openingID, fields: [
            "canvas": String(describing: view.bounds), "safeRegion": String(describing: view.safeAreaLayoutGuide.layoutFrame),
            "window": String(describing: view.window?.bounds), "windowInCanvas": String(describing: view.window.map { view.convert($0.bounds, from: $0) }),
            "geometry": String(describing: contentGeometry), "bars": bars, "guideHeight": guideHeight,
            "reserved": reserved, "toolBlockersInWindow": (contentGeometry?.blockedInWindow ?? []).map { String(describing: $0) }, "proposed": String(describing: proposed), "surface": String(describing: readingSurface.frame),
            "leaves": leafFrames.map { String(describing: $0) }, "cover": isCoverVisible,
            "anchor": anchor, "epoch": layoutEpoch, "typography": String(describing: settings)])
        #endif
    }

    private func readingRegions(in surface: CGRect) -> [CGRect] {
        var blocked: [CGRect] = []
        if #available(iOS 27.1, *) {
            blocked = [UIView.ReservedRegion.Kind.division, .occlusion].flatMap { kind in
                view.reservedRegions(kind: kind).filter(\.isActive).map(\.frame)
            }
        }
        if let window = view.window {
            blocked += (contentGeometry?.blockedInWindow ?? []).map { view.convert($0, from: window) }
        }
        return ReadingContainerRegions.available(surface, blocked: blocked)
    }

    private func preferredReadingRegion(_ regions: [CGRect]) -> CGRect? {
        if let previous = readingRegion, let same = regions.first(where: { $0.contains(CGPoint(x: previous.midX, y: previous.midY)) }) { return same }
        return regions.sorted {
            let a = $0.width * $0.height, b = $1.width * $1.height
            return a == b ? $0.minX < $1.minX : a > b
        }.first
    }

    func restoreNativeSelection() {
        guard let retainedSelection else { return }
        let preferred = currentLeaves.first { leaf in
            layoutAnchor.map { $0 >= leaf.page.start && $0 < leaf.page.end } ?? false
        }?.view as? UITextView
        let texts = preferred.map { [$0] + visibleTextViews.filter { $0 !== preferred } } ?? visibleTextViews
        for text in texts {
            let base = textBase(text), mapping = textCoordinates(text)
            let start = max(base, retainedSelection.0), end = min(base + UInt64(mapping.byteCount), retainedSelection.1)
            guard start < end, let range = mapping.displayRange(Int(start-base)..<Int(end-base)) else { continue }
            activateLeaf(text)
            text.selectedRange = range
            if selectionWasFirstResponder { text.becomeFirstResponder() }
            break // Native handles belong to just one leaf; logical range is full.
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

    var activeTextView: UITextView? {
        scrollText ?? anchorLeaf?.view as? UITextView
    }

}
