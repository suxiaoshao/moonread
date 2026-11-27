import MoonreadCoreBindings
import SwiftUI

public struct MetadataCoverRequest {
    public enum Source {
        case asset(BookCoverAsset?, pixels: Int?)
        case image(UIImage?)
    }

    public let title: String
    public let source: Source
    public let contentSHA256: String?
    public let author: String?
    public let compact: Bool
    public let contentMode: ContentMode
}

public extension EnvironmentValues {
    @Entry var metadataCoverRenderer: (MetadataCoverRequest) -> AnyView = { _ in AnyView(Color.clear) }
}

public struct MetadataCoverPreview: View {
    private let request: MetadataCoverRequest
    @Environment(\.metadataCoverRenderer) private var render

    public init(title: String, cover: BookCoverAsset? = nil, contentSHA256: String? = nil, author: String? = nil,
                compact: Bool = false, contentMode: ContentMode = .fill, pixels: Int? = nil) {
        request = .init(title: title, source: .asset(cover, pixels: pixels),
                        contentSHA256: contentSHA256, author: author, compact: compact, contentMode: contentMode)
    }

    public init(title: String, image: UIImage?, contentSHA256: String?, author: String?, compact: Bool) {
        request = .init(title: title, source: .image(image), contentSHA256: contentSHA256, author: author,
                        compact: compact, contentMode: .fill)
    }

    public var body: some View { render(request) }
}
