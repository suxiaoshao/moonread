import MoonreadCoreBindings
import SwiftUI

public struct MetadataCoverRequest {
    public let title: String
    public let cover: BookCoverAsset?
    public let contentSHA256: String?
    public let author: String?
    public let compact: Bool
    public let contentMode: ContentMode
    public let pixels: Int?
}

public extension EnvironmentValues {
    @Entry var metadataCoverRenderer: (MetadataCoverRequest) -> AnyView = { _ in AnyView(Color.clear) }
}

struct MetadataCoverPreview: View {
    let title: String
    let cover: BookCoverAsset?
    let contentSHA256: String?
    let author: String?
    var compact = false
    var contentMode: ContentMode
    var pixels: Int? = nil
    @Environment(\.metadataCoverRenderer) private var render

    var body: some View {
        render(.init(title: title, cover: cover, contentSHA256: contentSHA256, author: author,
                     compact: compact, contentMode: contentMode, pixels: pixels))
    }
}
