import SwiftUI
import UIKit

@MainActor
final class PageController: UIViewController {
    private(set) var page: TextPage
    private(set) var index: Int
    init(page: TextPage, index: Int) { self.page = page; self.index = index; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let text = page.makeTextView(frame: .zero)
        text.accessibilityIdentifier = "pageText"
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { text.accessibilityValue = String(page.start) }
        #endif
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
