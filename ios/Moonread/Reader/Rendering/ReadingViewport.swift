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
    var layoutVersion = ReadingTypography.layoutVersion
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
        guard let saved = restoring, saved.layoutVersion == ReadingTypography.layoutVersion, saved.size == size, saved.settings == settings, saved.typeSize == typeSize, saved.pageSize == pageSize, saved.leafCount == leafCount else { return nil }
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
    private let listeningToolInstallations = NSMapTable<UIViewController, NSUUID>.weakToStrongObjects()
    init(capture: (() -> ReadingViewport?)? = nil, range: (() -> (UInt64, UInt64)?)? = nil) { captureOverride = capture; rangeOverride = range }
    func statisticsRange() -> (UInt64, UInt64)? { rangeOverride.map { $0() } ?? controller?.statisticsRange() }
    func capture() -> ReadingViewport? { captureOverride.map { $0() } ?? controller?.captureViewport() }
    func hasBlockingPresentation(allowingReaderAccessory: Bool, allowAccessoryTransitions: Bool = false) -> Bool {
        guard let controller else { return false }
        func modal(in container: UIViewController) -> UIViewController? {
            if let presented = container.presentedViewController { return presented }
            for child in container.children {
                if let presented = modal(in: child) { return presented }
            }
            return nil
        }
        // Only this reader's ancestors, never another scene or tab's content.
        var ancestor = controller.parent
        var presented = modal(in: controller)
        while let current = ancestor {
            if let modal = current.presentedViewController { presented = modal }
            ancestor = current.parent
        }
        guard let presented else { return false }
        guard allowingReaderAccessory else { return true }
        if !allowAccessoryTransitions, presented.isBeingPresented || presented.isBeingDismissed { return true }
        // SwiftUI identifies the current small accessory. Exempt only its own
        // layer; a task presented above it (even by a contained child) blocks.
        return modal(in: presented) != nil
    }

    /// Listening permits each known tool layer of this opening independently.
    /// An unmarked child above an allowed tool can still be a system task.
    func hasBlockingListeningPresentation(opening: UUID?, awaitingToolContent: Bool = false) -> Bool {
        guard let controller else { return false }
        var checked = Set<ObjectIdentifier>()
        func marked(_ owner: UIViewController, for alertTitle: String?) -> Bool {
            if let marker = owner as? ReaderListeningToolMarker,
               let opening, marker.opening == opening, marker.alertTitle == alertTitle { return true }
            return owner.children.contains { marked($0, for: alertTitle) }
        }
        func blocked(in owner: UIViewController, includingChildren: Bool) -> Bool {
            if let presented = owner.presentedViewController, checked.insert(ObjectIdentifier(presented)).inserted {
                if let alert = presented as? UIAlertController, let title = alert.title {
                    guard marked(alert.presentingViewController ?? owner, for: title) else { return true }
                } else if let opening, marked(presented, for: nil) {
                    // Preserve provenance if SwiftUI removes the witness
                    // before UIKit completes this same controller's exit.
                    listeningToolInstallations.setObject(opening as NSUUID, forKey: presented)
                } else if !presented.isBeingDismissed || opening == nil
                            || listeningToolInstallations.object(forKey: presented).map({ $0 as UUID }) != opening {
                    // UIKit can begin a SwiftUI sheet transition before its
                    // hosted children exist. The next check must find the
                    // opening's marker; this never admits a new play request.
                    guard awaitingToolContent, opening != nil, presented.isBeingPresented,
                          presented.children.isEmpty else { return true }
                }
                if blocked(in: presented, includingChildren: true) { return true }
            }
            return includingChildren && owner.children.contains { blocked(in: $0, includingChildren: true) }
        }
        var owner: UIViewController? = controller
        while let current = owner {
            if blocked(in: current, includingChildren: current === controller) { return true }
            owner = current.parent
        }
        return false
    }
}

extension EnvironmentValues {
    @Entry var readerListeningOpening: UUID? = nil
}

/// Marks native content by reading opening, without changing UIKit ownership.
final class ReaderListeningToolMarker: UIViewController {
    var opening: UUID?
    var alertTitle: String?
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
}

private struct ReaderListeningToolWitness: UIViewControllerRepresentable {
    let opening: UUID
    let alertTitle: String?
    func makeUIViewController(context: Context) -> ReaderListeningToolMarker {
        let marker = ReaderListeningToolMarker()
        updateUIViewController(marker, context: context)
        return marker
    }
    func updateUIViewController(_ marker: ReaderListeningToolMarker, context: Context) {
        marker.opening = opening
        marker.alertTitle = alertTitle
    }
}

private struct ReaderListeningToolPresentation: ViewModifier {
    @Environment(\.readerListeningOpening) private var opening
    let alertTitle: String?
    func body(content: Content) -> some View {
        content.background {
            if let opening { ReaderListeningToolWitness(opening: opening, alertTitle: alertTitle) }
        }
    }
}

extension View {
    func readerListeningToolPresentation(alertTitle: String? = nil) -> some View {
        modifier(ReaderListeningToolPresentation(alertTitle: alertTitle))
    }
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

/// Readiness of the local renderer, independent of tool presentation.
@MainActor @Observable final class ReadingLayoutStatus {
    private(set) var hasValidLayout = false
    func committed() { hasValidLayout = true }
}
