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
        } else if let page = currentLeaves.first {
            if (currentLeaves.last?.index ?? page.index) >= pages.count - max(2, leafFrames.count * 2) { requestMore(.forward) }
            if page.index<=1 { requestMore(.backward) }
        }
    }
    func requestMore(_ direction: ReadingDirection) {
        guard let window, let cursor=direction == .forward ? window.nextCursor : window.previousCursor,
              let keep=protectedSourceRange() else { return }
        let admit = requestWindow
        requestedFrontiers.request(direction, cursor: cursor, keeping: keep) { admit(direction, keep) }

    }

    func report(_ offset: UInt64, settled: Bool) {
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
