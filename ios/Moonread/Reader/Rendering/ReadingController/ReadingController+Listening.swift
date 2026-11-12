import UIKit

extension ReadingController {
    func updateListening(cursor: ListeningCursor?, following: Bool) {
        let changed = listeningCursor?.sentence != cursor?.sentence
        listeningCursor = cursor; listeningFollows = following
        if changed { for text in visibleTextViews { decorateListening(text) } }
        applyListeningFollow()
    }

    /// Pure display navigation: no user interaction, history, query or save.
    /// Keep a spoken unit still while it is visible, including the right leaf.
    func applyListeningFollow() {
        guard listeningFollows, let cursor = listeningCursor, !needsRebuild, !rebuilding,
              !isInteracting, viewIfLoaded?.window != nil else { return }
        let target = cursor.unit.startUtf8
        if let text = scrollText {
            guard let rect = targetRect(target, end: cursor.unit.endUtf8, in: text) else { return }
            let visible = contextViewport(in: text, bottomObstruction: 0)
            guard let y = ReadingNavigation(placement: .context).scrollTarget(lineY: rect.minY,
                textInset: text.textContainerInset.top, target: rect, visible: visible, keepVisible: true) else { return }
            let maximum = max(0, text.contentSize.height + text.contentInset.bottom - text.bounds.height)
            text.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, y))), animated: false)
            layoutAnchor = target
        } else {
            guard !pages.isEmpty, window.map({ target >= $0.start && target < $0.end }) == true,
                  !currentLeaves.contains(where: { target >= $0.page.start && target < $0.page.end }) else { return }
            anchor = target; layoutAnchor = target
            pendingNavigation = (ReadingNavigation(placement: .context), true)
            applyNavigation()
        }
    }

    func decorateListening(_ text: UITextView) {
        guard let layout = text.layoutManager as? ReadingLayoutManager else { return }
        let mapping = textCoordinates(text), base = textBase(text)
        let end = base + UInt64(mapping.byteCount)
        guard let sentence = listeningCursor?.sentence, text.selectedRange.length == 0,
              retainedSelection == nil, focusRange == nil, sentence.startUtf8 < end, sentence.endUtf8 > base,
              let range = mapping.displayRange(Int(max(base, sentence.startUtf8) - base)..<Int(min(end, sentence.endUtf8) - base)) else {
            layout.setListeningDecoration(nil); return
        }
        layout.setListeningDecoration(.init(range: range, color: theme.accent.withAlphaComponent(theme.style == .dark ? 0.18 : 0.14)))
    }
}
