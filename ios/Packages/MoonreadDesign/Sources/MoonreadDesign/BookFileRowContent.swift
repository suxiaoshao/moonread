import SwiftUI

public enum BookFileRowLayout {
    public static let coverSize = CGSize(width: 56, height: 80)
    public static let textLeading = coverSize.width + LayoutTokens.control
    public static let statusAlignment = VerticalAlignment(StatusAlignment.self)

    private enum StatusAlignment: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
    }
}

public struct BookFileRowContent<Cover: View, Status: View>: View {
    private let title: Text
    private let author: Text?
    private let showsMenu: Bool
    private let unavailable: Bool
    private let cover: Cover
    private let status: Status

    public init(title: Text, author: Text?, showsMenu: Bool = false, unavailable: Bool = false,
                @ViewBuilder cover: () -> Cover, @ViewBuilder status: () -> Status) {
        self.title = title
        self.author = author
        self.showsMenu = showsMenu
        self.unavailable = unavailable
        self.cover = cover()
        self.status = status()
    }
    @Environment(\.theme) private var theme

    public var body: some View {
        HStack(spacing: LayoutTokens.control) {
            cover.frame(width: BookFileRowLayout.coverSize.width, height: BookFileRowLayout.coverSize.height)
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                title.font(.body.weight(.medium)).lineLimit(1)
                    .foregroundStyle(Color(uiColor: unavailable ? theme.secondary : theme.ink))
                if let author {
                    author.font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                }
                status.font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                    .alignmentGuide(BookFileRowLayout.statusAlignment) { $0[.bottom] }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, showsMenu ? LayoutTokens.hit : 0)
        }
    }
}
