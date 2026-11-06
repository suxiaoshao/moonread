import CoreText
import ImageIO
import SwiftUI
import UIKit
import WidgetKit

/// Display-only allocation. This order and modulus are frozen after release.
enum PresetBookCoverID: String, CaseIterable, Sendable {
    case bamboo, river, vermilion, moonlake, plum, lotus
    var assetName: String { "PresetCover-" + rawValue }
    var ink: UIColor {
        let rgb: UInt32 = switch self {
        case .bamboo: 0xd8c99f
        case .river: 0x494434
        case .vermilion: 0xf4e4c4
        case .moonlake: 0xd3cdb7
        case .plum: 0xdbc6c0
        case .lotus: 0x405452
        }
        return SystemCoverTypography.color(rgb)
    }
    var spineInk: UIColor {
        let rgb: UInt32 = switch self {
        case .bamboo: 0xf4e7bf
        case .river: 0x302e23
        case .vermilion: 0xfff0ce
        case .moonlake: 0xf5e8ca
        case .plum: 0xf9eadc
        case .lotus: 0x314345
        }
        return SystemCoverTypography.color(rgb)
    }
}

/// Shared installed-face check, also used by the reader's existing font picker.
/// UIFont lookup never requests a download or enumerates personal fonts.
enum SystemInstalledFont {
    static let songtiName = "STSongti-SC-Regular"
    static func lookup(_ name: String, size: CGFloat) -> UIFont? {
        guard let font = UIFont(name: name, size: size), font.fontName == name else { return nil }
        let characters = Array("月读".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count) ? font : nil
    }
    static var coverFace: String { lookup(songtiName, size: 20)?.fontName ?? (UIFont(name: "PingFangSC-Medium", size: 20) ?? UIFont.systemFont(ofSize: 20, weight: .medium)).fontName }
}

enum SystemCoverTypography {
    static func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static var fallbackPaper: UIColor { color(0xe4ded2) }
    static var fallbackInk: UIColor { color(0x504a40) }
    static func latinFont(size: CGFloat) -> UIFont {
        if let font = UIFont(name: "Georgia", size: size) { return font }
        let system = UIFont.systemFont(ofSize: size)
        return UIFont(descriptor: system.fontDescriptor.withDesign(.serif) ?? system.fontDescriptor, size: size)
    }
    static func chineseFont(face: String, size: CGFloat) -> UIFont { UIFont(name: face, size: size) ?? .systemFont(ofSize: size, weight: .medium) }
}

func presetCoverID(contentSHA256: String?) -> PresetBookCoverID? {
    guard let sha = contentSHA256 else { return nil }
    #if !MOONREAD_WIDGET
    guard (try? parseSha256(value: sha)) != nil else { return nil }
    #endif
    // The extension cannot link Rust. Defensively validate the incoming spelling;
    // this never computes or changes a book's authoritative content identity.
    guard sha.utf8.count == 64 else { return nil }
    var remainder = 0
    for digit in sha.utf8 {
        let value: Int
        switch digit {
        case 48...57: value = Int(digit - 48)
        case 97...102: value = Int(digit - 87)
        default: return nil
        }
        remainder = (remainder * 16 + value) % 6
    }
    return PresetBookCoverID.allCases[remainder]
}

