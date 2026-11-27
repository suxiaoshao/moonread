import MoonreadDesign
import Combine
import SwiftUI
import UIKit
import MarkdownView

public typealias AIMessageRowRenderer = @MainActor (String, @escaping AIProcessExpansionHandler) -> AnyView

public struct AIMessageListRequest: Equatable {
    public enum Target: Equatable { case bottom, preserve, row(String) }
    let id = UUID()
    let target: Target

    public init(target: Target = .bottom) { self.target = target }
}

/// UIKit owns recycling, sizing and scroll timing. SwiftUI owns only each cell's contents.
public struct AIMessageList: UIViewControllerRepresentable {
    let rows: [AIMessageViewportRow]
    let presentation: AIMessagePresentation
    let toggleProcess: AIProcessExpansionHandler
    let replyFeedback: (String) -> (text: String, present: (UIViewController, ThemeSurface) -> Void)?
    let background: UIColor
    let bottomInset: CGFloat
    let request: AIMessageListRequest
    let highlightedTurn: String?
    @Binding var atBottom: Bool
    let dismissKeyboard: () -> Void
    let content: AIMessageRowRenderer
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.moonreadReduceMotion) private var reduceMotion

    public init(rows: [AIMessageViewportRow], presentation: AIMessagePresentation, background: UIColor,
                bottomInset: CGFloat, request: AIMessageListRequest, highlightedTurn: String?, atBottom: Binding<Bool>,
                dismissKeyboard: @escaping () -> Void, toggleProcess: @escaping AIProcessExpansionHandler,
                replyFeedback: @escaping (String) -> (text: String, present: (UIViewController, ThemeSurface) -> Void)?,
                content: @escaping AIMessageRowRenderer) {
        self.rows = rows
        self.presentation = presentation
        self.background = background
        self.bottomInset = bottomInset
        self.request = request
        self.highlightedTurn = highlightedTurn
        _atBottom = atBottom
        self.dismissKeyboard = dismissKeyboard
        self.toggleProcess = toggleProcess
        self.replyFeedback = replyFeedback
        self.content = content
    }

    public func makeUIViewController(context: Context) -> UIViewController { AIMessageListController() }
    public func updateUIViewController(_ viewController: UIViewController, context: Context) {
        guard let controller = viewController as? AIMessageListController else { return }
        controller.presentation = presentation
        controller.toggleProcess = toggleProcess
        controller.replyFeedback = replyFeedback
        controller.reportBottom = { atBottom = $0 }
        controller.dismissKeyboard = dismissKeyboard
        controller.update(rows: rows, render: content, background: background, bottomInset: bottomInset,
                          request: request, appearance: .init(theme: theme, typeSize: typeSize, highlightedTurn: highlightedTurn, reduceMotion: reduceMotion))
    }
}

struct AIMessageListAppearance: Equatable {
    let theme: ThemeSurface
    let typeSize: DynamicTypeSize
    let highlightedTurn: String?
    var reduceMotion = false
}

/// Observe self-sizing layout too, not only explicit diffable updates.
private final class AIAnchoredTableView: UITableView {
    var beforeLayout: (() -> Void)?
    var afterLayout: (() -> Void)?
    private(set) var performingLayout = false
    override func layoutSubviews() {
        guard !performingLayout else { super.layoutSubviews(); return }
        performingLayout = true
        beforeLayout?()
        super.layoutSubviews()
        afterLayout?()
        performingLayout = false
    }
}

/// Contents keep their intrinsic height while the cell clips animated height changes.
/// Explicit safe-area policy prevents scrolling from changing a row's intrinsic height.
private final class AIHostedMessageCell: UITableViewCell {
    private var host: UIHostingController<AnyView>?
    private var height: CGFloat = 0
    private weak var parentController: UIViewController?
    private(set) var rowID: String?
    var processToggleLabelFrame: CGRect?
    func configure(_ content: AnyView, row: AIMessageViewportRow, height: CGFloat, parent: UIViewController) {
        if rowID != row.id { processToggleLabelFrame = nil; rowID = row.id }
        self.height = height; parentController = parent
        if let host { host.rootView = content }
        else {
            let host = UIHostingController(rootView: content)
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            contentView.addSubview(host.view)
            self.host = host
        }
        contentView.clipsToBounds = true
        attachHost()
        setNeedsLayout(); layoutIfNeeded()
    }
    @discardableResult func resize(_ height: CGFloat) -> Bool {
        guard abs(self.height - height) > 0.5 else { return false }
        self.height = height
        setNeedsLayout()
        return true
    }
    private func attachHost() {
        guard window != nil, let host, host.parent == nil, let parentController else { return }
        parentController.addChild(host); host.didMove(toParent: parentController)
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil, let host, host.parent != nil {
            host.willMove(toParent: nil); host.removeFromParent()
        } else { attachHost() }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        UIView.performWithoutAnimation {
            host?.view.frame = CGRect(x: 0, y: 0, width: contentView.bounds.width, height: height)
            host?.view.layoutIfNeeded()
        }
    }
}

