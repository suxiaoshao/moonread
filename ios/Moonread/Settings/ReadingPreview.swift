import SwiftUI
import UIKit

@MainActor
final class ReadingPreviewPosition {
    struct Saved {
        let anchor: UInt64
        let offset: CGPoint
        let width: CGFloat
    }
    weak var view: ReadingPreviewTextView?
    private(set) var saved: Saved?
    private var paperInput: ThemeSurface.PaperInput?
    private var tile: UIImage?
    func paperTile(_ input: ThemeSurface.PaperInput) -> UIImage? {
        if paperInput != input {
            paperInput = input
            tile = input.choice == nil ? nil : ThemeSurface.paperTile(input)
        }
        return tile
    }
    func capture() { if let view { saved = view.capturePosition() } }
}

struct ReadingPreviewSource: Equatable {
    struct Mark: Equatable {
        let start: UInt64
        let end: UInt64
        var search = false
    }
    let window: ReadingWindow
    let anchor: UInt64
    let title: String
    var marks: [Mark] = []

    static var sample: Self {
        let lines: [(String, ParagraphKind)] = [
            (String(localized: "第一章 月光入窗"), .heading),
            (String(localized: "晚风吹动窗帘，月光落在翻开的书页上。她把杯子放在窗边，沿着刚才读到的那一句，慢慢看了下去。"), .body),
            (String(localized: "街上的声音渐渐远了。故事里的人正走过一座小桥，桥下的流水映着星光，仿佛一伸手，就能触到夏夜的清凉。"), .body),
            (String(localized: "她翻过一页，想知道那个久别的人，最后有没有回到故乡。"), .body),
            (String(localized: "书里写着一条通往山间的小路。雨刚停，石阶还湿着，路边的草叶托着细小的水珠。有人提着灯走在前面，走几步便停下来，回头等一等身后的同伴。远处的屋檐下，一盏旧灯还亮着。"), .body),
            (String(localized: "读到这里，她抬头看了看窗外。对面的灯已经熄了，只有楼下那棵树仍在风里轻轻摇动。杯中的水还有一点温度，她握了片刻，又把目光移回书页，接着读那段尚未说完的对话。"), .body),
            (String(localized: "夜还很长，故事也没有结束。她把身体往椅背上靠了靠，换了个舒服的姿势。窗帘在身旁缓慢起落，纸页上的字一句接着一句，把那条陌生的小路，带到了离她很近的地方。"), .body)
        ]
        var offset: UInt64 = 0
        let paragraphs = lines.map { line, kind in
            let start = offset; offset += UInt64((line + "\n").utf8.count)
            return ReadingParagraph(startUtf8: start, endUtf8: offset, kind: kind, continuation: false, indented: false)
        }
        let text = lines.map { $0.0 + "\n" }.joined()
        let marks = [(String(localized: "月光落在翻开的书页上"), false), (String(localized: "桥下的流水映着星光"), true)].compactMap { phrase, search -> Mark? in
            guard let range = text.range(of: phrase) else { return nil }
            return Mark(start: UInt64(text[..<range.lowerBound].utf8.count), end: UInt64(text[..<range.upperBound].utf8.count), search: search)
        }
        return Self(window: ReadingWindow(chunks: [TextChunk(index: 0, startUtf8: 0, endUtf8: offset, text: text)], paragraphs: paragraphs, isEndOfBook: true),
                    anchor: 0, title: String(localized: "月光入窗"), marks: marks)
    }
}

/// A preview uses the same fonts, paragraph semantics and TextKit drawing as
/// the reader, without a ReaderSession, progress writes or device side effects.
struct ReadingPreviewPane: View {
    let source: ReadingPreviewSource
    let settings: ReaderSettings
    let surface: ThemeSurface
    var position: ReadingPreviewPosition?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: source.title).font(.caption).lineLimit(1)
                Spacer()
            }
            .foregroundStyle(Color(uiColor: surface.secondary))
            .padding(.horizontal, LayoutTokens.content)
            ReadingPreviewText(source: source, settings: settings, surface: surface, position: position)
                .accessibilityIdentifier("readingPreviewText")
        }
    }
}

struct ReadingPreviewText: UIViewRepresentable {
    let source: ReadingPreviewSource
    let settings: ReaderSettings
    let surface: ThemeSurface
    var position: ReadingPreviewPosition?
    @Environment(\.dynamicTypeSize) private var typeSize
    func makeUIView(context: Context) -> ReadingPreviewTextView { ReadingPreviewTextView() }
    func updateUIView(_ view: ReadingPreviewTextView, context: Context) {
        position?.view = view
        view.configure(source: source, settings: settings, surface: surface, typeSize: typeSize, restored: position?.saved)
    }
}

