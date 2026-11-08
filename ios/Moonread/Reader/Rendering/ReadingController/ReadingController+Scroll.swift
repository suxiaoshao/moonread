import SwiftUI
import UIKit

extension ReadingController {
    func updateEdge(_ edge: Bool) {
        guard edge != reportedEdge else { return }
        reportedEdge = edge
        DispatchQueue.main.async { [weak self] in self?.edgeChanged?(edge) }
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView === scrollText || currentLeaves.contains(where: { $0.viewIfLoaded === textView }) else { return }
        if !preparingAnnotationMenu, textView === annotationMenuText, let tappedAnnotation, textView.selectedRange != tappedAnnotation.range {
            endAnnotationMenu(clearSelection: false)
        }
        if !rebuilding {
            if textView.selectedRange.length > 0 { autoReading?.end() }
            if let selected = retainedSelection {
                let expected = Self.annotationRange(AnnotationSelection(start: selected.0, end: selected.1, annotations: []),
                    mapping: textCoordinates(textView), base: textBase(textView))
                if textView === activeTextView {
                    if textView.selectedRange != expected { retainedSelection = nil }
                } else if textView.selectedRange.length > 0 { retainedSelection = nil }
            }
            if textView.selectedRange.length > 0 {
                let previous = anchorLeaf?.index
                activateLeaf(textView, userInitiated: true)
                if currentLeaves.count > 1, previous != anchorLeaf?.index, let leaf = anchorLeaf {
                    readingBegan?()
                    report(leaf.page.firstVisibleOffset, settled: true)
                }
            }
            decorateVisibleText()
        }
        if !rebuilding, textView.selectedRange.length > 0 {
            statisticsInteraction(); Onboarding.shared.didSelectText()
        }
        guard textView.selectedRange.length == 0 else { return }
        DispatchQueue.main.async { [weak self] in self?.applyPendingWindow(); self?.reevaluateWindowRequests() }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { autoReading?.end(); endAnnotationMenu(clearSelection: true); statisticsInteraction(); readingBegan?() }

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
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { autoReading?.end(); reportScroll(settled: true) }

    func reportScroll(settled: Bool) {
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

    func automaticLayoutAvailable() -> Bool {
        guard settings?.mode == .scroll, !isCoverVisible, !rebuilding, !needsRebuild,
              let text = scrollText, text.bounds.height > 0, text.window != nil,
              text.selectedRange.length == 0, !isInteracting else { return false }
        if let scene = text.window?.windowScene, scene.activationState != .foregroundActive { return false }
        return true
    }

    func automaticReadingGeometry() -> ReaderAutoReading.Geometry? {
        guard automaticLayoutAvailable(), let text = scrollText, let settings else { return nil }
        let metrics = ReadingTypography.bodyMetrics(settings)
        return .init(bodyWidth: text.textContainer.size.width - 2 * text.textContainer.lineFragmentPadding,
            fontPointSize: metrics.pointSize, lineAdvance: metrics.lineAdvance)
    }

    func advanceAutomaticReading(by distance: CGFloat) -> AutomaticReadingStep {
        guard automaticLayoutAvailable(), let text = scrollText, let window else { return .blocked }
        let end = max(0, text.contentSize.height + text.contentInset.bottom - text.bounds.height)
        let remaining = end - text.contentOffset.y
        if remaining <= 0.01 { return window.isEndOfBook ? .end : .preparing }
        guard distance > 0 else { return .advanced(0) }
        let previous = text.contentOffset.y
        text.setContentOffset(CGPoint(x: text.contentOffset.x, y: min(end, previous + distance)), animated: false)
        updateBottomFade()
        return .advanced(Double(min(1, max(0, (text.contentOffset.y - previous) / distance))))
    }

    func updateAutomaticReadingEdge() {
        guard let autoReading, let text = scrollText, let window else { return }
        if autoReading.phase == .preparing || autoReading.phase == .failed {
            text.layoutIfNeeded()
            if text.contentSize.height + text.contentInset.bottom - text.bounds.height - text.contentOffset.y > 0.5 {
                autoReading.prepared()
            } else if window.isEndOfBook { autoReading.reachedEnd() }
        } else if autoReading.phase == .finished,
                  text.contentSize.height + text.contentInset.bottom - text.bounds.height - text.contentOffset.y > 1 { autoReading.end() }
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
        } else if let current = pageController?.viewControllers?.first, let first = pageIndex(current), first >= 0 {
            if (lastPageIndex(current) ?? first) >= pages.count - max(2, leafFrames.count * 2) { requestMore(.forward) }
            if first <= 1 { requestMore(.backward) }
        }
    }
    func requestMore(_ direction: ReadingDirection) {
        guard let window, let cursor=direction == .forward ? window.nextCursor : window.previousCursor,
              let keep=protectedSourceRange() else { return }
        let admit = requestWindow
        requestedFrontiers.request(direction, cursor: cursor, keeping: keep) { admit(direction, keep) }

    }

    func report(_ offset: UInt64, settled: Bool) {
        awaitBodyDisplay()
        anchor = offset
        layoutAnchor = offset
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            scrollText?.accessibilityValue = String(offset)
            pageController?.viewControllers?.first?.view.accessibilityValue = String(offset)
        }
        #endif
        let generation = reportGeneration
        // Delegate callbacks may occur during a SwiftUI representable update.
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == reportGeneration else { return }
            changed?(offset, settled)
        }
    }

}
