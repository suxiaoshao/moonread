import MoonreadDesign
import MoonreadAI
import MarkdownView
import SwiftUI
import UIKit

final class AINativeMarkdownCell: UITableViewCell {
    private var markdown: MarkdownTextView?
    func mount(_ view: MarkdownTextView) {
        guard markdown !== view || view.superview !== contentView else { return }
        unmount()
        view.removeFromSuperview()
        contentView.addSubview(view)
        markdown = view
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let markdown, markdown.superview === contentView {
            markdown.frame = contentView.bounds.insetBy(dx: LayoutTokens.content, dy: LayoutTokens.compact)
        }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        unmount()
    }
    private func unmount() {
        // A retained block may already belong to a newer cell when this one is reused.
        if markdown?.superview === contentView { markdown?.removeFromSuperview() }
        markdown = nil
    }
}

extension AIMessageRow {
    var nativeText: (text: String, streaming: Bool)? {
        guard case .block(let block, let status, _) = content, block.isMessage,
              let item = block.items.first, item.kind == .text else { return nil }
        return (item.text, [.running, .compacting, .waitingConfirmation].contains(status))
    }
}

extension AIMessageListAppearance {
    func markdownTheme(traits: UITraitCollection) -> MarkdownTheme {
        let category: UIContentSizeCategory = switch typeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
        let traits = UITraitCollection(traitsFrom: [traits, .init(preferredContentSizeCategory: category)])
        let body = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        var value = MarkdownTheme()
        value.fonts.body = body
        value.fonts.bold = UIFont(descriptor: body.fontDescriptor.withSymbolicTraits(.traitBold) ?? body.fontDescriptor, size: body.pointSize)
        value.fonts.italic = UIFont(descriptor: body.fontDescriptor.withSymbolicTraits(.traitItalic) ?? body.fontDescriptor, size: body.pointSize)
        value.fonts.largeTitle = UIFont.preferredFont(forTextStyle: .title1, compatibleWith: traits)
        value.fonts.title = UIFont.preferredFont(forTextStyle: .title2, compatibleWith: traits)
        value.fonts.footnote = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        value.fonts.codeInline = .monospacedSystemFont(ofSize: body.pointSize, weight: .regular)
        value.fonts.code = .monospacedSystemFont(ofSize: body.pointSize * 0.85, weight: .regular)
        value.colors.body = theme.ink; value.colors.code = theme.ink
        value.colors.highlight = theme.accent; value.colors.emphasis = theme.accent
        value.colors.codeBackground = theme.raised; value.colors.codeBlockBackground = theme.raised
        value.colors.codeBlockBarBackground = theme.raised
        value.colors.selectionBackground = theme.accent.withAlphaComponent(0.2)
        value.table.borderColor = theme.border; value.table.headerBackgroundColor = theme.raised
        value.table.cellBackgroundColor = .clear
        value.spacings.final = 0
        return value
    }
}


/// A separate render for the menu, sized to the current window above the system actions.
final class AIReplyPreviewController: UIViewController {
    private let markdown: MarkdownTextView
    private let background: UIColor
    private let viewport = UIView()
    private let fade = CAGradientLayer()

    init(text: String, theme: MarkdownTheme, background: UIColor, availableSize: CGSize) {
        self.markdown = AINativeMarkdownCache.preview(text: text, theme: theme)
        self.background = background
        super.init(nibName: nil, bundle: nil)
        let width = max(1, availableSize.width - 2 * LayoutTokens.content)
        let height = measuredHeight(width: width - 2 * LayoutTokens.content)
        preferredContentSize = .init(width: width, height: min(height + 2 * LayoutTokens.compact, availableSize.height * 0.55))
        fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = background
        viewport.clipsToBounds = true
        view.addSubview(viewport)
        viewport.addSubview(markdown)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        viewport.frame = view.bounds.insetBy(dx: LayoutTokens.content, dy: LayoutTokens.compact)
        let height = measuredHeight(width: viewport.bounds.width)
        markdown.frame = CGRect(origin: .zero, size: .init(width: viewport.bounds.width, height: height))
        if height > viewport.bounds.height {
            fade.frame = viewport.bounds
            fade.locations = [0, NSNumber(value: Double(max(0, 1 - 32 / max(1, viewport.bounds.height)))), 1]
            viewport.layer.mask = fade
        } else {
            viewport.layer.mask = nil
        }
    }

    private func measuredHeight(width: CGFloat) -> CGFloat {
        ceil(markdown.boundingSize(for: max(1, width)).height)
    }
}