@MainActor
final class ReadingPreviewTextView: UITextView {
    private let paint = ReadingInk()
    private var source: ReadingPreviewSource?
    private var settings: ReaderSettings?
    private var surface = ThemeSurface.initial
    private var typeSize: DynamicTypeSize?
    private var readingText = ReadingText(text: "")
    private var coordinates: TextCoordinates { readingText.coordinates }
    private var layoutWidth: CGFloat = 0
    private var pendingAnchor: UInt64?
    private var pendingPosition: ReadingPreviewPosition.Saved?
    private var needsTextLayout = false
    private var rendering = false

    init() {
        let storage = NSTextStorage()
        let manager = ReadingLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        super.init(frame: .zero, textContainer: container)
        isEditable = false; isSelectable = false
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityIdentifier = "readingPreviewText"
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(source: ReadingPreviewSource, settings: ReaderSettings, surface: ThemeSurface, typeSize: DynamicTypeSize,
                   restored: ReadingPreviewPosition.Saved? = nil) {
        if self.source != source {
            pendingAnchor = restored?.anchor ?? source.anchor; pendingPosition = restored; needsTextLayout = true
            accessibilityLabel = ReadingText(source.window).text
        } else if !settings.hasSameLayout(as: self.settings) || self.typeSize != typeSize {
            pendingAnchor = projectionAnchor(); needsTextLayout = true
        }
        self.source = source; self.settings = settings; self.surface = surface; self.typeSize = typeSize
        paint.set(surface.ink)
        overrideUserInterfaceStyle = surface.style
        updateDecorations()
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        setNeedsLayout()
    }

    private func projectionAnchor() -> UInt64 {
        guard let source, textStorage.length > 0, layoutManager.numberOfGlyphs > 0 else { return source?.anchor ?? 0 }
        let point = CGPoint(x: 0, y: max(0, contentOffset.y))
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let character = layoutManager.characterIndexForGlyph(at: min(glyph, max(0, layoutManager.numberOfGlyphs - 1)))
        guard let offset = coordinates.sourcePoint(character) else { return source.anchor }
        return source.window.start+UInt64(offset)
    }

    func capturePosition() -> ReadingPreviewPosition.Saved {
        .init(anchor: projectionAnchor(), offset: contentOffset, width: bounds.width)
    }

    override func layoutSubviews() {
        guard !rendering else { return }
        if bounds.width > 60, let source, let settings, needsTextLayout || layoutWidth != bounds.width {
            rendering = true
            let anchor = pendingAnchor ?? projectionAnchor()
            textContainerInset = ReadingTypography.insets(settings, width: bounds.width)
            textStorage.setAttributedString(ReadingTypography.text(source.window, settings: settings, ink: paint.dynamic))
            readingText = ReadingText(source.window)
            layoutWidth = bounds.width; needsTextLayout = false; pendingAnchor = nil
            super.layoutSubviews()
            layoutManager.ensureLayout(for: textContainer)
            if textStorage.length > 0 {
                let local = coordinates.displayPoint(Int(anchor.saturatingSubtract(source.window.start))) ?? 0
                let glyph = layoutManager.glyphIndexForCharacter(at: min(local, textStorage.length - 1))
                let y: CGFloat
                if let saved = pendingPosition, abs(saved.width - bounds.width) < 1 { y = saved.offset.y }
                else { y = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY }
                setContentOffset(CGPoint(x: 0, y: min(max(0, contentSize.height - bounds.height), y)), animated: false)
            }
            pendingPosition = nil
            updateDecorations()
            rendering = false
        }
        super.layoutSubviews()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), let settings {
            accessibilityValue = "\(Int(settings.fontSize))|\(Int(settings.lineSpacing))|\(Int(settings.horizontalMargin))|\(Int(settings.paragraphSpacing))|\(surface.plan.paletteId)|\(surface.plan.appearance)|\(projectionAnchor())"
        }
        #endif
    }

    private func updateDecorations() {
        guard let source, let manager = layoutManager as? ReadingLayoutManager else { return }
        manager.setDecorations(source.marks.compactMap { mark in
            let start = max(source.window.start, mark.start), end = min(source.window.end, mark.end)
            guard start < end else { return nil }
            guard let range = coordinates.displayRange(Int(start-source.window.start)..<Int(end-source.window.start)) else { return nil }
            let a = range.location, b = NSMaxRange(range)
            return .init(range: NSRange(location: a, length: b - a), color: mark.search ? surface.search : surface.annotation)
        })
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
