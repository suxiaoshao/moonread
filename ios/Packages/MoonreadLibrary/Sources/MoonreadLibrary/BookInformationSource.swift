import Combine
import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes

public struct BookInformationTarget: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        case library
        case reader(fileID: String? = nil)
    }

    public let target: BookTarget
    public let origin: Origin

    public init(target: BookTarget, origin: Origin = .library) {
        self.target = target
        self.origin = origin
    }

    public var fromReader: Bool {
        if case .reader = origin { return true }
        return false
    }

    public var fileID: String? {
        if case .file(let id) = target { return id }
        if case .reader(let id) = origin { return id }
        return nil
    }
}

public enum BookInformationPreparationStep: Sendable {
    case downloading
    case indexing
}

@MainActor
public struct BookInformationSource {
    public typealias Value = (LibraryEntry?, BookDetailsResult)
    public typealias Coverage = @MainActor @Sendable (Result<ChapterOutline?, Error>) -> Void
    public typealias Progress = @MainActor @Sendable (BookInformationPreparationStep, Double?) -> Void

    let read: @MainActor (BookInformationTarget) async throws -> Value
    let readChapters: (@MainActor (String) async throws -> [ChapterEntry])?
    let updates: @MainActor (BookInformationTarget) async throws -> AsyncThrowingStream<BookInformationRead.Update, Error>
    let observeCoverage: @MainActor (String, @escaping Coverage) async throws -> Void
    let prepareMetadata: @MainActor (SourceFile?, String?, @escaping Progress) async throws -> BookDetailsResult
    let makeDraft: @MainActor (BookMetadata) -> BookMetadataDraft
    let saveMetadata: @MainActor (BookMetadata, BookMetadata) async throws -> Void
    let details: @MainActor (BookTarget) async throws -> BookDetailsResult
    let observeAccount: @MainActor (@escaping @MainActor () -> Void) -> AnyCancellable
    let describeError: @MainActor (Error) -> String

    public init(
        read: @escaping @MainActor (BookInformationTarget) async throws -> Value,
        readChapters: (@MainActor (String) async throws -> [ChapterEntry])? = nil,
        updates: @escaping @MainActor (BookInformationTarget) async throws -> AsyncThrowingStream<BookInformationRead.Update, Error>,
        observeCoverage: @escaping @MainActor (String, @escaping Coverage) async throws -> Void,
        prepareMetadata: @escaping @MainActor (SourceFile?, String?, @escaping Progress) async throws -> BookDetailsResult,
        makeDraft: @escaping @MainActor (BookMetadata) -> BookMetadataDraft,
        saveMetadata: @escaping @MainActor (BookMetadata, BookMetadata) async throws -> Void,
        details: @escaping @MainActor (BookTarget) async throws -> BookDetailsResult,
        observeAccount: @escaping @MainActor (@escaping @MainActor () -> Void) -> AnyCancellable,
        describeError: @escaping @MainActor (Error) -> String
    ) {
        self.read = read
        self.readChapters = readChapters
        self.updates = updates
        self.observeCoverage = observeCoverage
        self.prepareMetadata = prepareMetadata
        self.makeDraft = makeDraft
        self.saveMetadata = saveMetadata
        self.details = details
        self.observeAccount = observeAccount
        self.describeError = describeError
    }
}
