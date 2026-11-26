import MoonreadReader
import MoonreadLibrary
import MoonreadDesign
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import Foundation
import SwiftUI
import UIKit

extension AppDataService {
    func noteCandidates(_ id: String) async throws -> NoteCandidates { try await annotationSnapshot(id) }
    func noteDocument(_ id: String, ids: Set<String>? = nil) async throws -> NoteDocument {
        let snapshot = try await noteCandidates(id)
        let groups = try snapshot.checked(ids)
        let info = try await book(id)
        let details = try? await details(bookID: id)
        let locations = try await noteLocationDetails(id, offsets: groups.values.flatMap { $0.compactMap { $0.content?.start } })
        var records: [NoteDocument.Record] = []
        for (markID, heads) in groups {
            let live = heads.filter { $0.content != nil }.sorted { $0.id < $1.id }
            for (index, head) in live.enumerated() {
                guard let c = head.content else { continue }
                let mark = ReaderMark(id: markID, kind: head.bookmark ? .bookmark : .annotation, startUtf8: c.start, endUtf8: c.end, excerpt: c.excerpt, note: c.note, created: head.created)
                let (chapter, percent) = locations[c.start] ?? (nil,nil)
                records.append(.init(id: head.id, mark: mark, chapter: chapter?.title, chapterStart: chapter?.startUtf8, percentage: percent, version: live.count > 1 ? index + 1 : nil, deletionVersion: heads.contains { $0.content == nil }))
            }
        }
        records.sort { ($0.mark.startUtf8, $0.mark.endUtf8, $0.mark.id, $0.id) < ($1.mark.startUtf8, $1.mark.endUtf8, $1.mark.id, $1.id) }
        let author = details?.metadata.author
        return NoteDocument(title: details?.book?.title ?? info.title, author: author?.isEmpty == false ? author : nil, records: records)
    }
    func shareExcerpt(_ id: String, range: TextRange) async throws -> String {
        let info = try await book(id)
        let details = try? await details(bookID: id)
        let (chapter, percent) = try await noteLocationDetails(id, offsets: [range.startUtf8])[range.startUtf8] ?? (nil,nil)
        let document = NoteDocument(title: details?.book?.title ?? info.title,
            author: details?.metadata.author.isEmpty == false ? details?.metadata.author : nil, records: [])
        let mark = ReaderMark(id: "excerpt", kind: .annotation, startUtf8: range.startUtf8,
            endUtf8: range.endUtf8, excerpt: range.text, note: "", created: 0)
        return document.excerpt(.init(id: "excerpt", mark: mark, chapter: chapter?.title, percentage: percent,
            version: nil, deletionVersion: false))
    }
    func noteLocations(_ id: String, marks: [ReaderMark]) async throws -> [String: String] {
        let locations = try await noteLocationDetails(id, offsets: marks.map(\.startUtf8))
        var values: [String: String] = [:]
        for mark in marks {
            let (chapter, percent) = locations[mark.startUtf8] ?? (nil,nil)
            values[mark.id] = [chapter?.title, percent.map { String(format: "%.0f%%", $0) }].compactMap { $0 }.joined(separator: " · ")
        }
        return values
    }
    func deleteNoteSelection(_ id: String, expected: NoteCandidates, ids: Set<String>) async throws {
        try await deleteSelectedAnnotations(id, expected: expected, ids: ids)
    }

}
