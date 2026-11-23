import SwiftUI

public struct AIProviderIcon: View {
    private let providerID: String?
    private let accent: UIColor

    public init(providerID: String?, accent: UIColor) {
        self.providerID = providerID
        self.accent = accent
    }

    private var asset: String? { providerID.flatMap { AIProviderBrand.asset(providerID: $0) } }
    public var body: some View {
        Group {
            if let asset { Image(asset, bundle: .module).resizable().scaledToFit() }
            else { Image(systemName: "sparkles").resizable().scaledToFit() }
        }.foregroundStyle(Color(uiColor: accent)).frame(width: 22, height: 22).accessibilityHidden(true)
    }
}
