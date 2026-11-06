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
        case .bamboo: 0xf4e7bf
        case .river: 0x302e23
        case .vermilion: 0xfff0ce
        case .moonlake: 0xf5e8ca
        case .plum: 0xf9eadc
        case .lotus: 0x314345
        }
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
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
    static let layoutVersion = 2
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
        init(id: PresetBookCoverID, title: String, author: String?, size: CGSize, scale: CGFloat) {
            self.id = id; self.title = title; self.author = author?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.scale = max(1, scale)
            width = max(1, Int((size.width * self.scale).rounded()))
            height = max(1, Int((size.height * self.scale).rounded()))
        }
        var size: CGSize { CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale) }
        var key: NSString { "\(layoutVersion):\(id.rawValue):\(width)x\(height)@\(scale):\(title.utf8.count):\(title):\(author ?? "")" as NSString }
    }
    static func image(_ request: Request) -> UIImage {
        if let image = cache.object(forKey: request.key) { return image }
        let size = request.size
        let format = UIGraphicsImageRendererFormat(); format.scale = request.scale; format.opaque = true
        let result = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.secondarySystemBackground.setFill(); renderer.fill(rect)
            if let background = UIImage(named: request.id.assetName) {
                let factor = max(size.width / background.size.width, size.height / background.size.height)
                let drawn = CGSize(width: background.size.width * factor, height: background.size.height * factor)
                let thumbnail = background.preparingThumbnail(of: CGSize(width: drawn.width * request.scale, height: drawn.height * request.scale)) ?? background
                thumbnail.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
            }
            let context = renderer.cgContext
            let shadow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor.black.withAlphaComponent(0.2).cgColor, UIColor.clear.cgColor] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(shadow, start: .zero, end: CGPoint(x: size.width * 0.04, y: 0), options: [])
            context.setStrokeColor(request.id.ink.withAlphaComponent(0.16).cgColor); context.setLineWidth(0.5)
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
        if latin {
            let latinSize = large ? max(11, min(19, size.width * 0.066)) : 10
            let font = UIFont(descriptor: UIFont.systemFont(ofSize: latinSize, weight: .semibold).fontDescriptor.withDesign(.serif)!, size: latinSize)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            let bounds = CGRect(x: size.width * (large ? 0.52 : 0.13), y: size.height * 0.09, width: size.width * (large ? 0.4 : 0.79), height: size.height * (large ? 0.49 : 0.82))
            (title as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph], context: nil)
        } else {
            // Swift Character keeps emoji/combining sequences intact. Core Text
            // supplies upright CJK and vertical punctuation, never rotated Text.
            let rows = large ? 8 : max(1, min(8, Int(size.height * 0.86 / fontSize)))
            let columnSpacing: CGFloat = large ? 1.25 : 1.15
            let columnCount = large ? 2 : max(1, min(2, Int(size.width * 0.9 / (fontSize * columnSpacing))))
            let capacity = rows * columnCount
            let characters = Array(title)
            let visible = characters.count > capacity ? String(characters.prefix(capacity - 1)) + "︙" : title
            let shown = Array(visible)
            let columns = stride(from: 0, to: shown.count, by: rows).map { String(shown[$0..<min($0 + rows, shown.count)]) }
            for (index, column) in columns.enumerated() where !column.isEmpty {
                let bounds = CGRect(x: size.width * 0.9 - fontSize * (columnSpacing * CGFloat(index) + 1), y: size.height * 0.07, width: fontSize * 1.2, height: min(size.height * 0.86, fontSize * 8.4))
                vertical(column, fontSize: fontSize, color: color, bounds: bounds, canvasHeight: size.height, context: context)
            }
        }
        if large, let author = request.author, !author.isEmpty {
            if latin {
                let bounds = CGRect(x: size.width * 0.3, y: size.height * 0.8, width: size.width * 0.6, height: size.height * 0.12)
                (author as NSString).draw(with: bounds, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: [.font: UIFont.systemFont(ofSize: max(10, fontSize * 0.5)), .foregroundColor: color], context: nil)
            } else {
                let small = max(10, fontSize * 0.5)
                let capacity = max(1, min(7, Int(size.height * 0.26 / small) - 2))
                let text = String(author.prefix(capacity)) + " 著"
                vertical(text, fontSize: small, color: color, bounds: CGRect(x: size.width * 0.9 - small, y: size.height * 0.7, width: small * 1.2, height: size.height * 0.26), canvasHeight: size.height, context: context)
            }
        }
    }
    private static func vertical(_ text: String, fontSize: CGFloat, color: UIColor, bounds: CGRect, canvasHeight: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, fontSize, nil)
        let text = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor])
        // Emoji fallback fonts can have larger cross-axis metrics than CJK.
        // Reserve their line width while keeping the same right/top text edge.
        let path = CGPath(rect: CGRect(x: bounds.maxX - max(bounds.width, fontSize * 2.2), y: canvasHeight - bounds.maxY, width: max(bounds.width, fontSize * 2.2), height: bounds.height), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        // https://developer.apple.com/documentation/coretext/ctframeprogression
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
    @Environment(\.displayScale) private var scale
    @State private var rendered: (SystemPresetCoverRenderer.Request, UIImage)?
    var body: some View {
        GeometryReader { geometry in
            let request = SystemPresetCoverRenderer.Request(id: id, title: title, author: author, size: geometry.size, scale: scale)
            #if MOONREAD_WIDGET
            Image(uiImage: SystemPresetCoverRenderer.image(request)).resizable()
                .widgetAccentedRenderingMode(.desaturated)
                .frame(width: geometry.size.width, height: geometry.size.height)
            #else
            Group {
                if let rendered, rendered.0 == request { Image(uiImage: rendered.1).resizable() }
                else { Image(id.assetName).resizable().scaledToFill() }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .task(id: request) {
                    let image = await Task.detached(priority: .utility) { SystemPresetCoverRenderer.image(request) }.value
                    if !Task.isCancelled { rendered = (request, image) }
                }
            #endif
        }.accessibilityHidden(true)
    }
}
