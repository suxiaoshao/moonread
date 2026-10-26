import Foundation

/// Book matching and result composition. Database scope/identity and natural
/// ordering come from Rust; deliberately different entry contracts stay named.
enum LibraryQueryRules {
    struct SearchSpec: Sendable {
        enum Profile: Sendable, Equatable { case library, ai }
        var profile: Profile
        var query = ""
        var author: String?
        var tags: [String] = []
        var status: String?
        var nameOrder = false
    }
    static func selectionMatches(_ title: String, query: String) -> Bool {
        query.isEmpty || title.localizedStandardContains(query)
    }
    static func filterSuggestions(_ values: [String], query: String) -> [String] {
        values.filter { selectionMatches($0, query: query) }
    }
    static func statusName(_ status: BookReadingStatus) -> String {
        switch status {
        case .unread: "unread"
        case .reading: "reading"
        case .finished: "finished"
        case .paused: "paused"
        case .other: "other"
        }
    }
    // Rust str::trim's Unicode White_Space set (Foundation additionally trims
    // U+200B). Never use localized matching for the library's literal contract.
    private static func rustWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 9...13, 32, 133, 160, 5760, 8192...8202, 8232, 8233, 8239, 8287, 12288: true
        default: false
        }
    }
    private static func literalQuery(_ value: String) -> String {
        let scalars = value.unicodeScalars.drop(while: rustWhitespace).reversed().drop(while: rustWhitespace).reversed()
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
    private static func literalTitle(_ entry: LibraryEntry) -> String {
        // URL path access can normalize a filename to NFD. The old Rust Path
        // stem search used the exact indexed bytes, including NFC/NFD differences.
        let bytes = Array(entry.name.utf8)
        guard !entry.directory, let dot = bytes.lastIndex(of: 46), dot > 0 else { return entry.name.lowercased() }
        return String(decoding: bytes[..<dot], as: UTF8.self).lowercased()
    }
    private static func literalContains(_ value: String, _ query: String) -> Bool {
        Data(value.utf8).range(of: Data(query.utf8)) != nil
    }
    static func filterAndRank(_ candidates: [LibrarySearchCandidate], spec: SearchSpec) -> [LibraryEntry] {
        let literal = spec.profile == .library
        let query = literal ? literalQuery(spec.query) : spec.query
        if literal && query.isEmpty && spec.author == nil && spec.tags.isEmpty { return [] }
        let ranked = candidates.compactMap { candidate -> (LibrarySearchCandidate, LibraryEntry, Int)? in
            var row = candidate.entry
            if !literal { row.metadata = candidate.resolvedMetadata }
            let metadata = row.metadata
            if literal {
                if spec.author != nil || !spec.tags.isEmpty {
                    guard !row.directory, spec.author.map({ metadata?.author.utf8.elementsEqual($0.utf8) == true }) ?? true,
                          spec.tags.allSatisfy({ tag in metadata?.tags.contains(where: { $0.utf8.elementsEqual(tag.utf8) }) == true }) else { return nil }
                }
                let title = literalTitle(row)
                let rank: Int
                if query.isEmpty || title.utf8.starts(with: query.utf8) { rank = 0 }
                else if literalContains(title, query) { rank = 1 }
                else if !row.directory, metadata.map({ literalContains($0.author.lowercased(), query) }) == true { rank = 2 }
                else { return nil }
                return (candidate, row, rank)
            }
            guard !row.directory,
                  query.isEmpty || [row.title, metadata?.author ?? "", metadata?.synopsis ?? ""].contains(where: { $0.localizedCaseInsensitiveContains(query) }),
                  spec.author.map({ $0.isEmpty || metadata?.author.localizedCaseInsensitiveContains($0) == true }) ?? true,
                  spec.tags.allSatisfy({ metadata?.tags.contains($0) == true }),
                  spec.status.map({ status in metadata.map { statusName($0.status) == status } ?? false }) ?? true else { return nil }
            return (candidate, row, 0)
        }
        return ranked.sorted { a, b in
            if literal {
                if a.1.directory != b.1.directory { return !a.1.directory }
                if a.2 != b.2 { return a.2 < b.2 }
                if a.1.lastRead != b.1.lastRead { return a.1.lastRead > b.1.lastRead }
                return a.0.naturalOrderOrdinal < b.0.naturalOrderOrdinal
            }
            if spec.nameOrder { return (a.1.name, a.1.id) < (b.1.name, b.1.id) }
            return a.1.lastRead == b.1.lastRead ? a.1.id < b.1.id : a.1.lastRead > b.1.lastRead
        }.map { $0.1 }
    }
}

/// A superseded directory response cannot publish into a new input scope.
/// SwiftUI cancels its task; the token also guards services which finish after cancellation.
@MainActor
final class LibraryCatalogueRequest {
    struct Input: Hashable {
        let location: LibraryLocation
        let libraryRevision: Int
        let readingRevision: UInt64
    }
    private var generation = UUID()
    func read(_ fetch: () async throws -> [LibraryEntry]) async throws -> [LibraryEntry]? {
        let request = UUID(); generation = request
        do {
            let result = try await fetch()
            guard generation == request else { return nil }
            try Task.checkCancellation()
            return result
        } catch {
            guard generation == request else { return nil }
            throw error
        }
    }
}
