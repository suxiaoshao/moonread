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
    var pageSize: CGSize? = nil
    var leafCount = 1
    var groupStart: UInt64? = nil
}


@MainActor
struct ReadingNavigation {
    var placement: ReadingTargetPlacement = .start
    var bottomObstruction: CGFloat = 0
    var restoring: ReadingViewport?
    func restoration(size: CGSize, settings: ReaderSettings?, typeSize: DynamicTypeSize, pageSize: CGSize? = nil, leafCount: Int = 1) -> ReadingViewport? {
        guard let saved = restoring, saved.size == size, saved.settings == settings, saved.typeSize == typeSize, saved.pageSize == pageSize, saved.leafCount == leafCount else { return nil }
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

/// One local rectangle policy for both capacity prediction and native text.
/// UIKit's reserved-region frame already contains its interactive margins.
enum ReadingContainerRegions {
    static func valid(_ surface: CGRect, inside canvas: CGRect, minimumHeight: CGFloat) -> Bool {
        [surface.minX, surface.minY, surface.width, surface.height].allSatisfy(\.isFinite)
            && surface.width >= 80 && surface.height >= minimumHeight && canvas.contains(surface)
    }
    static func available(_ surface: CGRect, blocked: [CGRect]) -> [CGRect] {
        blocked.reduce([surface]) { regions, frame in
            regions.flatMap { region -> [CGRect] in
                let overlap = region.intersection(frame)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [region] }
                if overlap.height >= overlap.width {
                    return [CGRect(x: region.minX, y: region.minY, width: overlap.minX - region.minX, height: region.height),
                            CGRect(x: overlap.maxX, y: region.minY, width: region.maxX - overlap.maxX, height: region.height)].filter { $0.width > 0 }
                }
                return [CGRect(x: region.minX, y: region.minY, width: region.width, height: overlap.minY - region.minY),
                        CGRect(x: region.minX, y: overlap.maxY, width: region.width, height: region.maxY - overlap.maxY)].filter { $0.height > 0 }
            }
        }
    }
    static func permitsSpread(in size: CGSize) -> Bool { size.width > size.height }
}

/// Readiness and epoch of the local renderer, never an inspector capacity input.
@MainActor @Observable final class ReadingLayoutStatus {
    private(set) var hasValidLayout = false
    func committed() { hasValidLayout = true }
}
