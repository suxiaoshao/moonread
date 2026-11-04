import SwiftUI
import UIKit
import MarkdownView

typealias AIMessageRowRenderer = @MainActor (String, @escaping AIProcessExpansionHandler) -> AnyView

struct AIMessageListRequest: Equatable {
    enum Target: Equatable { case bottom, preserve, row(String) }
    let id = UUID()
    var target: Target = .bottom
}

/// UIKit owns recycling, sizing and scroll timing. SwiftUI owns only each cell's contents.
struct AIMessageList: UIViewControllerRepresentable {
    let rows: [AIMessageRow]
    let conversation: AIConversation
    let background: UIColor
    let bottomInset: CGFloat
    let request: AIMessageListRequest
    let highlightedTurn: String?
    @Binding var atBottom: Bool
    let dismissKeyboard: () -> Void
    let content: AIMessageRowRenderer
    @Environment(AIService.self) private var ai
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.moonreadReduceMotion) private var reduceMotion

    func makeUIViewController(context: Context) -> AIMessageListController { AIMessageListController() }
    func updateUIViewController(_ controller: AIMessageListController, context: Context) {
        controller.conversation = conversation
        controller.replyFeedback = { row in AIReplyFeedback(row: row, conversation: conversation, connections: ai.providers.connections) }
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
    func configure(_ content: AnyView, height: CGFloat, parent: UIViewController) {
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
    func resize(_ height: CGFloat) { self.height = height; setNeedsLayout() }
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
    weak var conversation: AIConversation?
    var replyFeedback: ((AIMessageRow) -> AIReplyFeedback?)?
    private let feedbackPresenter = AIReplyFeedbackPresenter()
    var reportBottom: ((Bool) -> Void)?
    var dismissKeyboard: (() -> Void)?
    private(set) var following = true
    private var rows: [String: AIMessageRow] = [:]
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
        streamVisible = false; conversation?.streamDisplay.flush(); replayDisplay?()
        stopStreamClock(); conversation?.streamDisplay.reset()
    }
    @objc private func streamBackgrounded() { finishStreamPresentation() }
    @objc private func streamForegrounded() { streamVisible = viewIfLoaded?.window != nil }
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
        if conversation?.streamDisplay.advance(now: now) == true { replayDisplay?() }
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
        if conversation?.streamDisplay.pending != true && (!following || !smoothFollowing || bottomGap <= 0.25) {
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
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id],
              let feedback = replyFeedback?(row), let theme = appearance?.theme else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "复制回复"), image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = feedback.text },
                UIAction(title: String(localized: "反馈这条回复"), image: UIImage(systemName: "envelope")) { [weak self] _ in
                    guard let self else { return }
                    self.feedbackPresenter.present(feedback, from: self, theme: theme)
                }
            ])
        }
    }

    override func loadView() { tableView = AIAnchoredTableView(frame: .zero, style: .plain) }
    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(self, selector: #selector(streamBackgrounded), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(streamForegrounded), name: UIApplication.didBecomeActiveNotification, object: nil)
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 80
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        tableView.keyboardDismissMode = .interactive
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.accessibilityIdentifier = "aiMessages"
        tableView.alwaysBounceVertical = true
        tableView.register(AIHostedMessageCell.self, forCellReuseIdentifier: "message")
        tableView.register(AINativeMarkdownCell.self, forCellReuseIdentifier: "markdown")
        source = UITableViewDiffableDataSource(tableView: tableView) { [weak self] table, path, id in
            if let self, let row = rows[id], let text = row.nativeText, let appearance, let conversation {
                let cell = table.dequeueReusableCell(withIdentifier: "markdown", for: path) as! AINativeMarkdownCell
                let view = conversation.nativeMarkdown.view(id: id, text: text.text, streaming: text.streaming,
                                                            theme: appearance.markdownTheme(traits: traitCollection))
                view.trackedScrollView = table
                cell.mount(view)
                cell.selectionStyle = .none
                cell.backgroundColor = row.turnID == appearance.highlightedTurn ? appearance.theme.accent.withAlphaComponent(0.12) : .clear
                return cell
            }
            let cell = table.dequeueReusableCell(withIdentifier: "message", for: path) as! AIHostedMessageCell
            if let self, let row = rows[id] { cell.configure(hostedContent(id), height: hostedHeight(row), parent: self) }
            cell.selectionStyle = .none; cell.backgroundColor = .clear
            return cell
        }
        anchoredTable.beforeLayout = { [weak self] in
            guard let self, !adjusting, !animatingExpansion else { return }
            if following {
                adjusting = true; followBottom(); adjusting = false
            } else if !applying { layoutAnchor = expansionAnchor ?? stableAnchor ?? captureAnchor() }
        }
        anchoredTable.afterLayout = { [weak self] in
            guard let self, !adjusting, !animatingExpansion else { return }
            if applying {
                if following { adjusting = true; followBottom(); adjusting = false }
                else if let expansionAnchor { settle(anchor: expansionAnchor) }
            } else { settle(anchor: layoutAnchor) }
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedBackground))
        tap.cancelsTouchesInView = false; tap.delegate = self
        tableView.addGestureRecognizer(tap)
    }
    private func hostedContent(_ id: String) -> AnyView {
        AnyView(render?(id, { [weak self] item in
            self?.toggleProcessItem(rowID: id, item: item)
        }).id(id)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, LayoutTokens.content).padding(.vertical, LayoutTokens.compact)
            // Result cards change height from their own state (reviews, save feedback), not a row version.
            // Only result rows act on it; every other row is re-measured by its version.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
                DispatchQueue.main.async { self?.hostedContentResized(id, height: height) }
            }
            .environment(\.moonreadReduceMotion, (appearance?.reduceMotion ?? false) || UIAccessibility.isReduceMotionEnabled))
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
    private func hostedHeight(_ row: AIMessageRow) -> CGFloat {
        let key = heightKey(row)
        if let cached = conversation?.messageHeights[key] { return cached }
        let height = measureHosted(hostedContent(row.id))
        if !animatingExpansion { conversation?.messageHeights[key] = height }
        return height
    }
    /// Re-measures a visible row whose content grew or shrank without a new row version.
    func hostedContentResized(_ id: String, height: CGFloat) {
        guard let row = rows[id], case .result = row.content else { return }
        // A process expansion owns its geometry. Keep the latest result-card
        // measurement until it finishes; SwiftUI may never send it again.
        guard !animatingExpansion, !expansionAnimationPending, !applying, expansionHeights.isEmpty else {
            pendingResizes.record(id: id, version: row.version, height: Double(height)); return
        }
        let key = heightKey(row), height = ceil(height)
        guard let cached = conversation?.messageHeights[key], abs(cached - height) > 0.5 else { return }
        conversation?.messageHeights[key] = height
        guard let path = source.indexPath(for: id), let cell = tableView.cellForRow(at: path) as? AIHostedMessageCell else { return }
        cell.resize(height)
        UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
    }
    private func replayPendingResizes() {
        let pending = pendingResizes.drain(versions: rows.mapValues(\.version))
        for (id, height) in pending { hostedContentResized(id, height: CGFloat(height)) }
    }
    @objc private func tappedBackground() { dismissKeyboard?() }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Interactive cell contents keep taps, links, text selection and their own menus.
        tableView.indexPathForRow(at: touch.location(in: tableView)) == nil
    }

    func update(rows nextRows: [AIMessageRow], render: @escaping AIMessageRowRenderer, background: UIColor,
                bottomInset: CGFloat, request: AIMessageListRequest, appearance nextAppearance: AIMessageListAppearance) {
        loadViewIfNeeded()
        let buffer = conversation?.streamDisplay
        buffer?.receive(nextRows, enabled: streamVisible && !nextAppearance.reduceMotion && !UIAccessibility.isReduceMotionEnabled, now: CACurrentMediaTime())
        replayDisplay = { [weak self] in
            guard let self else { return }
            self.applyDisplay(rows: buffer?.project(nextRows) ?? nextRows, render: render, background: background,
                              bottomInset: bottomInset, request: request, appearance: nextAppearance)
        }
        replayDisplay?()
        if buffer?.pending == true { startStreamClock() }
    }
    private func applyDisplay(rows nextRows: [AIMessageRow], render: @escaping AIMessageRowRenderer, background: UIColor,
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
        let anchor = expansionAnchor ?? stableAnchor ?? captureAnchor()
        let old = rows
        if streamVisible && !nextAppearance.reduceMotion && nextRows.contains(where: { $0.nativeText?.streaming == true }) {
            smoothFollowing = true
        }
        if nextAppearance.reduceMotion { smoothFollowing = false; scrollVelocity = 0 }
        let force = appearance != nextAppearance
        if force { streamLineHeight = nextAppearance.markdownTheme(traits: traitCollection).fonts.body.lineHeight }
        if appearance?.theme != nextAppearance.theme || appearance?.typeSize != nextAppearance.typeSize {
            conversation?.messageHeights.removeAll()
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
        let changed = ids.filter { id in
            guard existing.contains(id) else { return false }
            // Authority can advance while the displayed prefix has not. Do not
            // reconfigure the same Markdown twice at that publication boundary.
            if rows[id]?.nativeText != nil { return force || old[id]?.content != rows[id]?.content }
            return force || old[id] != rows[id]
        }
        if expansionAnimationPending, previous == ids, let anchor = expansionAnchor, changed == [anchor.id],
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
            let oldHeight = tableView.rectForRow(at: path).height
            expansionHeights = [anchor.id: oldHeight]
            CATransaction.begin()
            UIView.performWithoutAnimation {
                (cell as? AIHostedMessageCell)?.configure(content, height: height, parent: self)
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
                    self.recordVisibleHeights(); self.replayPendingResizes(); self.publishBottom()
                    let next = self.pendingUpdate; self.pendingUpdate = nil; next?()
                }
            }
            CATransaction.commit()
            return
        }
        expansionAnimationPending = false
        tableView.selfSizingInvalidation = .enabledIncludingConstraints
        guard previous != ids || !changed.isEmpty else { settle(anchor: anchor); return }
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0]); snapshot.appendItems(ids); snapshot.reconfigureItems(changed)
        applying = true
        UIView.performWithoutAnimation {
            source.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                tableView.layoutIfNeeded()
                applying = false
                replayPendingResizes()
                settle(anchor: expansionAnchor ?? anchor)
                let next = pendingUpdate; pendingUpdate = nil; next?()
            }
            // The completion can run on the next turn of the run loop. Finish
            // visible sizing and following before this update reaches the screen.
            tableView.layoutIfNeeded()
            if following { followBottom() }
            else if let expansionAnchor { settle(anchor: expansionAnchor) }
        }
    }

    func toggleProcessItem(rowID: String, item: AIProcessExpansionID) {
        guard let path = source.indexPath(for: rowID), let conversation else { return }
        following = false; scrollVelocity = 0; searchTarget = nil
        let anchor = Anchor(id: rowID, offset: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - tableView.contentOffset.y)
        expansionAnchor = anchor; stableAnchor = anchor; layoutAnchor = anchor
        expansionAnimationPending = true
        tableView.selfSizingInvalidation = .disabled
        conversation.toggleProcessItem(item)
    }

    private var minimumOffset: CGFloat { -tableView.adjustedContentInset.top }
    private var bottomOffset: CGFloat { max(minimumOffset, tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height) }
    var bottomGap: CGFloat { max(0, bottomOffset - tableView.contentOffset.y) }
    private func move(to offset: CGFloat) {
        let y = min(bottomOffset, max(minimumOffset, offset))
        guard abs(tableView.contentOffset.y - y) > 0.25 else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }
    private func captureAnchor() -> Anchor? {
        let top = tableView.contentOffset.y + tableView.adjustedContentInset.top
        let bottom = tableView.contentOffset.y + tableView.bounds.height - tableView.adjustedContentInset.bottom
        let visible = (tableView.indexPathsForVisibleRows ?? []).sorted()
        let complete = visible.first { let r = tableView.rectForRow(at: $0); return r.minY >= top && r.maxY <= bottom }
        guard let path = complete ?? visible.first, let id = source?.itemIdentifier(for: path) else { return nil }
        return .init(id: id, offset: tableView.rectForRow(at: path).minY - top)
    }
    private func settle(anchor: Anchor?) {
        guard !adjusting, !animatingExpansion, source != nil else { return }
        adjusting = true
        UIView.performWithoutAnimation {
            if let id = searchTarget, let path = source.indexPath(for: id) {
                tableView.scrollToRow(at: path, at: .middle, animated: false)
                tableView.layoutIfNeeded(); searchTarget = nil
            } else if following { followBottom() }
            else if let anchor, let path = source.indexPath(for: anchor.id) {
                move(to: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - anchor.offset)
            }
        }
        if let anchor = expansionAnchor, let path = source.indexPath(for: anchor.id) {
            // A bottom clamp may legitimately lower this row after collapse. Keep that
            // new position rather than moving it back when later content arrives.
            let actual = Anchor(id: anchor.id, offset: tableView.rectForRow(at: path).minY - tableView.adjustedContentInset.top - tableView.contentOffset.y)
            expansionAnchor = actual; stableAnchor = actual
        } else { stableAnchor = captureAnchor() }
        recordVisibleHeights()
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
        if sizingEnvironment != environment { conversation?.messageHeights.removeAll(); sizingEnvironment = environment }
        settle(anchor: stableAnchor)
    }
    private func heightKey(_ row: AIMessageRow) -> AIMessageHeightKey {
        .init(id: row.id, version: row.version, width: tableView.bounds.width.rounded(), typeSize: String(describing: appearance?.typeSize))
    }
    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if let id = source.itemIdentifier(for: indexPath), let height = expansionHeights[id] { return height }
        if let id = source.itemIdentifier(for: indexPath), let row = rows[id], row.nativeText == nil { return hostedHeight(row) }
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id], let text = row.nativeText,
              let appearance, let conversation else { return UITableView.automaticDimension }
        let key = heightKey(row)
        if let cached = conversation.messageHeights[key] { return cached }
        let height = conversation.nativeMarkdown.height(id: id, text: text.text, streaming: text.streaming,
                                                       theme: appearance.markdownTheme(traits: traitCollection),
                                                       width: tableView.bounds.width - 2 * LayoutTokens.content) + 2 * LayoutTokens.compact
        for old in conversation.messageHeights.keys where old.id == id && old != key {
            conversation.messageHeights.removeValue(forKey: old)
        }
        conversation.messageHeights[key] = height
        return height
    }
    override func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        if let id = source.itemIdentifier(for: indexPath), let height = expansionHeights[id] { return height }
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id] else { return 80 }
        if let cached = conversation?.messageHeights[heightKey(row)] { return cached }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection)
        let characters = max(8, (tableView.bounds.width - 2 * LayoutTokens.content) / font.pointSize)
        switch row.content {
        case .block(let block, _, _): return block.isMessage ? max(44, ceil(CGFloat(block.items[0].text.count) / characters) * font.lineHeight + 16) : 48
        case .user(let entry): return max(52, ceil(CGFloat((entry.userText ?? "").count) / characters) * font.lineHeight + 32)
        case .queued(let input): return max(52, ceil(CGFloat(input.text.count) / characters) * font.lineHeight + 32)
        case .image(let image): return min(320, max(80, (tableView.bounds.width - 32) * CGFloat(image.height) / CGFloat(max(1, image.width)))) + 16
        case .confirmation, .result: return 160
        case .header: return 100
        default: return 48
        }
    }
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) { recordHeight(cell, at: indexPath) }
    private func recordHeight(_ cell: UITableViewCell, at indexPath: IndexPath) {
        guard !animatingExpansion else { return }
        guard let id = source.itemIdentifier(for: indexPath), let row = rows[id], cell.bounds.height > 0 else { return }
        guard row.nativeText == nil else { return }
        let key = heightKey(row)
        if conversation?.messageHeights[key] == cell.bounds.height { return }
        conversation?.messageHeights = conversation?.messageHeights.filter { $0.key.id != id || $0.key == key } ?? [:]
        conversation?.messageHeights[key] = cell.bounds.height
    }
    private func recordVisibleHeights() {
        for path in tableView.indexPathsForVisibleRows ?? [] {
            if let cell = tableView.cellForRow(at: path) { recordHeight(cell, at: path) }
        }
    }
}