/// All hosts share the same pixels and typesetting; size/scale are part of the
/// bounded cache so neither scrolling nor widget updates redraw unchanged covers.
enum SystemPresetCoverRenderer {
    static let layoutVersion = 5
    // NSCache synchronizes its own access; the shared reference is never replaced.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()
    struct Request: Hashable, Sendable {
        let id: PresetBookCoverID
        let title: String
        let author: String?
        let width: Int
        let height: Int
        let scale: CGFloat
        let chineseFace: String
        init(id: PresetBookCoverID, title: String, author: String?, size: CGSize, scale: CGFloat, chineseFace: String = SystemInstalledFont.coverFace) {
            self.chineseFace = chineseFace
            self.id = id; self.title = title; self.author = author?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.scale = max(1, scale)
            width = max(1, Int((size.width * self.scale).rounded()))
            height = max(1, Int((size.height * self.scale).rounded()))
        }
        var size: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
        var key: NSString { "\(layoutVersion):\(chineseFace):\(id.rawValue):\(width)x\(height)@\(scale):\(title.utf8.count):\(title):\(author ?? "")" as NSString }
    }
    static func image(_ request: Request) -> UIImage {
        if let image = cache.object(forKey: request.key) { return image }
        let size = request.size
        let format = UIGraphicsImageRendererFormat(); format.scale = request.scale; format.opaque = true
        let result = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let rect = CGRect(origin: .zero, size: size)
            SystemCoverTypography.fallbackPaper.setFill(); renderer.fill(rect)
            if let background = UIImage(named: request.id.assetName) {
                let factor = max(size.width / background.size.width, size.height / background.size.height)
                let drawn = CGSize(width: background.size.width * factor, height: background.size.height * factor)
                let thumbnail = background.preparingThumbnail(of: CGSize(width: drawn.width * request.scale, height: drawn.height * request.scale)) ?? background
                thumbnail.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
            }
            let context = renderer.cgContext
            let shadow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor.black.withAlphaComponent(0.2).cgColor, UIColor.clear.cgColor] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(shadow, start: .zero, end: CGPoint(x: size.width * 0.04, y: 0), options: [])
            context.setStrokeColor(request.id.spineInk.withAlphaComponent(0.16).cgColor); context.setLineWidth(0.5)
            context.move(to: CGPoint(x: size.width * 0.04, y: 0)); context.addLine(to: CGPoint(x: size.width * 0.04, y: size.height)); context.strokePath()
            drawText(request, context: context)
        }
        cache.setObject(result, forKey: request.key, cost: request.width * request.height * 4)
        return result
    }
    private static let latinLetters = try! NSRegularExpression(pattern: "\\p{script=Latin}")
    private static let hanLetters = try! NSRegularExpression(pattern: "\\p{script=Han}")
    private static func latinTitle(_ title: String) -> Bool {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        let latin = latinLetters.numberOfMatches(in: title, range: range)
        return latin > 0 && latin > hanLetters.numberOfMatches(in: title, range: range)
    }
    private static func drawText(_ request: Request, context: CGContext) {
        let size = request.size, large = size.width >= 120
        let fontSize: CGFloat = large ? min(28, size.width * 0.102) : size.width < 60 ? 12 : 13
        let color = request.id.ink
        let title = request.title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let latin = latinTitle(title)
        let kern = min(2, max(0.35, size.width * 0.008))
        if latin {
            drawEnglish(title, author: request.author, size: size, large: large, color: color)
        } else {
            let titleHeight = min(size.height * 0.86, fontSize * 8.4 + kern * 7)
            let columnSpacing: CGFloat = large ? 1.25 : 1.15
            let columnCount = large ? 2 : max(1, min(2, Int(size.width * 0.9 / (fontSize * columnSpacing))))
            vertical(title, fontSize: fontSize, face: request.chineseFace, kern: kern, color: color,
                     bounds: CGRect(x: size.width * 0.9 - fontSize, y: size.height * 0.07, width: fontSize * 1.2, height: titleHeight),
                     columns: columnCount, columnSpacing: columnSpacing, canvasHeight: size.height, context: context)
        }
        if !latin, large, let author = request.author, !author.isEmpty {
            let small = max(10, fontSize * 0.5)
            let text = author + " 著"
            vertical(text, fontSize: small, face: request.chineseFace, kern: kern, color: color.withAlphaComponent(0.8), bounds: CGRect(x: size.width * 0.9 - small, y: size.height * 0.7, width: small * 1.2, height: size.height * 0.26), canvasHeight: size.height, context: context)
        }
    }
    private static func drawEnglish(_ title: String, author: String?, size: CGSize, large: Bool, color: UIColor) {
        let pointSize: CGFloat = large ? min(23, max(13, size.width * 0.075)) : 10
        let font = SystemCoverTypography.latinFont(size: pointSize)
        let authorSize = min(11, max(9, size.width * 0.04))
        let authorFont = SystemCoverTypography.latinFont(size: authorSize)
        let width = size.width * (large ? 0.51 : 0.79)
        let origin = CGPoint(x: size.width * (large ? 0.4 : 0.13), y: size.height * (large ? 0.1 : 0.09))
        let author = large ? author.flatMap { $0.isEmpty ? nil : $0 } : nil
        let lineHeight = max(font.lineHeight, pointSize * 1.15)
        let gap = author == nil ? 0 : authorSize * 1.2
        let authorHeight = author == nil ? 0 : authorFont.lineHeight * 2
        let available = size.height * (large ? 0.55 : 0.84)
        let count = max(1, min(large ? 5 : size.width >= 60 ? 4 : 3, Int((available - gap - authorHeight) / lineHeight)))
        let lines = englishLines(title, font: font, width: width, count: count)
        for (index, line) in lines.enumerated() {
            let lineWidth = (line as NSString).size(withAttributes: [.font: font]).width
            let x = origin.x + (large ? max(0, width - lineWidth) : 0)
            (line as NSString).draw(at: CGPoint(x: x, y: origin.y + CGFloat(index) * lineHeight), withAttributes: [.font: font, .foregroundColor: color])
        }
        if let author {
            let kern = authorSize * 0.025
            let attributes: [NSAttributedString.Key: Any] = [.font: authorFont, .foregroundColor: color.withAlphaComponent(0.8), .kern: kern]
            let authorLines = englishLines(author, font: authorFont, width: width, count: 2, kern: kern)
            for (index, line) in authorLines.enumerated() {
                let lineWidth = (line as NSString).size(withAttributes: attributes).width
                (line as NSString).draw(at: CGPoint(x: origin.x + max(0, width - lineWidth), y: origin.y + CGFloat(lines.count) * lineHeight + gap + CGFloat(index) * authorFont.lineHeight), withAttributes: attributes)
            }
        }
    }
    /// Match the prototype with measured native glyphs: whole words, no automatic
    /// hyphens; a word wider than the block is shortened once and stops the title.
    private static func englishLines(_ text: String, font: UIFont, width: CGFloat, count: Int, kern: CGFloat = 0) -> [String] {
        func fits(_ value: String) -> Bool { (value as NSString).size(withAttributes: [.font: font, .kern: kern]).width <= width }
        func truncated(_ value: String) -> String {
            var value = value
            while !value.isEmpty && !fits(value + "…") { value.removeLast() }
            return value.trimmingCharacters(in: .whitespaces) + "…"
        }
        var lines: [String] = [], line = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let next = line.isEmpty ? word : line + " " + word
            if fits(next) { line = next; continue }
            if !line.isEmpty {
                lines.append(line); line = ""
                if lines.count == count { lines[count - 1] = truncated(lines[count - 1]); return lines }
            }
            if !fits(word) { lines.append(truncated(word)); return lines }
            line = word
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }
    enum VerticalToken: Equatable {
        case upright(String), horizontal(String), rotated(String), space
    }
    private static let latinOrDigit = try! NSRegularExpression(pattern: "^[\\p{script=Latin}\\p{Nd}\\p{M}]+$")
    /// Keep grapheme clusters and Latin/number runs intact. A whitespace run is
    /// a small separator, never a full-width glyph or a column by itself.
    static func verticalTokens(_ text: String) -> [VerticalToken] {
        var tokens: [VerticalToken] = [], run = ""
        func flush() {
            guard !run.isEmpty else { return }
            tokens.append(run.count <= 3 ? .horizontal(run) : .rotated(run)); run = ""
        }
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            let value = String(character), range = NSRange(value.startIndex..<value.endIndex, in: value)
            if latinOrDigit.firstMatch(in: value, range: range) != nil { run += value }
            else {
                flush()
                if character.isWhitespace {
                    if tokens.last != .space { tokens.append(.space) }
                } else { tokens.append(.upright(value)) }
            }
        }
        flush()
        return tokens
    }
    /// Keep closing punctuation with the preceding visible unit, including
    /// punctuation chains. Only the group can wrap, never its closing marks.
    static func verticalGroups(_ tokens: [VerticalToken]) -> [[VerticalToken]] {
        let prohibited = Set("、。，．：；！？）》」』】〕〉〗〙〛’”»›…,.!?;:%)]}")
        var groups: [[VerticalToken]] = []
        for token in tokens {
            if case .upright(let value) = token, let character = value.first, prohibited.contains(character), !groups.isEmpty {
                var spaces: [VerticalToken] = []
                while groups.last == [.space] { spaces += groups.removeLast() }
                if groups.isEmpty { groups.append(spaces + [token]) }
                else { groups[groups.count - 1] += spaces + [token] }
            } else { groups.append([token]) }
        }
        return groups
    }
    private static func vertical(_ text: String, fontSize: CGFloat, face: String, kern: CGFloat, color: UIColor, bounds: CGRect,
                                 columns: Int = 1, columnSpacing: CGFloat = 1.15, canvasHeight: CGFloat, context: CGContext) {
        let latinFont = SystemCoverTypography.latinFont(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: latinFont, .foregroundColor: color]
        let latinScale = min(1, fontSize / latinFont.lineHeight)
        func fittedWord(_ text: String, height: CGFloat) -> String {
            var value = text
            guard (value as NSString).size(withAttributes: attributes).width * latinScale > height else { return value }
            while !value.isEmpty && ((value + "…") as NSString).size(withAttributes: attributes).width * latinScale > height { value.removeLast() }
            return value + "…"
        }
        func advance(_ token: VerticalToken) -> CGFloat {
            switch token {
            case .space: return fontSize * 0.2
            case .horizontal: return fontSize
            case .rotated(let word): return (word as NSString).size(withAttributes: attributes).width * latinScale
            case .upright(let value):
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                return fontSize + (hanLetters.firstMatch(in: value, range: range) == nil ? 0 : kern)
            }
        }
        var lines = [[VerticalToken]](repeating: [], count: columns), heights = [CGFloat](repeating: 0, count: columns), column = 0
        for group in verticalGroups(verticalTokens(text)) {
            let reserved = group.reduce(CGFloat.zero) { total, token in
                if case .rotated = token { return total }
                return total + advance(token)
            }
            let tokens = group.map { token -> VerticalToken in
                if case .rotated(let word) = token { return .rotated(fittedWord(word, height: max(1, bounds.height - reserved))) }
                return token
            }
            if tokens == [.space] && lines[column].isEmpty { continue }
            let height = tokens.reduce(CGFloat.zero) { $0 + advance($1) }
            if heights[column] + height > bounds.height {
                if column + 1 < columns { column += 1; if tokens == [.space] { continue } }
                else {
                    while let last = lines[column].last, last == .space || heights[column] + fontSize > bounds.height {
                        heights[column] -= advance(last); lines[column].removeLast()
                    }
                    lines[column].append(.upright("︙")); break
                }
            }
            lines[column].append(contentsOf: tokens); heights[column] += height
        }
        for (index, line) in lines.enumerated() {
            let x = bounds.minX - CGFloat(index) * fontSize * columnSpacing
            var y = bounds.minY
            for token in line {
                let height = advance(token)
                switch token {
                case .space: break
                case .upright(let value):
                    verticalGlyph(value, fontSize: fontSize, face: face, color: color,
                                  bounds: CGRect(x: x, y: y, width: bounds.width, height: fontSize * 1.5), canvasHeight: canvasHeight, context: context)
                case .horizontal(let word), .rotated(let word):
                    let measured = (word as NSString).size(withAttributes: attributes)
                    context.saveGState()
                    context.translateBy(x: x + fontSize * 0.5, y: y + height * 0.5)
                    if case .rotated = token { context.rotate(by: .pi / 2) }
                    let factor = min(1, fontSize / max(1, measured.height), (token == .horizontal(word) ? fontSize : bounds.height) / max(1, measured.width))
                    context.scaleBy(x: factor, y: factor)
                    (word as NSString).draw(at: CGPoint(x: -measured.width / 2, y: -measured.height / 2), withAttributes: attributes)
                    context.restoreGState()
                }
                y += height
            }
        }
    }
    private static func verticalGlyph(_ text: String, fontSize: CGFloat, face: String, color: UIColor, bounds: CGRect, canvasHeight: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName(face as CFString, fontSize, nil)
        let text = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor])
        // Keep Core Text's upright CJK, vertical punctuation and emoji fallback.
        let path = CGPath(rect: CGRect(x: bounds.maxX - max(bounds.width, fontSize * 2.2), y: canvasHeight - bounds.maxY, width: max(bounds.width, fontSize * 2.2), height: bounds.height), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary)
        context.saveGState(); context.textMatrix = .identity
        context.translateBy(x: 0, y: canvasHeight); context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context); context.restoreGState()
    }
}

