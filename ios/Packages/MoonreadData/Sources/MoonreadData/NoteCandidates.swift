import Foundation
import MoonreadCoreBindings
import MoonreadDataTypes

/// Ephemeral read snapshot, never a new sync or backup format.
public struct NoteCandidates: Sendable {
    public let key: String
    public let groups: [String: [AnnotationCandidate]]
    public let blocked: Set<String>
    public var unknownMarks = false
    public var admission: DataSessionLease? = nil
    public func checked(_ ids: Set<String>?) throws -> [String: [AnnotationCandidate]] {
        let unreadable = ids.map { blocked.intersection($0) } ?? blocked
        guard unreadable.isEmpty, !unknownMarks else { throw NoteReadError(count: unreadable.count + (unknownMarks ? 1 : 0)) }
        return groups.filter { ids?.contains($0.key) ?? true }
    }

    public init(key: String,
                groups: [String: [AnnotationCandidate]],
                blocked: Set<String>,
                unknownMarks: Bool = false,
                admission: DataSessionLease? = nil) {
        self.key = key
        self.groups = groups
        self.blocked = blocked
        self.unknownMarks = unknownMarks
        self.admission = admission
    }
}
public struct NoteReadError: LocalizedError {
    public let count: Int
    public var errorDescription: String? { String(localized: "有 \(count) 条记录无法读取，暂时无法完整分享或导出。请在数据管理中查看。") }

    public init(count: Int) {
        self.count = count
    }
}
