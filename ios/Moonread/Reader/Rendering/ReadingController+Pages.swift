import SwiftUI
import UIKit

extension ReadingController {
    func makePage(at index: Int, endingBefore end: Int? = nil) -> UIViewController {
        if index == -1 { return makeCover() }
        guard leafFrames.count > 1 else { return makeLeaf(at: index) }
        let indices = index..<min(end ?? pages.count, index + leafFrames.count)
        let group = ReadingPageGroupController(leaves: indices.map(makeLeaf), frames: leafFrames,
            waitingForText: end == nil && indices.count < leafFrames.count && window?.isEndOfBook != true)
        group.view.backgroundColor = paperBackground
        for leaf in group.leaves { if let text = leaf.view as? UITextView { paintPaper(on: text) } }
        return group
    }

    func makeLeaf(at index: Int) -> PageController {
        let controller = PageController(page: pages[index], index: index)
        if let text = controller.view as? UITextView {
            text.delegate = self; configureAccessibility(text); decorate(text, base: controller.page.start)
        }
        return controller
    }

    var currentLeaves: [PageController] {
        let current = pageController?.viewControllers?.first
        if let group = current as? ReadingPageGroupController { return group.leaves }
        return (current as? PageController).map { [$0] } ?? []
    }
    var anchorLeaf: PageController? {
        (pageController?.viewControllers?.first as? ReadingPageGroupController)?.anchorLeaf ?? currentLeaves.first
    }
    func activateLeaf(_ text: UITextView, userInitiated: Bool = false) {
        (pageController?.viewControllers?.first as? ReadingPageGroupController)?.activate(text)
        if userInitiated, let leaf = currentLeaves.first(where: { $0.viewIfLoaded === text }) {
            layoutAnchor = leaf.page.firstVisibleOffset
        }
    }
    func lastPageIndex(_ controller: UIViewController?) -> Int? {
        if let last = (controller as? ReadingPageGroupController)?.leaves.last { return sourceIndex(of: last.page) }
        return pageIndex(controller)
    }

    private func sourceIndex(of page: TextPage) -> Int? {
        pages.firstIndex { $0.start == page.start && $0.end == page.end }
    }

    /// A single page is a one-leaf group. Check the whole group before updating
    /// any indices; an adjacent spread sharing just one leaf cannot be reused.
    func reuseCurrentPageGroup(containing index: Int, startingAt requiredStart: Int? = nil) -> Bool {
        let leaves = currentLeaves
        guard let first = leaves.first, let start = requiredStart ?? sourceIndex(of: first.page),
              pages.indices.contains(start) else { return false }
        let range = start..<min(pages.count, start + max(1, leafFrames.count))
        guard range.contains(index), leaves.count == range.count,
              zip(leaves, range).allSatisfy({ $0.page.start == pages[$1].start && $0.page.end == pages[$1].end }) else { return false }
        for (leaf, index) in zip(leaves, range) { leaf.update(page: pages[index], index: index) }
        return true
    }

    func makeCover() -> ReaderCoverController {
        let cover = ReaderCoverController(title: coverTitle ?? "", information: coverInformation, showDetails: showBookDetails, theme: theme, background: settings?.mode == .scroll ? .clear : paperBackground)
        cover.view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "显示阅读工具")) { [weak self] _ in self?.toggleControls?(); return true },
            UIAccessibilityCustomAction(name: String(localized: "开始阅读")) { [weak self] _ in
                guard let self else { return false }
                if let text = scrollText {
                    readingBegan?()
                    text.setContentOffset(CGPoint(x: 0, y: self.scrollCoverHeight), animated: !reduceMotion)
                    reportCover(false); report(window.flatMap { ReadingText($0).firstVisibleOffset } ?? anchor, settled: true)
                } else { movePage(1) }
                return true
            }
        ]
        return cover
    }

    var scrollCoverHeight: CGFloat { hasCover ? readingSurface.bounds.height : 0 }

    func updateScrollCover(in text: UITextView) {
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

    func removeScrollCover() {
        scrollCover?.willMove(toParent: nil)
        scrollCover?.view.removeFromSuperview()
        scrollCover?.removeFromParent()
        scrollCover = nil
    }

    func reportCover(_ visible: Bool) {
        guard isCoverVisible != visible else { return }
        isCoverVisible = visible
        visibleTextViews.forEach(configureAccessibility)
        let generation = reportGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == reportGeneration else { return }
            coverChanged?(visible)
        }
    }

    func pageIndex(_ controller: UIViewController?) -> Int? {
        if controller is ReaderCoverController { return -1 }
        let first = (controller as? ReadingPageGroupController)?.leaves.first ?? (controller as? PageController)
        return first.flatMap { sourceIndex(of: $0.page) }
    }

    private func reportPage(_ index: Int) {
        reportCover(index == -1)
        if pages.indices.contains(index) {
            report(pages[index].firstVisibleOffset, settled: true)
            if (lastPageIndex(pageController?.viewControllers?.first) ?? index) >= pages.count - max(2, leafFrames.count * 2) { requestMore(.forward) }
            if index <= 1 { requestMore(.backward) }
        }
    }

    func movePage(_ direction: Int) {
        guard !rebuilding, !pageTransitioning, let paging = pageController,
              let current = pageIndex(paging.viewControllers?.first) else { return }
        guard direction > 0 || current > (hasCover ? -1 : 0) else { requestMore(.backward); return }
        let index = direction > 0 ? (lastPageIndex(paging.viewControllers?.first) ?? current) + 1 : (current == 0 && hasCover ? -1 : max(0, current - leafFrames.count))
        guard pages.indices.contains(index) || (index == -1 && hasCover) else { updateEdge(direction > 0); requestMore(direction > 0 ? .forward : .backward); return }
        statisticsInteraction(); readingBegan?()
        pageTransitioning = true
        programmaticPageTransition = true
        let generation = reportGeneration
        paging.setViewControllers([makePage(at: index, endingBefore: direction < 0 ? current : nil)],
                                  direction: direction > 0 ? .forward : .reverse,
                                  animated: !reduceMotion && !UIAccessibility.isReduceMotionEnabled) { [weak self] complete in
            guard let self, generation == self.reportGeneration else { return }
            self.pageTransitioning = false
            self.programmaticPageTransition = false
            if complete { self.reportPage(index) }
            self.updateEdge((self.lastPageIndex(paging.viewControllers?.first) ?? index) == self.pages.count - 1)
            self.applyPendingWindow()
        }
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let current = pageIndex(viewController), current > (hasCover ? -1 : 0) else { return nil }
        return makePage(at: (current == 0 && hasCover ? -1 : max(0, current - leafFrames.count)), endingBefore: current)
    }
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let current = pageIndex(viewController), (lastPageIndex(viewController) ?? current) + 1 < pages.count else { return nil }
        return makePage(at: (lastPageIndex(viewController) ?? current) + 1)
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard pageViewController === pageController else { return }
        pageTransitioning = false
        guard completed, let current = pageIndex(pageViewController.viewControllers?.first) else { applyPendingWindow(); return }
        visibleTextViews.forEach(configureAccessibility)
        reportPage(current)
        updateEdge(lastPageIndex(pageViewController.viewControllers?.first) == pages.count - 1)
        applyPendingWindow()
    }
    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        guard pageViewController === pageController else { return }
        pageTransitioning = true
        if !programmaticPageTransition { statisticsInteraction(); readingBegan?() }
    }
}
