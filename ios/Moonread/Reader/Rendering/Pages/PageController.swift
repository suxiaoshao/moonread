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

/// One pager item owns consecutive source leaves. Its first source range is the
/// identity: inserting earlier window pages never re-pairs the visible spread.
@MainActor
final class ReadingPageGroupController: UIViewController {
    let leaves: [PageController]
    let frames: [CGRect]
    private(set) var activeLeaf: PageController?
    let waitingForText: Bool
    init(leaves: [PageController], frames: [CGRect], waitingForText: Bool) {
        self.leaves = leaves; self.frames = frames; self.waitingForText = waitingForText
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = UIView()
        for leaf in leaves {
            addChild(leaf); view.addSubview(leaf.view); leaf.didMove(toParent: self)
        }
        if waitingForText, frames.count > leaves.count {
            let activity = UIActivityIndicatorView(style: .medium)
            activity.accessibilityLabel = String(localized: "正在准备正文")
            activity.startAnimating(); activity.tag = 1
            view.addSubview(activity)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for (leaf, frame) in zip(leaves, frames) { leaf.view.frame = frame }
        if let activity = view.viewWithTag(1), frames.count > leaves.count {
            activity.center = CGPoint(x: frames[leaves.count].midX, y: frames[leaves.count].midY)
        }
    }
    func activate(_ text: UITextView) {
        activeLeaf = leaves.first { $0.viewIfLoaded === text }
    }
    var anchorLeaf: PageController? { activeLeaf ?? leaves.first }
}
