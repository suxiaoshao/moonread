import UIKit

public extension UIColor {
    var opaqueRGB: UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if let space = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = cgColor.converted(to: space, intent: .defaultIntent, options: nil),
           let components = converted.components, components.count >= 3 {
            r = components[0]; g = components[1]; b = components[2]
        } else { getRed(&r, green: &g, blue: &b, alpha: &a) }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
