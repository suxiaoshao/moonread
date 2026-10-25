import SwiftUI
import UIKit

extension ReadingController {
    func makePage(at index: Int) -> UIViewController {
        if index == -1 { return makeCover() }
        let controller = PageController(page: pages[index], index: index)
        if let text = controller.view as? UITextView { text.delegate = self; configureAccessibility(text); decorate(text, base: controller.page.start) }
        return controller
    }

    func makeCover() -> ReaderCoverController {
        let cover = ReaderCoverController(title: coverTitle ?? "", information: coverInformation, showDetails: showBookDetails, theme: theme, background: settings?.mode == .scroll ? .clear : paperBackground)
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
        if let text = activeTextView { configureAccessibility(text) }
        let generation = reportGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == reportGeneration else { return }
            coverChanged?(visible)
        }
    }

    func pageIndex(_ controller: UIViewController?) -> Int? {
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

    func movePage(_ direction: Int) {
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
