import Foundation

public struct AIAnnotationCommitTicket {
    public let owner: String
    public let token: UUID

    public init(owner: String, token: UUID) {
        self.owner = owner
        self.token = token
    }
}

public struct AIAnnotationCommitHooks {
    public init(begin: @escaping @MainActor () throws -> AIAnnotationCommitTicket,
                saved: @escaping @MainActor () -> Void, finish: @escaping @MainActor (AIAnnotationCommitTicket) -> Void) {
        self.begin = begin
        self.saved = saved
        self.finish = finish
    }

    let begin: @MainActor () throws -> AIAnnotationCommitTicket
    let saved: @MainActor () -> Void
    let finish: @MainActor (AIAnnotationCommitTicket) -> Void
}