struct SystemPresetBookCover: View {
    let id: PresetBookCoverID
    let title: String
    var author: String? = nil
    var chineseFace = SystemInstalledFont.coverFace
    var rendersSynchronously = false
    @Environment(\.displayScale) private var scale
    @State private var rendered: (SystemPresetCoverRenderer.Request, UIImage)?
    var body: some View {
        GeometryReader { geometry in
            let request = SystemPresetCoverRenderer.Request(id: id, title: title, author: author, size: geometry.size, scale: scale, chineseFace: chineseFace)
            #if MOONREAD_WIDGET
            Image(uiImage: SystemPresetCoverRenderer.image(request)).resizable()
                .widgetAccentedRenderingMode(.desaturated)
                .frame(width: geometry.size.width, height: geometry.size.height)
            #else
            Group {
                if rendersSynchronously { Image(uiImage: SystemPresetCoverRenderer.image(request)).resizable() }
                else if let rendered, rendered.0 == request { Image(uiImage: rendered.1).resizable() }
                else { Image(id.assetName).resizable().scaledToFill() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .task(id: request) {
                    guard !rendersSynchronously else { return }
                    let image = await Task.detached(priority: .utility) { SystemPresetCoverRenderer.image(request) }.value
                    if !Task.isCancelled { rendered = (request, image) }
                }
            #endif
        }.accessibilityHidden(true)
    }
}
