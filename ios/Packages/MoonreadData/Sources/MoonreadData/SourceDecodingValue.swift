import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import OSLog

public struct SourceDecodingValue: Codable, Sendable {
    public let decoding: String

    public init(decoding: String) {
        self.decoding = decoding
    }
}
