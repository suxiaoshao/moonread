import SwiftUI
import UIKit

@MainActor
final class ReaderCoverController: UIHostingController<AnyView> {
    private var currentTitle: String
    private var currentTheme: ThemeSurface
    private var information: BookDetails?
    init(title: String, information: BookDetails?, showDetails: @escaping () -> Void, theme: ThemeSurface, background: UIColor) {
        currentTitle = title; currentTheme = theme; self.information = information
        super.init(rootView: AnyView(ReaderTitlePage(title: title, information: information, showDetails: showDetails).themeScope(theme)))
        safeAreaRegions = []
        view.backgroundColor = background
        view.isAccessibilityElement = false
        view.accessibilityIdentifier = "readerCover"
        view.accessibilityLabel = String(localized: "封面，\(title)")
    }
    @MainActor required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(title: String, information: BookDetails?, showDetails: @escaping () -> Void, theme: ThemeSurface, background: UIColor) {
        view.backgroundColor = background
        guard currentTitle != title || currentTheme.plan != theme.plan || self.information != information else { return }
        currentTitle = title; currentTheme = theme; self.information = information
        rootView = AnyView(ReaderTitlePage(title: title, information: information, showDetails: showDetails).themeScope(theme))
        view.accessibilityLabel = String(localized: "封面，\(title)")
    }
}