@MainActor private final class AIStreamFrameTarget: NSObject {
    weak var owner: AIMessageListController?
    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { link.invalidate(); return }
        owner.streamFrame(link)
    }
}

final class AIMessageListController: UITableViewController, UIGestureRecognizerDelegate {
    private struct Anchor { let id: String; let offset: CGFloat }
    private var render: AIMessageRowRenderer?
    weak var presentation: AIMessagePresentation?
    var toggleProcess: AIProcessExpansionHandler?
    var replyFeedback: ((String) -> (text: String, present: (UIViewController, ThemeSurface) -> Void)?)?
    var reportBottom: ((Bool) -> Void)?
    var dismissKeyboard: (() -> Void)?
    private(set) var following = true
    private var rows: [String: AIMessageViewportRow] = [:]
    private var source: UITableViewDiffableDataSource<Int, String>!
    private var appearance: AIMessageListAppearance?
    private var appliedRequest: UUID?
    private var searchTarget: String?
    private var stableAnchor: Anchor?
    private var expansionAnchor: Anchor?
    private var layoutAnchor: Anchor?
    private var applying = false
    private var expansionAnimationPending = false
    private var animatingExpansion = false
    private var animatingProcessRows = false
    private var expansionHeights: [String: CGFloat] = [:]
    private var pendingResizes = DeferredRowMeasurements()
    private var adjusting = false
    private var pendingUpdate: (() -> Void)?
    private var reportedBottom: Bool?
    private var sizingEnvironment: String?
    private var rowSizer: UIHostingController<AnyView>?
    private var streamLink: CADisplayLink?
    private var streamTarget: AIStreamFrameTarget?
    private var replayDisplay: (() -> Void)?
    private var streamVisible = false
    private var smoothFollowing = false
    private var scrollVelocity: CGFloat = 0
    private var streamLineHeight: CGFloat = 20
    private var scrollTime: Double = 0
    private var reducedMotion: Bool { (appearance?.reduceMotion ?? false) || UIAccessibility.isReduceMotionEnabled }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); streamVisible = true
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated); finishStreamPresentation()
    }
    private func finishStreamPresentation() {
        streamVisible = false; presentation?.streamDisplay.flush(); replayDisplay?()
        stopStreamClock(); presentation?.streamDisplay.reset()
    }
    private var lifecycleNotifications: [AnyCancellable] = []
    private func streamBackgrounded() { finishStreamPresentation() }
    private func streamForegrounded() { streamVisible = viewIfLoaded?.window != nil }
    private func startStreamClock() {
        guard streamLink == nil, streamVisible else { return }
        let target = AIStreamFrameTarget(); target.owner = self; streamTarget = target
        let link = CADisplayLink(target: target, selector: #selector(AIStreamFrameTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        streamLink = link; scrollTime = CACurrentMediaTime(); link.add(to: .main, forMode: .common)
    }
    private func stopStreamClock() {
        streamLink?.invalidate(); streamLink = nil; streamTarget = nil; scrollVelocity = 0
    }
    fileprivate func streamFrame(_ link: CADisplayLink) {
        let now = link.timestamp
        if presentation?.streamDisplay.advance(now: now) == true { replayDisplay?() }
        if following && smoothFollowing && !reducedMotion && !animatingExpansion {
            let dt = max(0, min(0.05, now - scrollTime))
            let current = tableView.contentOffset.y
            let distance = current - bottomOffset
            let omega: CGFloat = 32
            let decay = exp(-omega * dt)
            let c = scrollVelocity + omega * distance
            let next = bottomOffset + (distance + c * dt) * decay
            scrollVelocity = (scrollVelocity - omega * c * dt) * decay
            let line = streamLineHeight
            let viewport = max(line, tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom)
            let limit = min(viewport / 8, line / 3 + max(0, abs(distance) - 3 * line) * 0.2)
            adjusting = true
            // Finish within a small fraction of one line; subpixel rounding must
            // not leave a perpetual one-pixel display link tail.
            move(to: abs(distance) <= line / 6 ? bottomOffset : current + min(limit, max(-limit, next - current)))
            adjusting = false
            publishBottom()
        }
        scrollTime = now
        if presentation?.streamDisplay.pending != true && (!following || !smoothFollowing || bottomGap <= 0.25) {
            stopStreamClock()
        }
    }
    private func followBottom() {
        if smoothFollowing && streamVisible && !reducedMotion {
            if bottomGap > 0.25 { startStreamClock() }
        } else { move(to: bottomOffset) }
    }

    private var anchoredTable: AIAnchoredTableView { tableView as! AIAnchoredTableView }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = source.itemIdentifier(for: indexPath),
              let feedback = replyFeedback?(id), let appearance, let window = tableView.window else { return nil }
        let theme = appearance.theme
        let traits = traitCollection
        let markdown = appearance.markdownTheme(traits: traits)
        let background = (tableView.backgroundColor ?? theme.canvas).resolvedColor(with: traits)
        var available = window.bounds.inset(by: window.safeAreaInsets).size
        available.width = min(available.width, tableView.bounds.width)
        let previewSize = available
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: {
            AIReplyPreviewController(text: feedback.text, theme: markdown, background: background, availableSize: previewSize)
        }) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "复制回复"), image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = feedback.text },
                UIAction(title: String(localized: "反馈这条回复"), image: UIImage(systemName: "envelope")) { [weak self] _ in
                    guard let self else { return }
                    feedback.present(self, theme)
                }
            ])
        }
    }

    override func loadView() { tableView = AIAnchoredTableView(frame: .zero, style: .plain) }
    override func viewDidLoad() {
        super.viewDidLoad()
        lifecycleNotifications = [
            MainActorNotifications.observe(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.streamBackgrounded() },
            MainActorNotifications.observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.streamForegrounded() }
        ]
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        tableView.keyboardDismissMode = .interactive
        if #available(iOS 26, *) {
            // Only the viewport extends at the top. The composer and keyboard still own the bottom layout.
            tableView.contentInsetAdjustmentBehavior = .automatic
        } else {
            tableView.contentInsetAdjustmentBehavior = .never
        }
        tableView.accessibilityIdentifier = "aiMessages"
        tableView.alwaysBounceVertical = true
        tableView.register(AIHostedMessageCell.self, forCellReuseIdentifier: "message")
        tableView.register(AINativeMarkdownCell.self, forCellReuseIdentifier: "markdown")
        source = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, path, id in
            if let self, let row = rows[id], let text = row.nativeText, let appearance, let presentation {
                let cell = table.dequeueReusableCell(withIdentifier: "markdown", for: path) as! AINativeMarkdownCell
                let view = presentation.nativeMarkdown.view(id: id, text: text.text, streaming: text.streaming,
                                                            theme: appearance.markdownTheme(traits: traitCollection))
                view.trackedScrollView = table
                cell.mount(view)
                cell.selectionStyle = .none
                cell.backgroundColor = row.turnID == appearance.highlightedTurn ? appearance.theme.accent.withAlphaComponent(0.12) : .clear
                return cell
            }
            let cell = table.dequeueReusableCell(withIdentifier: "message", for: path) as! AIHostedMessageCell
            if let self, let row = rows[id] {
                cell.configure(hostedContent(id, displayedIn: cell), row: row, height: hostedHeight(row), parent: self)
            }
            cell.selectionStyle = .none; cell.backgroundColor = .clear
            return cell
        }
        source.defaultRowAnimation = .top
        anchoredTable.beforeLayout = { [weak self] in
            guard let self, !adjusting, !animatingExpansion, !animatingProcessRows else { return }
            if following {
                adjusting = true; followBottom(); adjusting = false
            } else if !applying { layoutAnchor = expansionAnchor ?? stableAnchor ?? captureAnchor() }
        }
        anchoredTable.afterLayout = { [weak self] in
            guard let self, !adjusting, !animatingExpansion else { return }
            if animatingProcessRows { alignAnimatingProcess(); return }
            if applying {
                if following { adjusting = true; followBottom(); adjusting = false }
                else if let expansionAnchor { settle(anchor: expansionAnchor) }
            } else { settle(anchor: layoutAnchor) }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedTable))
        tap.cancelsTouchesInView = false; tap.delegate = self
        tableView.addGestureRecognizer(tap)
    }
    private func hostedContent(_ id: String, displayedIn cell: AIHostedMessageCell? = nil) -> AnyView {
        let processToggle: Bool
        if case .processToggle? = rows[id]?.kind { processToggle = true } else { processToggle = false }
        let content = render?(id, { [weak self] item in
            self?.toggleProcessItem(rowID: id, item: item)
        }).id(id)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, LayoutTokens.content).padding(.vertical, LayoutTokens.compact)
            .environment(\.moonreadReduceMotion, reducedMotion)
        if processToggle, let cell {
            return AnyView(content.coordinateSpace(.named(AIProcessToggleHitShape.rowSpace))
                .environment(\.aiProcessToggleLabelFrame, { [weak cell] frame in
                    guard cell?.rowID == id else { return }
                    cell?.processToggleLabelFrame = frame
                }))
        }
        // Result cards can resize without a new row version. Only the displayed
        // content observes those changes; the offscreen sizer uses sizeThatFits.
        guard cell != nil, let row = rows[id], case .result = row.kind else { return AnyView(content) }
        let version = row.version
        return AnyView(content.onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.rows[id]?.version == version,
                      abs(size.width - self.tableView.bounds.width) < 0.5 else { return }
                self.hostedContentResized(id, height: size.height)
            }
        })
    }
    private func measureHosted(_ content: AnyView) -> CGFloat {
        if rowSizer == nil {
            let host = UIHostingController(rootView: content)
            host.safeAreaRegions = []
            rowSizer = host
        }
        rowSizer!.rootView = content
        return ceil(rowSizer!.sizeThatFits(in: CGSize(width: tableView.bounds.width, height: .greatestFiniteMagnitude)).height)
    }
    private func hostedHeight(_ row: AIMessageViewportRow) -> CGFloat {
        let key = heightKey(row)
        if let cached = presentation?.messageHeights[key] { return cached }
        let height = measureHosted(hostedContent(row.id))
        if !animatingExpansion { storeMeasuredHeight(height, for: key) }
        return height
    }
    /// Re-measures a visible row whose content grew or shrank without a new row version.
    func hostedContentResized(_ id: String, height: CGFloat) {
        guard let row = rows[id], case .result = row.kind else { return }
        // Geometry observations can arrive while UIKit still owns a snapshot or expansion.
        // Keep the latest measurement and apply it even when that row has no cached height.
        guard height.isFinite, height > 0 else { return }
        pendingResizes.record(id: id, version: row.version, height: Double(height))
        replayPendingResizes()
    }
    private func replayPendingResizes() {
        guard !pendingResizes.isEmpty, !animatingExpansion, !expansionAnimationPending, !applying, expansionHeights.isEmpty else { return }
        var needsLayout = false
        for (id, measured) in pendingResizes.drain(versions: rows.mapValues(\.version)) {
            guard let row = rows[id] else { continue }
            let key = heightKey(row), height = ceil(CGFloat(measured))
            let cacheChanged = presentation?.messageHeights[key].map { abs($0 - height) > 0.5 } ?? true
            if cacheChanged { storeMeasuredHeight(height, for: key) }
            guard let path = source.indexPath(for: id), let cell = tableView.cellForRow(at: path) as? AIHostedMessageCell else { continue }
            if cell.resize(height) || cacheChanged { needsLayout = true }
        }
        if needsLayout { UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) } }
    }
    @objc private func tappedTable(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: tableView)
        if let target = processToggleOverflow(at: point) {
            toggleProcessItem(rowID: target.row, item: .turn(target.turn))
        } else if tableView.indexPathForRow(at: point) == nil { dismissKeyboard?() }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Interactive cell contents keep taps, links, text selection and their own menus.
        let point = touch.location(in: tableView)
        return tableView.indexPathForRow(at: point) == nil || processToggleOverflow(at: point) != nil
    }
    private func processToggleOverflow(at point: CGPoint) -> (row: String, turn: String)? {
        // UIKit hit-testing stops at row bounds. Forward only the part of the
        // SwiftUI interaction shape that falls outside the toggle's own cell.
        for path in tableView.indexPathsForVisibleRows ?? [] {
            guard let id = source.itemIdentifier(for: path), let row = rows[id], case .processToggle = row.kind,
                  let turn = row.turnID, !tableView.rectForRow(at: path).contains(point),
                  let cell = tableView.cellForRow(at: path) as? AIHostedMessageCell, cell.rowID == id,
                  let label = cell.processToggleLabelFrame, !label.isEmpty,
                  cell.convert(AIProcessToggleHitShape.target(for: label), to: tableView).contains(point) else { continue }
            return (id, turn)
        }
        return nil
    }

    func update(rows nextRows: [AIMessageViewportRow], render: @escaping AIMessageRowRenderer, background: UIColor,
                bottomInset: CGFloat, request: AIMessageListRequest, appearance nextAppearance: AIMessageListAppearance) {
        loadViewIfNeeded()
        let buffer = presentation?.streamDisplay
        buffer?.receive(nextRows, enabled: streamVisible && !nextAppearance.reduceMotion && !UIAccessibility.isReduceMotionEnabled, now: CACurrentMediaTime())
        replayDisplay = { [weak self] in
            guard let self else { return }
            self.applyDisplay(rows: buffer?.project(nextRows) ?? nextRows, render: render, background: background,
                              bottomInset: bottomInset, request: request, appearance: nextAppearance)
        }
        replayDisplay?()
        if buffer?.pending == true { startStreamClock() }
    }
    private func applyDisplay(rows nextRows: [AIMessageViewportRow], render: @escaping AIMessageRowRenderer, background: UIColor,
                              bottomInset: CGFloat, request: AIMessageListRequest, appearance nextAppearance: AIMessageListAppearance) {
        if applying {
            pendingUpdate = { [weak self] in
                self?.applyDisplay(rows: nextRows, render: render, background: background, bottomInset: bottomInset, request: request, appearance: nextAppearance)
            }
            return
        }
        // Insets and the overlay change in one update, even while a snapshot is finishing.
        adjusting = true
        let insets = UIEdgeInsets(top: LayoutTokens.content, left: 0, bottom: bottomInset + LayoutTokens.content, right: 0)
        if tableView.contentInset != insets {
            let previousGap = bottomGap
            UIView.performWithoutAnimation {
                tableView.contentInset = insets; tableView.verticalScrollIndicatorInsets = insets
                tableView.layoutIfNeeded()
                // Composer/queue geometry remains atomic; only streaming growth is smoothed.
                if following {
                    let gap = smoothFollowing && streamVisible && !reducedMotion ? previousGap : 0
                    move(to: bottomOffset - gap)
                }
            }
        }
        adjusting = false
        let old = rows
        if streamVisible && !nextAppearance.reduceMotion && nextRows.contains(where: { $0.nativeText?.streaming == true }) {
            smoothFollowing = true
        }
        if nextAppearance.reduceMotion { smoothFollowing = false; scrollVelocity = 0 }
        let force = appearance != nextAppearance
        if force { streamLineHeight = nextAppearance.markdownTheme(traits: traitCollection).fonts.body.lineHeight }
        if appearance?.theme != nextAppearance.theme || appearance?.typeSize != nextAppearance.typeSize {
            pendingResizes = .init()
            presentation?.messageHeights.removeAll()
        }
        appearance = nextAppearance; self.render = render
        rows = Dictionary(uniqueKeysWithValues: nextRows.map { ($0.id, $0) })
        tableView.backgroundColor = background
        if appliedRequest != request.id {
            appliedRequest = request.id
            expansionAnchor = nil
            switch request.target {
            case .bottom: following = true; searchTarget = nil; smoothFollowing = false; scrollVelocity = 0
            case .preserve: following = false; scrollVelocity = 0; searchTarget = nil
            case .row(let id): following = false; searchTarget = id
            }
        }
        let ids = nextRows.map(\.id)
        let previous = source.snapshot().itemIdentifiers
        let existing = Set(previous)
        let processChange = previous != ids && searchTarget == nil
            ? processExpansionChange(nextRows, old: old, previous: previous) : nil
        if let processChange, processChange.automatic,
           let reply = nextRows.last(where: { $0.turnID == processChange.turn && $0.nativeText != nil }),
           let replyAnchor = captureAnchor(where: { $0 == reply.id }) {
            pinExpansion(to: replyAnchor)
        }
        let anchor = expansionAnchor
            ?? stableAnchor.flatMap { rows[$0.id] == nil ? nil : $0 }
            ?? captureAnchor(where: { rows[$0] != nil })
        var completionAnchor: Anchor?
        if following && smoothFollowing && streamVisible && !reducedMotion && previous != ids {
            // The process control can first appear above visible prose.
            let completedTurns = Set(nextRows.compactMap { row -> String? in
                guard !existing.contains(row.id), case .processToggle = row.kind else { return nil }
                return row.turnID
            })
            if !completedTurns.isEmpty {
                completionAnchor = captureAnchor { id in
                    guard old[id]?.nativeText != nil, let row = rows[id], row.nativeText != nil,
                          let turnID = row.turnID else { return false }
                    return completedTurns.contains(turnID)
                }
            }
        }
        let changed = ids.filter { id in
            guard existing.contains(id) else { return false }
            // Authority can advance while the displayed prefix has not. Do not
            // reconfigure the same Markdown twice at that publication boundary.
            if let text = rows[id]?.nativeText { return force || old[id]?.nativeText != text }
            return force || old[id] != rows[id]
        }
        if expansionAnimationPending, previous == ids, let anchor = expansionAnchor, changed == [anchor.id], let row = rows[anchor.id],
           let path = source.indexPath(for: anchor.id), let cell = tableView.cellForRow(at: path) {
            expansionAnimationPending = false
            applying = true; animatingExpansion = true
            let viewport = tableView.superview!
            let oldFrames = Dictionary(uniqueKeysWithValues: (tableView.indexPathsForVisibleRows ?? []).compactMap { path -> (String, CGRect)? in
                guard let id = source.itemIdentifier(for: path), let cell = tableView.cellForRow(at: path) else { return nil }
                return (id, cell.convert(cell.bounds, to: viewport))
            })
            let content = hostedContent(anchor.id)
            let height = measureHosted(content)
            storeMeasuredHeight(height, for: heightKey(row))
            let oldHeight = tableView.rectForRow(at: path).height
            expansionHeights = [anchor.id: oldHeight]
            CATransaction.begin()
            UIView.performWithoutAnimation {
                (cell as? AIHostedMessageCell)?.configure(content, row: row, height: height, parent: self)
                tableView.performBatchUpdates { expansionHeights[anchor.id] = height }
                expansionHeights = [:]
                tableView.layoutIfNeeded()
                move(to: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - anchor.offset)
                tableView.layoutIfNeeded()
            }
            let actual = Anchor(id: anchor.id, offset: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - tableView.contentOffset.y)
            let clamped = abs(actual.offset - anchor.offset) > 0.5
            let duration = nextAppearance.reduceMotion || UIAccessibility.isReduceMotionEnabled || clamped ? 0.0 : 0.25
            // UIKit resolves final row geometry once. One explicit layer transaction animates
            // from the previous visible frames, avoiding UIKit's spring/estimate corrections.
            if duration > 0 {
                func animate(_ layer: CALayer, key: String, from: Any, to: Any) {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = from; animation.toValue = to
                    animation.duration = duration
                    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    layer.add(animation, forKey: "process-" + key)
                }
                for visible in tableView.indexPathsForVisibleRows ?? [] {
                    guard let id = source.itemIdentifier(for: visible), let cell = tableView.cellForRow(at: visible) else { continue }
                    let old = oldFrames[id].map { tableView.convert($0, from: viewport) }
                        ?? cell.frame.offsetBy(dx: 0, dy: visible.row > path.row ? oldHeight - height : 0)
                    var bounds = cell.bounds; bounds.size = old.size
                    animate(cell.layer, key: "bounds", from: bounds, to: cell.bounds)
                    animate(cell.layer, key: "position", from: CGPoint(x: old.midX, y: old.midY), to: cell.layer.position)
                    var contentBounds = cell.contentView.bounds; contentBounds.size.height = old.height
                    animate(cell.contentView.layer, key: "bounds", from: contentBounds, to: cell.contentView.bounds)
                    animate(cell.contentView.layer, key: "position", from: CGPoint(x: cell.contentView.layer.position.x, y: old.height / 2), to: cell.contentView.layer.position)
                }
            }
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.animatingExpansion = false; self.applying = false
                    self.tableView.selfSizingInvalidation = .enabledIncludingConstraints
                    if self.expansionAnchor?.id == anchor.id { self.expansionAnchor = actual; self.stableAnchor = actual }
                    else { self.stableAnchor = self.expansionAnchor ?? self.captureAnchor() }
                    self.replayPendingResizes(); self.publishBottom()
                    let next = self.pendingUpdate; self.pendingUpdate = nil; next?()
                }
            }
            CATransaction.commit()
            return
        }
        expansionAnimationPending = false
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        guard previous != ids || !changed.isEmpty else {
            replayPendingResizes()
            settle(anchor: anchor)
            return
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0]); snapshot.appendItems(ids); snapshot.reconfigureItems(changed)
        applying = true
        let finish = { [weak self] in
            guard let self else { return }
            tableView.layoutIfNeeded()
            animatingProcessRows = false
            applying = false
            replayPendingResizes()
            settle(anchor: expansionAnchor ?? anchor, followingInsertion: completionAnchor)
            completionAnchor = nil
            let next = pendingUpdate; pendingUpdate = nil; next?()
        }
        if processChange != nil && streamVisible && !reducedMotion {
            animatingProcessRows = true
            source.apply(snapshot, animatingDifferences: true, completion: finish)
            tableView.layoutIfNeeded()
            if animatingProcessRows { alignAnimatingProcess() }
        } else {
            // The completion can run on the next turn of the run loop. Finish
            // visible sizing and following before this update reaches the screen.
            UIView.performWithoutAnimation {
                source.apply(snapshot, animatingDifferences: false, completion: finish)
                tableView.layoutIfNeeded()
                if searchTarget == nil {
                    settle(anchor: expansionAnchor ?? anchor, followingInsertion: completionAnchor)
                    completionAnchor = nil
                }
            }
        }
    }

    private func processExpansionChange(_ nextRows: [AIMessageViewportRow], old: [String: AIMessageViewportRow],
                                        previous: [String]) -> (turn: String, automatic: Bool)? {
        for row in nextRows {
            guard case .processToggle(let expanded, let completed) = row.kind, let turn = row.turnID else { continue }
            if case .processToggle(let wasExpanded, let wasCompleted)? = old[row.id]?.kind {
                if expanded != wasExpanded { return (turn, completed && !wasCompleted && !expanded) }
            } else if completed && !expanded && previous.contains(where: { rows[$0] == nil && old[$0]?.turnID == turn }) {
                // The control may first appear when a turn leaves a waiting state.
                return (turn, true)
            }
        }
        return nil
    }

    func toggleProcessItem(rowID: String, item: AIProcessExpansionID) {
        guard let path = source.indexPath(for: rowID), let toggleProcess else { return }
        let anchor = Anchor(id: rowID, offset: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - tableView.contentOffset.y)
        pinExpansion(to: anchor)
        switch item {
        case .turn: break
        case .group, .reasoning:
            expansionAnimationPending = true
            tableView.selfSizingInvalidation = .disabled
        }
        toggleProcess(item)
    }

    private func pinExpansion(to anchor: Anchor) {
        following = false; scrollVelocity = 0; searchTarget = nil
        expansionAnchor = anchor; stableAnchor = anchor; layoutAnchor = anchor
    }
    private func alignAnimatingProcess() {
        guard let expansionAnchor else { return }
        adjusting = true
        move(to: expansionAnchor)
        adjusting = false
    }

    private var minimumOffset: CGFloat { -tableView.adjustedContentInset.top }
    private var bottomOffset: CGFloat { max(minimumOffset, tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height) }
    var bottomGap: CGFloat { max(0, bottomOffset - tableView.contentOffset.y) }
    private func move(to offset: CGFloat) {
        let y = min(bottomOffset, max(minimumOffset, offset))
        guard abs(tableView.contentOffset.y - y) > 0.25 else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
    private func move(to anchor: Anchor) {
        guard let path = source.indexPath(for: anchor.id) else { return }
        move(to: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - anchor.offset)
    }
    private func captureAnchor(where includes: (String) -> Bool = { _ in true }) -> Anchor? {
        let top = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let bottom = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        for path in (tableView.indexPathsForVisibleRows ?? []).sorted() {
            guard let id = source?.itemIdentifier(for: path), includes(id) else { continue }
            let frame = tableView.rectForRow(at: path)
            if frame.maxY > top && frame.minY < bottom { return .init(id: id, offset: frame.minY - top) }
        }
        return nil
    }
    private func settle(anchor: Anchor?, followingInsertion: Anchor? = nil) {
        guard !adjusting, !animatingExpansion, !animatingProcessRows, source != nil else { return }
        adjusting = true
        UIView.performWithoutAnimation {
            if let id = searchTarget, let path = source.indexPath(for: id) {
                tableView.scrollToRow(at: path, at: .middle, animated: false)
                tableView.layoutIfNeeded(); searchTarget = nil
            } else if following {
                // Restore the same visible prose once after an insertion above it.
                // Trailing growth and the final bottom gap still use the stream clock.
                if let followingInsertion { move(to: followingInsertion) }
                followBottom()
            } else if let anchor { move(to: anchor) }
        }
        if let anchor = expansionAnchor, let path = source.indexPath(for: anchor.id) {
            // A bottom clamp may legitimately lower this row after collapse. Keep that
            // new position rather than moving it back when later content arrives.
            let actual = Anchor(id: anchor.id, offset: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - tableView.contentOffset.y)
            expansionAnchor = actual; stableAnchor = actual
        } else { stableAnchor = captureAnchor() }
        adjusting = false
        publishBottom()
    }
    private func publishBottom() {
        let value = following || bottomGap <= 24
        guard value != reportedBottom else { return }; reportedBottom = value
        Task { @MainActor [weak self] in guard let self, reportedBottom == value else { return }; reportBottom?(value) }
    }
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        expansionAnchor = nil
        following = false; scrollVelocity = 0; searchTarget = nil; stableAnchor = captureAnchor()
    }
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !adjusting, !applying, !anchoredTable.performingLayout else { return }
        if scrollView.isDragging || scrollView.isDecelerating { stableAnchor = captureAnchor() }
        publishBottom()
    }
    override func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishUserScroll() }
    }
    override func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishUserScroll() }
    private func finishUserScroll() {
        following = bottomGap <= 24; stableAnchor = captureAnchor()
        if following { settle(anchor: nil) }; publishBottom()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let environment = "\(tableView.bounds.width.rounded())/\(String(describing: appearance?.typeSize))"
        if sizingEnvironment != environment {
            pendingResizes = .init()
            presentation?.messageHeights.removeAll()
            sizingEnvironment = environment
        }
        settle(anchor: stableAnchor)
    }
    private func heightKey(_ row: AIMessageViewportRow) -> AIMessageHeightKey {
        .init(id: row.id, version: row.version, width: tableView.bounds.width.rounded(), typeSize: String(describing: appearance?.typeSize))
    }
    private func storeMeasuredHeight(_ height: CGFloat, for key: AIMessageHeightKey) {
        guard let presentation else { return }
        for old in presentation.messageHeights.keys where old.id == key.id && old != key {
            presentation.messageHeights.removeValue(forKey: old)
        }
        presentation.messageHeights[key] = height
    }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if let id = source.itemIdentifier(for: indexPath), let height = expansionHeights[id] { return height }
        if let id = source.itemIdentifier(for: indexPath), let row = rows[id], row.nativeText == nil { return hostedHeight(row) }
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id], let text = row.nativeText,
              let appearance, let presentation else { return UITableView.automaticDimension }
        let key = heightKey(row)
        if let cached = presentation.messageHeights[key] { return cached }
        let height = presentation.nativeMarkdown.height(id: id, text: text.text, streaming: text.streaming,
                                                       theme: appearance.markdownTheme(traits: traitCollection),
                                                       width: tableView.bounds.width - 2 * LayoutTokens.content) + 2 * LayoutTokens.compact
        storeMeasuredHeight(height, for: key)
        return height
    }
    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if let id = source.itemIdentifier(for: indexPath), let height = expansionHeights[id] { return height }
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id] else { return 80 }
        if let cached = presentation?.messageHeights[heightKey(row)] { return cached }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let characters = max(8, (tableView.bounds.width - 2 * LayoutTokens.content) / font.pointSize)
        switch row.kind {
        case .block(let message): return message.map { max(44, ceil(CGFloat($0.count) / characters) * font.lineHeight + 16) } ?? 48
        case .input(let text): return max(52, ceil(CGFloat(text.count) / characters) * font.lineHeight + 32)
        case .image(let width, let height): return min(320, max(80, (tableView.bounds.width - 32) * height / max(1, width))) + 16
        case .confirmation, .result: return 160
        case .header: return 100
        case .processToggle:
            let font = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection)
            return ceil(font.lineHeight + 2 * LayoutTokens.compact)
        default: return 48
        }
    }
}
