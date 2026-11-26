import Foundation
import MoonreadData

/// Kept by the reader until all of its asynchronous work has released it.
/// Merely hiding the view (for settings, for example) does not end this lease.
public final class ReadingLease: Sendable {
    public let id: String
    public let writeAdmission: DataSessionLease?
    let service: any ReaderDataAccess
    public let released: AsyncStream<Void>
    private let releaseSignal: AsyncStream<Void>.Continuation
    public init(id: String, service: any ReaderDataAccess, writeAdmission: DataSessionLease? = nil) {
        self.id = id; self.service = service; self.writeAdmission = writeAdmission
        (released, releaseSignal) = AsyncStream.makeStream(of: Void.self)
    }
    deinit {
        let id = id, service = service, releaseSignal = releaseSignal
        Task { await service.releaseReading(id); releaseSignal.finish() }
    }
}
