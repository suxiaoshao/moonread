import MarkdownView
import MarkdownParser
import Litext
import CoreText
import SwiftUI
import UIKit

/// One cache belongs to one conversation. Measuring never reparents a displayed view.
@MainActor final class AINativeMarkdownCache {
    private struct Revision: Equatable {
        let text: String
        let hash: Int
        let streaming: Bool
        let theme: MarkdownTheme
    }
    private struct Parsed {
        let revision: Revision
        let content: MarkdownContent
    }
    private struct Mounted {
        let view: MarkdownTextView
        var revision: Revision
        var accessed: Int
    }
    private var parsed: [String: Parsed] = [:]
    private var retained: [String: Mounted] = [:]
    private var measuring: [String: Mounted] = [:]
    private var access = 0
    private let sizingLimit = 24

    func reset() {
        parsed.removeAll(); retained.removeAll(); measuring.removeAll()
    }
    private func content(id: String, text: String, streaming: Bool, theme: MarkdownTheme) -> Parsed {
        let revision = Revision(text: text, hash: text.hashValue, streaming: streaming, theme: theme)
        if let hit = parsed[id], hit.revision == revision { return hit }
        let value = Parsed(revision: revision, content: MarkdownContent(markdown: text, theme: theme, isStreaming: streaming))
        parsed[id] = value
        return value
    }
    private func configured(_ previous: Mounted?, package: Parsed) -> Mounted {
        access += 1
        if var previous, previous.revision == package.revision {
            previous.accessed = access
            return previous
        }
        let view = previous?.view ?? AINativeMarkdownView()
        view.theme = package.revision.theme
        view.setContentImmediately(package.content)
        view.backgroundColor = .clear
        let accessibility = AINativeMarkdownAccessibility(blocks: package.content.blocks)
        view.isAccessibilityElement = true
        view.accessibilityTraits = .staticText
        view.accessibilityLabel = accessibility.label
        view.accessibilityCustomActions = accessibility.links.map { link in
            UIAccessibilityCustomAction(name: link.name) { _ in
                guard let url = URL(string: link.destination) else { return false }
                UIApplication.shared.open(url)
                return true
            }
        }
        view.linkHandler = { link, _, _ in
            let url: URL?
            switch link {
            case .url(let value): url = value
            case .string(let value): url = URL(string: value)
            }
            if let url { UIApplication.shared.open(url) }
        }
        return .init(view: view, revision: package.revision, accessed: access)
    }
    func view(id: String, text: String, streaming: Bool, theme: MarkdownTheme) -> MarkdownTextView {
        let package = content(id: id, text: text, streaming: streaming, theme: theme)
        let value = configured(retained[id], package: package)
        retained[id] = value
        return value.view
    }
    func height(id: String, text: String, streaming: Bool, theme: MarkdownTheme, width: CGFloat) -> CGFloat {
        let package = content(id: id, text: text, streaming: streaming, theme: theme)
        let value = configured(measuring[id], package: package)
        measuring[id] = value
        if measuring.count > sizingLimit, let oldest = measuring.min(by: { $0.value.accessed < $1.value.accessed })?.key {
            measuring.removeValue(forKey: oldest)
        }
        return ceil(value.view.boundingSize(for: max(1, width)).height)
    }
    var sizingCount: Int { measuring.count }
    var retainedCount: Int { retained.count }
}

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

/// Speech follows the same parsed nodes as rendering, including the streaming tail.
struct AINativeMarkdownAccessibility {
    struct Link { let name: String; let destination: String }
    var label = ""
    var links: [Link] = []

