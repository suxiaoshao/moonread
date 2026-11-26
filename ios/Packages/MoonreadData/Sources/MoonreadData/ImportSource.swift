import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

public struct ImportSource: Codable, Equatable, Sendable {
    public let rootBookmark: Data
    public let relativePath: String
    public var encoding: String? = nil
    public var fileID: String? = nil
    public var expectedRawSHA: String? = nil

    public init(rootBookmark: Data,
                relativePath: String,
                encoding: String? = nil,
                fileID: String? = nil,
                expectedRawSHA: String? = nil) {
        self.rootBookmark = rootBookmark
        self.relativePath = relativePath
        self.encoding = encoding
        self.fileID = fileID
        self.expectedRawSHA = expectedRawSHA
    }
}
