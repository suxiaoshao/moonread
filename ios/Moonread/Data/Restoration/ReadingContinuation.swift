import MoonreadReader
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation

extension AppDataService {
    /// A suggestion reads only the selected position, its device baseline
    /// and, if distant enough, the heading at the target.
    func readingResumeContext(_ id: String, currentOffset: UInt64? = nil) async throws -> ReadingResumeContext {
        let configuration = userCloudConfigurationRevision
        guard let resume = try await fixedReaderRead({ try $0.readerResume(id, currentOffset: currentOffset) }) else {
            return .init(localOffset: nil, candidate: nil)
        }
        return .init(localOffset: resume.localOffset,
                     candidate: .init(contentSHA: resume.key, token: resume.token, configuration: configuration, location: resume.location))
    }
}