    init(blocks: [MarkdownBlockNode]) {
        label = blockText(blocks)
    }
    private mutating func inlineText(_ nodes: [MarkdownInlineNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let text), .code(let text), .html(let text): return text
            case .softBreak, .lineBreak: return "\n"
            case .math(let text, _): return text
            case .link(let destination, let children):
                let name = inlineText(children)
                links.append(.init(name: name.isEmpty ? destination : name, destination: destination))
                return name
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .image(_, let children):
                return inlineText(children)
            }
        }.joined()
    }
    private mutating func blockText(_ blocks: [MarkdownBlockNode]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let content), .heading(_, let content): return inlineText(content)
            case .blockquote(let children): return blockText(children)
            case .bulletedList(_, let items): return items.map { blockText($0.children) }.joined(separator: "\n")
            case .numberedList(_, let start, let items):
                return items.enumerated().map { "\(start + $0.offset). " + blockText($0.element.children) }.joined(separator: "\n")
            case .taskList(_, let items):
                return items.map { ($0.isCompleted ? "☑ " : "☐ ") + blockText($0.children) }.joined(separator: "\n")
            case .codeBlock(_, let content): return content
            case .table(_, let rows):
                return rows.map { $0.cells.map { inlineText($0.content) }.joined(separator: "，") }.joined(separator: "\n")
            case .thematicBreak: return ""
            }
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// Styling through the library's public document hook; no private subview access.
final class AINativeMarkdownView: MarkdownTextView {
    override func applyDocument(_ document: NSAttributedString, newContextViews: [UIView], animated: Bool) {
        var styled: NSMutableAttributedString?
        func output() -> NSMutableAttributedString {
            if let styled { return styled }
            let copy = NSMutableAttributedString(attributedString: document)
            styled = copy
            return copy
        }
        let range = NSRange(location: 0, length: document.length)
        // MarkdownView 4.8.3 represents emphasis as an underline, including CJK.
        document.enumerateAttribute(.underlineStyle, in: range) { value, span, _ in
            guard value != nil else { return }
            output().removeAttribute(.underlineStyle, range: span)
            output().removeAttribute(.underlineColor, range: span)
        }
        var levels: [Int] = []
        func headings(_ nodes: [MarkdownBlockNode]) {
            for node in nodes {
                if case .heading(let level, _) = node { levels.append(level) }
                headings(node.children)
            }
        }
        headings(content.blocks)
        if !levels.isEmpty {
            let text = document.string as NSString
            var location = 0, heading = 0
            while location < text.length {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                defer { location = NSMaxRange(paragraph) }
                guard heading < levels.count,
                      let style = document.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle,
                      style.paragraphSpacingBefore == theme.spacings.headingBefore,
                      style.paragraphSpacingBefore > 0 else { continue }
                // The pinned renderer marks headings with headingBefore; preserve inline code.
                let base: CGFloat = switch levels[heading] { case 1: 28; case 2: 24; case 3: 20; default: 17 }
                let font = UIFont.systemFont(ofSize: base * theme.fonts.body.pointSize / 17)
                document.enumerateAttribute(.font, in: paragraph) { value, span, _ in
                    guard (value as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) != true else { return }
                    output().addAttribute(.font, value: font, range: span)
                }
                heading += 1
            }
        }
        document.enumerateAttributes(in: range) { attributes, span, _ in
            guard attributes[.litextLineDrawingAction] != nil,
                  let attachment = attributes[.litextAttachment] as? TextLabel.Attachment else { return }
            let marker = attachment.attributedStringRepresentation().string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard marker.hasSuffix("."), Int(marker.dropLast()) != nil else { return }
            let drawing = AINativeNumberMarker(text: marker, font: theme.fonts.body, color: theme.colors.body)
            output().addAttribute(.litextLineDrawingAction, value: drawing, range: span)
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, drawing.width + 8 > 24 {
                let paragraph = (document.string as NSString).paragraphRange(for: span)
                let adjusted = style.mutableCopy() as! NSMutableParagraphStyle
                let extra = ceil(drawing.width + 8) - 24
                adjusted.headIndent += extra; adjusted.firstLineHeadIndent += extra
                output().addAttribute(.paragraphStyle, value: adjusted, range: paragraph)
            }
        }
        super.applyDocument(styled ?? document, newContextViews: newContextViews, animated: animated)
    }
}

final class AINativeNumberMarker: TextLabel.LineDrawingAction {
    let text: String
    let width: CGFloat
    init(text: String, font: UIFont, color: UIColor) {
        self.text = text
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        self.width = width
        super.init { context, _, origin in
            context.textPosition = CGPoint(x: origin.x - 8 - width, y: origin.y)
            CTLineDraw(line, context)
        }
    }
}
