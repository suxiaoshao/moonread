import SwiftUI
import UIKit

extension ReadingController {
    func attributes() -> [NSAttributedString.Key: Any] {
        ReadingTypography.attributes(settings ?? defaultReaderSettings(), ink: ink.dynamic)
    }

    var textInsets: UIEdgeInsets {
        ReadingTypography.insets(settings ?? defaultReaderSettings(), width: pageSize.width)
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
        TextPage.paginate(window, size: pageSize, attributes: attributes(), source: styledText(window),
                          insets: textInsets, preserving: previous, keeping: anchor)
    }

    var isInteracting: Bool {
        pageTransitioning || scrollText?.isDragging == true || scrollText?.isDecelerating == true
            || (activeTextView?.selectedRange.length ?? 0) > 0
    }

    struct ScrollLineGeometry {
        let offset: UInt64
        let lineY: CGFloat
    }

    /// A reading anchor is a visible body line, not the nearest glyph to a
    /// point in the indentation or paragraph spacing. Keep source and Y paired.
    func scrollLineGeometry(_ text: ReadingTextView) -> ScrollLineGeometry? {
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
        guard let current = anchorLeaf else { return nil }
        return ReadingViewport(offset: current.page.firstVisibleOffset, lineY: 0, size: renderedSize,
                               settings: settings, typeSize: typeSize, pages: pages, pageSize: contentGeometry == nil ? nil : pageSize, leafCount: leafFrames.count, groupStart: currentLeaves.count > 1 ? currentLeaves.first?.page.start : nil)
    }

    private var matchingRestoration: ReadingViewport? {
        pendingNavigation?.request.restoration(size: readingSurface.bounds.size, settings: settings, typeSize: typeSize, pageSize: contentGeometry == nil ? nil : pageSize, leafCount: leafFrames.count)
    }

    func replaceNavigationContents() {
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
        } else if let leaf = currentLeaves.first(where: { offset >= $0.page.start && offset < $0.page.end }) {
            if let text = leaf.view as? UITextView { activateLeaf(text) }
            return window
        }
        return nil
    }

    func applyNavigation() {
        guard let pending = pendingNavigation else { return }
        let restoration = matchingRestoration
        rebuilding = true
        defer {
            rebuilding = false
            pendingNavigation = nil
            decorateVisibleText()
            updateBottomFade()
            visibleTextViews.forEach(configureAccessibility)
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
                desired = ReadingNavigation(restoring: restoration).scrollTarget(lineY: line.minY, textInset: text.textContainerInset.top, target: rect, visible: .zero, keepVisible: false)!
            } else if pending.request.placement == .context {
                let visible = contextViewport(in: text, bottomObstruction: pending.request.bottomObstruction)
                let match = targetRect(target, end: focusRange?.endUtf8, in: text) ?? rect
                guard let destination = pending.request.scrollTarget(lineY: rect.minY, textInset: text.textContainerInset.top,
                    target: match, visible: visible, keepVisible: pending.keepVisible) else { return }
                desired = destination
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
            let index = pending.request.pageIndex(in: pages, anchor: restoration?.groupStart ?? target)
            if let leaf = currentLeaves.first(where: { $0.page.start == pages[index].start && $0.page.end == pages[index].end }) {
                leaf.update(page: pages[index], index: index)
                if let text = leaf.view as? UITextView { activateLeaf(text) }
            } else {
                let current = pageIndex(paging.viewControllers?.first) ?? index
                paging.setViewControllers([makePage(at: index)], direction: index >= current ? .forward : .reverse, animated: false)
            }
            if let leaf = currentLeaves.first(where: { target >= $0.page.start && target < $0.page.end }), let text = leaf.view as? UITextView { activateLeaf(text) }
            updateEdge(lastPageIndex(paging.viewControllers?.first) == pages.count - 1)
        }
    }

    func applyPendingWindow() {
        guard !isInteracting, let next = pendingWindow, let previous = window else { return }
        pendingWindow = nil
        let visible = captureViewport()?.offset ?? anchor
        guard next.chunks.contains(where:{visible >= $0.startUtf8 && visible < $0.endUtf8}) else { requestMore(visible < next.start ? .backward : .forward); return }
        window = next
        replaceContents(from: previous)
    }

    @discardableResult func appendScrollContents(_ next: ReadingWindow) -> Bool {
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
    func replaceContents(from previous: ReadingWindow) {
        guard let window, let settings else { return }
        rebuilding = true
        defer {
            rebuilding = false; decorateVisibleText(); updateBottomFade()
            visibleTextViews.forEach(configureAccessibility)
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
                  let current = currentLeaves.first {
            guard current.page.start >= window.start, currentLeaves.last!.page.end <= window.end else {
                self.window = previous; requestMore(current.page.firstVisibleOffset < window.start ? .backward : .forward); return
            }
            let visible = current.page.firstVisibleOffset
            pages = paginate(window,preserving:pages,keeping:visible)
            guard !pages.isEmpty else { return }
            let index = pages.lastIndex(where:{$0.start<=visible}) ?? 0
            let active = anchorLeaf?.page.firstVisibleOffset
            if paging.viewControllers?.first is ReadingPageGroupController {
                paging.setViewControllers([makePage(at: index)], direction: .forward, animated: false)
                if let active, let leaf = currentLeaves.first(where: { $0.page.start <= active && $0.page.end > active }), let text = leaf.view as? UITextView { activateLeaf(text) }
            } else {
                current.update(page: pages[index], index: index)
                paging.setViewControllers([current], direction: .forward, animated: false)
            }
            updateEdge(lastPageIndex(paging.viewControllers?.first) == pages.count - 1)
        } else if let paging = pageController, paging.viewControllers?.first is ReaderCoverController {
            pages = paginate(window, preserving: pages)
            if let cover = paging.viewControllers?.first { paging.setViewControllers([cover], direction: .forward, animated: false) }
        }
    }

    func rebuild() {
        guard let window, let settings else { return }
        rebuilding = true
        pageTransitioning = false
        programmaticPageTransition = false
        reportGeneration += 1
        defer { restoreNativeSelection(); rebuilding = false; needsRebuild = false }
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
            text.backgroundColor = .clear
            text.isOpaque = false
            text.contentInsetAdjustmentBehavior = .never
            text.contentInset.bottom = ReadingTextMetrics.scrollFadeHeight(bottomSafeArea: stableInsets.bottom)
            text.textContainerInset = textInsets
            // Populate after UITextView has configured the typesetter, just as
            // for later window replacements (including fallback emoji fonts).
            storage.setAttributedString(styledScrollText(window))
            text.accessibilityIdentifier = "scrollText"
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { text.accessibilityValue = String(anchor) }
            #endif
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
            paging.view.backgroundColor = theme.paper
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

}
