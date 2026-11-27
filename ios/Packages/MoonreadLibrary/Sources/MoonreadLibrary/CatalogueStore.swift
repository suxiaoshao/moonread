import Combine
import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import MoonreadDesign
import Observation

public struct CatalogueTagSection: Identifiable, Sendable {
    public let kind: LibraryTagGroupKind
    public let tag: String
    public let fileIDs: [String]

    public var id: String {
        switch kind {
        case .tag: "tag:" + tag
        case .untagged: "untagged"
        case .unindexed: "unindexed"
        }
    }
}

/// Only the grouping in use is assembled. Tag sections refer to one
/// physical-file card map; counting books never counts memberships.
public struct CatalogueSnapshot: Sendable {
    public enum Content: Sendable {
        case names([LibraryNameGroup])
        case tags([CatalogueTagSection], cards: [String: LibraryEntry])
    }

    public let shelfID: String
    public let content: Content
    public let bookCount: UInt64

    public init(_ ordered: CatalogueRead.Ordered, shelfID: String) throws {
        self.shelfID = shelfID
        bookCount = UInt64(ordered.entries.count)
        if let tags = ordered.groups {
            let sections = try tags.shelfTagGroups.map { group in
                try CatalogueTagSection(kind: CatalogueRead.sectionKind(group), tag: group.tag, fileIDs: group.fileIDs)
            }
            content = .tags(sections, cards: Dictionary(uniqueKeysWithValues: ordered.entries.map { ($0.id,$0) }))
        } else {
            content = .names(LibraryNameGroup.group(ordered.entries))
        }
    }

    public var grouping: LibraryGrouping {
        if case .tags = content { return .tags }
        return .name
    }
}

/// Alphabet grouping is a localized platform presentation of the Rust file index.
/// Normalize Han names to pinyin so the visible letters and ordering agree.
public struct LibraryNameGroup: Identifiable, Sendable {
    public let id: String
    public let entries: [LibraryEntry]

    public static func key(_ name: String) -> String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return (title.applyingTransform(.mandarinToLatin, reverse: false) ?? title)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
    }
    public static func letter(_ key: String) -> String {
        guard let first = key.first, ("A"..."Z").contains(String(first)) else { return "#" }
        return String(first)
    }
    public static func group(_ entries: [LibraryEntry]) -> [Self] {
        let keyed = entries.map { (entry: $0, key: key($0.title)) }
        let groups = Dictionary(grouping: keyed) { letter($0.key) }
        return groups.keys.sorted { $0 == "#" ? false : $1 == "#" ? true : $0 < $1 }.map { letter in
            let values = groups[letter, default: []].sorted {
                let order = $0.key.localizedStandardCompare($1.key)
                if order != .orderedSame { return order == .orderedAscending }
                return $0.entry.id < $1.entry.id
            }
            return Self(id: letter, entries: values.map(\.entry))
        }
    }
}

@MainActor @Observable
public final class CatalogueStore {
    public typealias Updates = @Sendable (String, LibraryGrouping) async throws -> AsyncThrowingStream<CatalogueSnapshot, Error>
    public private(set) var snapshot: CatalogueSnapshot?
    public private(set) var failed = false
    public private(set) var requestRevision = 0
    public let loading = LoadingState()

    @ObservationIgnored private let updates: Updates
    @ObservationIgnored private let beforeRead: @Sendable () async throws -> Void
    @ObservationIgnored private var accountChange: AnyCancellable?

    public init(updates: @escaping Updates, beforeRead: @escaping @Sendable () async throws -> Void = {},
                observeAccount: (@escaping @MainActor @Sendable () -> Void) -> AnyCancellable? = { _ in nil }) {
        self.updates = updates
        self.beforeRead = beforeRead
        accountChange = observeAccount { [weak self] in
            guard let self else { return }
            snapshot = nil
            failed = false
            requestRevision &+= 1
        }
    }

    public func retryIfFailed() {
        if failed { requestRevision &+= 1 }
    }

    public func observe(shelfID: String, grouping: LibraryGrouping, didFail: (Error) -> Void) async {
        let revision = requestRevision
        let request = loading.begin(); defer { loading.finish(request) }
        failed = false
        do {
            try await beforeRead()
            let stream = try await updates(shelfID, grouping)
            for try await value in stream {
                guard !Task.isCancelled, requestRevision == revision else { return }
                snapshot = value
                loading.finish(request)
            }
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestRevision == revision else { return }
            failed = true
            didFail(error)
        }
    }
}
