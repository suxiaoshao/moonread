import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

public struct CloudInitialUploadProgress: Equatable, Sendable {
    public let processed: Int
    public let total: Int
}
