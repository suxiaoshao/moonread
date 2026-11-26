import MoonreadCoreBindings
import MoonreadDesign
import SwiftUI
import UIKit

extension ThemeSurface {
    struct PaperInput: Equatable {
        let paper: UInt32
        let descriptor: ReaderTextureDescriptor?
    }
    func paperInput() -> PaperInput {
        PaperInput(paper: paper.opaqueRGB, descriptor: readerTexture?.activeDescriptor)
    }
    /// Prepare at the artwork's fixed reference resolution, independently of
    /// view bounds/display scale. Resizing only places this already mixed image.
    static func paperImage(_ input: PaperInput, asset: ReaderTextureAsset) -> UIImage? {
        guard let image = UIImage(named: asset.name)?.cgImage, let descriptor = input.descriptor,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.setFillColor(UIColor(rgb: input.paper).cgColor); context.fill(bounds)
        let blend: CGBlendMode
        switch descriptor.blend { case .multiply: blend = .multiply; case .screen: blend = .screen; case .softLight: blend = .softLight; default: blend = .normal }
        if descriptor.blend == .softLight { context.clear(bounds) }
        context.setBlendMode(descriptor.blend == .softLight ? .normal : blend)
        context.setAlpha(descriptor.blend == .softLight ? 1 : CGFloat(descriptor.opacity))
        context.draw(image, in: bounds)
        if descriptor.blend == .softLight { cssSoftLight(context, paper: input.paper, opacity: CGFloat(descriptor.opacity)) }
        return context.makeImage().map { UIImage(cgImage: $0) }
    }
    /// Quartz soft-light differs visibly from the approved CSS artwork on dark paper.
    /// W3C sRGB, evaluated only on a changed background using channel lookup tables.
    /// https://www.w3.org/TR/compositing-1/#blendingsoftlight
    private static func cssSoftLight(_ context: CGContext, paper: UInt32, opacity: CGFloat) {
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        let base = [16, 8, 0].map { Int((paper >> $0) & 255) }
        let tables: [[Int]] = base.map { byte in
            let b = Double(byte) / 255
            let d = b <= 0.25 ? ((16 * b - 12) * b + 4) * b : sqrt(b)
            return (0..<256).map { value in
                let s = Double(value) / 255
                let blend = s <= 0.5 ? b - (1 - 2 * s) * b * (1 - b) : b + (2 * s - 1) * (d - b)
                return Int((255 * (b + (blend - b) * Double(opacity))).rounded())
            }
        }
        for offset in stride(from: 0, to: context.bytesPerRow * context.height, by: 4) {
            let alpha = Int(data[offset + 3])
            for channel in 0..<3 {
                let source = alpha == 0 ? 0 : min(255, Int(data[offset + channel]) * 255 / alpha)
                let result = base[channel] + (tables[channel][source] - base[channel]) * alpha / 255
                data[offset + channel] = UInt8(clamping: result)
            }
            data[offset + 3] = 255
        }
    }
}

/// One prepared result can be retained by both reader and preview. The factory
/// only retains the most recent input, never a dictionary of sizes or palettes.
@MainActor
final class PreparedReadingPaper {
    private static var current: PreparedReadingPaper?
    let input: ThemeSurface.PaperInput
    struct Layer {
        let description: ReaderTextureLayer
        let image: UIImage?
    }
    private(set) lazy var layers: [Layer] = input.descriptor?.layers.map {
        Layer(description: $0, image: ThemeSurface.paperImage(input, asset: $0.asset))
    } ?? []
    private init(_ input: ThemeSurface.PaperInput) { self.input = input }
    static func resolve(_ input: ThemeSurface.PaperInput) -> PreparedReadingPaper {
        if let current, current.input == input { return current }
        let result = PreparedReadingPaper(input)
        current = result
        return result
    }
    /// Native reader and preview use this one placement calculation. Only small
    /// rectangles change during resize; image preparation never receives bounds.
    func frames(in size: CGSize) -> [CGRect] {
        guard size.width > 0, size.height > 0, let descriptor = input.descriptor else { return layers.map { _ in .zero } }
        let unit = min(size.width, size.height) / CGFloat(descriptor.referenceShortSide)
        return layers.map { layer in
            let value = layer.description
            let reference = CGSize(width: CGFloat(value.asset.referenceWidth), height: CGFloat(value.asset.referenceHeight))
            let width: CGFloat, height: CGFloat
            switch value.placement {
            case .cover: return CGRect(origin: .zero, size: size)
            case .edge:
                width = size.width
                height = min(reference.height * unit, size.height * CGFloat(value.maxHeightFraction))
            case .fit:
                let scale = min(unit, size.width * CGFloat(value.maxWidthFraction) / reference.width,
                                size.height * CGFloat(value.maxHeightFraction) / reference.height)
                width = reference.width * scale; height = reference.height * scale
            }
            return CGRect(x: (size.width - width) * CGFloat(value.anchorX),
                          y: (size.height - height) * CGFloat(value.anchorY), width: width, height: height)
        }
    }
}
