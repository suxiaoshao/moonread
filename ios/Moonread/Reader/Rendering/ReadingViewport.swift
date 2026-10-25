import SwiftUI
import UIKit

@MainActor
enum ReadingTextMetrics {
    // Pages stop above the home indicator; scrolling text extends behind its fade.
    static let insets = UIEdgeInsets(top: 16, left: 16, bottom: 4, right: 16)

    static func scrollFadeHeight(bottomSafeArea: CGFloat) -> CGFloat {
        bottomSafeArea > 0 ? bottomSafeArea : 24
    }

    static func contentSize(in size: CGSize, insets: UIEdgeInsets = ReadingTextMetrics.insets) -> CGSize {
        CGSize(width: max(1, size.width - insets.left - insets.right),
               height: max(1, size.height - insets.top - insets.bottom))
    }

    static func fadeOpacity(remaining: CGFloat, isEndOfBook: Bool, isPreparedTail: Bool = false, height: CGFloat = 24) -> Float {
        (isEndOfBook || isPreparedTail) ? Float(min(1, max(0, remaining) / max(1, height))) : 1
    }
}


enum ReadingTargetPlacement { case start, context, cover }


/// Transient display geometry, kept only for the current reader's return point.
/// Persistent locations remain Rust-owned UTF-8 offsets.
@MainActor
struct ReadingViewport {
    let offset: UInt64
    let lineY: CGFloat
    let size: CGSize
    let settings: ReaderSettings
    let typeSize: DynamicTypeSize
    let pages: [TextPage]
    var isCover = false
}


@MainActor
struct ReadingNavigation {
    var placement: ReadingTargetPlacement = .start
    var bottomObstruction: CGFloat = 0
    var restoring: ReadingViewport?
    func restoration(size: CGSize, settings: ReaderSettings?, typeSize: DynamicTypeSize) -> ReadingViewport? {
        guard let saved = restoring, saved.size == size, saved.settings == settings, saved.typeSize == typeSize else { return nil }
        return saved
    }
    func pageIndex(in pages: [TextPage], anchor: UInt64) -> Int { pages.lastIndex { $0.start <= anchor } ?? 0 }
    func scrollTarget(lineY: CGFloat, textInset: CGFloat, target: CGRect, visible: CGRect, keepVisible: Bool) -> CGFloat? {
        if let restoring { return lineY + textInset - restoring.lineY }
        if placement == .context {
            if keepVisible && target.minY >= visible.minY + 8 && target.maxY <= visible.maxY - 8 { return nil }
            return target.minY - ReadingTextMetrics.insets.top - visible.height / 3
        }
        return lineY
    }
}


@MainActor
final class ReadingViewportAccess {
    weak var controller: ReadingController?
    private let captureOverride: (() -> ReadingViewport?)?
    private let rangeOverride: (() -> (UInt64, UInt64)?)?
    init(capture: (() -> ReadingViewport?)? = nil, range: (() -> (UInt64, UInt64)?)? = nil) { captureOverride = capture; rangeOverride = range }
    func statisticsRange() -> (UInt64, UInt64)? { rangeOverride.map { $0() } ?? controller?.statisticsRange() }
    func capture() -> ReadingViewport? { captureOverride.map { $0() } ?? controller?.captureViewport() }
}


@MainActor
/// Admission belongs to the application, independently of native viewport geometry.
struct ReadingFrontierAdmissions {
    private var accepted = Set<String>()
    mutating func reset() { accepted.removeAll() }
    mutating func request(_ direction: ReadingDirection, cursor: UInt64, keeping span: SourceSpan, admit: () -> Bool) {
        let key = "\(direction)-\(cursor)-\(span.startUtf8)-\(span.endUtf8)"
        guard !accepted.contains(key) else { return }
        if admit() { accepted.insert(key) }
    }
}
