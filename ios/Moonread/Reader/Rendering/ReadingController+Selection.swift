import SwiftUI
import UIKit

extension ReadingController {
    @objc func tappedBody(_ gesture: UITapGestureRecognizer) {
        statisticsInteraction()
        if let text = visibleTextViews.first(where: { $0.bounds.contains(gesture.location(in: $0)) }) {
            activateLeaf(text, userInitiated: true)
            let ids = annotationIDs(at: gesture.location(in: text), in: text)
            if !ids.isEmpty { showAnnotations(ids, in: text); return }
        }
        if controlsVisible || settings?.mode != .pages { toggleControls?(); return }
        let fraction = gesture.location(in: readingSurface).x / max(1, readingSurface.bounds.width)
        if fraction < 0.28 { movePage(-1) }
        else if fraction > 0.72 { movePage(1) }
        else { toggleControls?() }
    }
    @objc func ignoredDoubleTap() { statisticsInteraction() }

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
        guard let range = Self.annotationRange(context, mapping: mapping, base: base) else { return }
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

    static func annotationRange(_ context: AnnotationSelection, mapping: TextCoordinates, base: UInt64) -> NSRange? {
        guard context.end > base, context.start < base + UInt64(mapping.byteCount),
              let range = mapping.displayRange(Int(max(base, context.start) - base)..<Int(min(base + UInt64(mapping.byteCount), context.end) - base)), range.length > 0 else { return nil }
        return range
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

    func endAnnotationMenu(clearSelection: Bool) {
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

    static var pageActionNames: [String] { [String(localized: "上一页"), String(localized: "下一页")] }
    func configureAccessibility(_ text: UITextView) {
        (text as? ReadingTextView)?.copySelection = { [weak self] start, end in
            guard let self else { return }
            let full = retainedSelection ?? (min(selectionStart ?? start, start), max(selectionStart ?? end, end))
            selection?(full.0, full.1, .copy)
        }
        text.isSelectable = allowsSelection && !isCoverVisible
        text.accessibilityLabel = isCoverVisible ? String(localized: "封面，\(coverTitle ?? "")") : (text as? ReadingTextView)?.readingText.text
        text.accessibilityValue = isCoverVisible ? "" : nil
        text.accessibilityCustomActions = [UIAccessibilityCustomAction(name: controlsVisible ? String(localized: "隐藏阅读工具") : String(localized: "显示阅读工具")) { [weak self] _ in
            self?.toggleControls?()
            return true
        }]
        if isCoverVisible {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { text.accessibilityValue = String(anchor) }
            #endif
            text.accessibilityCustomActions?.append(UIAccessibilityCustomAction(name: String(localized: "开始阅读")) { [weak self, weak text] _ in
                guard let self, let text else { return false }
                readingBegan?()
                text.setContentOffset(CGPoint(x: 0, y: self.scrollCoverHeight), animated: !reduceMotion)
                reportCover(false); report(window.flatMap { ReadingText($0).firstVisibleOffset } ?? anchor, settled: true)
                return true
            })
            return
        }
        if settings?.mode == .pages {
            text.accessibilityCustomActions?.append(contentsOf: [
                UIAccessibilityCustomAction(name: Self.pageActionNames[0]) { [weak self] _ in
                    self?.movePage(-1)
                    return true
                },
                UIAccessibilityCustomAction(name: Self.pageActionNames[1]) { [weak self] _ in
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            text.accessibilityValue = String(anchor)
        }
        #endif
    }

    func textBase(_ text: UITextView) -> UInt64 {
        // During deferred replacement the native view still owns its old
        // projection. Never pair that mapping with the new window's base.
        (text as! ReadingTextView).readingText.sourceStart
    }

    func textCoordinates(_ text: UITextView) -> TextCoordinates {
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
            let full = retainedSelection ?? (min(selectionStart ?? from, from), max(selectionStart ?? to, to))
            context = AnnotationSelection(start: full.0, end: full.1, annotations: annotations)
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

}
