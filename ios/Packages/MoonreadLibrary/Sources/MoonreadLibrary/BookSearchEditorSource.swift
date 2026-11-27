import Combine
import Foundation
import MoonreadCoreBindings
import MoonreadData

@MainActor
public struct BookSearchEditorSource {
    let shelfTitle: (String) -> String
    let shelves: () -> [LibraryShelf]
    let metadataOptions: () async throws -> AsyncThrowingStream<LibraryMetadataOptions, Error>
    let accountChanges: AnyPublisher<Notification, Never>
    let untaggedCount: () async throws -> Int
    let describeError: (Error) -> String

    public init(shelfTitle: @escaping (String) -> String, shelves: @escaping () -> [LibraryShelf],
                metadataOptions: @escaping () async throws -> AsyncThrowingStream<LibraryMetadataOptions, Error>,
                accountChanges: AnyPublisher<Notification, Never>, untaggedCount: @escaping () async throws -> Int,
                describeError: @escaping (Error) -> String) {
        self.shelfTitle = shelfTitle; self.shelves = shelves; self.metadataOptions = metadataOptions
        self.accountChanges = accountChanges; self.untaggedCount = untaggedCount; self.describeError = describeError
    }
}
