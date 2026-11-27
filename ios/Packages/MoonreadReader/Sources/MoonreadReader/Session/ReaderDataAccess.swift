import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes
import UIKit

/// The actor serving the active reader lease. The host supplies the existing
/// coordinator for file preparation, account-scoped reads and saves.
public protocol ReaderDataAccess: Actor {
    func releaseReading(_ id: String)
    func openReading(_ id: String, diagnostic: ReaderOpenTrace?) throws -> ReadingLease
    func openSourceFile(_ file: SourceFile, diagnostic: ReaderOpenTrace?, progress: (@Sendable (Double?) -> Void)?) async throws -> ReadingLease
    func restartImport(_ id: String, encoding: String?) async throws -> ReadingLease
    func resumeImport(_ id: String) throws
    func waitForImportFinish(_ id: String) async throws
    func readingDecoding(_ id: String) -> String?
    func readingChangeRevision(_ id: String) -> UInt64
    func waitForChange(_ id: String, after: UInt64, timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) async throws
    func readingCompatibilityNotice(_ id: String) async throws -> String?
    func readingResumeContext(_ id: String, currentOffset: UInt64?) async throws -> ReadingResumeContext

    func frame(_ id: String, offset: UInt64) async throws -> ReadingFrame
    func extensionFrame(_ id: String, cursor: UInt64, direction: ReadingDirection, retaining: SourceSpan?) async throws -> ReadingFrame
    func openingFrame(_ id: String, offset: UInt64?, attempt: UUID?, diagnostic: ReaderOpenTrace?) async throws -> (ReadingSnapshot, ReadingFrame?)
    func textRange(_ id: String, start: UInt64, end: UInt64) throws -> TextRange
    func displayTextRange(_ id: String, start: UInt64, end: UInt64, indent: ReadingIndent) async throws -> TextRange
    func paragraph(_ id: String, at offset: UInt64) throws -> TextRange
    func location(_ id: String, percentage: Double) async throws -> ReadingLocation
    func search(_ id: String, query: String, regex: Bool, caseSensitive: Bool, range: SearchRange?) async throws -> SearchJob

    func chapter(bookID: String, offset: UInt64) async throws -> ChapterInfo?
    func adjacentChapter(_ id: String, offset: UInt64, forward: Bool) async throws -> ChapterInfo?
    func rebuildChapters(_ id: String) throws -> ChapterRebuild
    func advanceRebuild(_ job: ChapterRebuild) throws -> ChapterRebuildProgress
    func rebuildPreview(_ job: ChapterRebuild) throws -> [ChapterInfo]
    func applyRebuild(_ job: ChapterRebuild) throws
    func chapterStructure(_ id: String) async throws -> ChapterOutline
    func observeChapterCoverage(_ id: String, receive: @escaping @MainActor @Sendable (Result<ChapterOutline?, Error>) -> Void) async throws
    func correctChapter(_ id: String, offset: UInt64, title: String, level: UInt32, excluded: Bool) async throws
    func restoreChapterCorrections(_ id: String) async throws

    func annotationWindow(_ id: String, start: UInt64, end: UInt64) async throws -> ReaderAnnotationWindow
    func annotationEditingBundle(_ edit: AnnotationEdit) async throws -> [String: [AnnotationCandidate]]
    func prepareAnnotation(_ id: String, start: UInt64, end: UInt64, admission: DataSessionLease?) async throws -> AnnotationEdit
    func resolveAnnotation(_ edit: AnnotationEdit, expected: [String: [AnnotationCandidate]], content: AnnotationContent?) async throws
    func saveNote(_ edit: AnnotationEdit, text: String) async throws -> ReaderMark
    func mark(_ id: String) async throws -> ReaderMark
    func marks(_ id: String, kind: MarkKind, offset: UInt32, snapshot: NoteCandidates?) async throws -> MarkPage
    func noteCandidates(_ id: String) async throws -> NoteCandidates
    func noteLocations(_ id: String, marks: [ReaderMark]) async throws -> [String: String]
    func noteDocument(_ id: String, ids: Set<String>?) async throws -> NoteDocument
    func deleteMarks(_ ids: [String], deleted: Bool, expected: NoteCandidates?) async throws
    func deleteNoteSelection(_ id: String, expected: NoteCandidates, ids: Set<String>) async throws
    func bookmarkPositions(_ id: String, start: UInt64, end: UInt64) async throws -> [UInt64]
    func toggleBookmark(_ id: String, at offset: UInt64, admission: DataSessionLease?) async throws -> Bool
    func hasBookmark(_ id: String, at offset: UInt64) async throws -> Bool
    func shareExcerpt(_ id: String, range: TextRange) async throws -> String

    func details(bookID: String) async throws -> BookDetails
    func coverImage(_ cover: BookCoverAsset, pixels: Int, exactSize: Bool) async throws -> UIImage?
    func recordBookOpened(_ id: String, at milliseconds: Int64, admission: DataSessionLease?) async throws
    func systemReadingBegan(_ bookID: String)
    func writePosition(_ id: String, offset: UInt64, at: Int64?, expectedConfiguration: UUID?, admission: DataSessionLease?) async throws
    func savePosition(bookID: String, offset: UInt64, at: Int64?, admission: DataSessionLease?) async throws
    func statisticsPreferences() -> StatisticsPreferences
    func readingSegmentAuthor(_ lease: ReadingLease) async throws -> ReadingSegmentAuthor
    func saveReadingSegments(_ batch: ReadingSegmentBatch) async throws
}

extension ReaderDataAccess {
    func waitForChange(_ id: String, after: UInt64, timeout: Duration) async throws {
        try await waitForChange(id, after: after, timeout: timeout) { try await Task.sleep(for: $0) }
    }

    func savePosition(bookID: String, offset: UInt64, admission: DataSessionLease?) async throws {
        try await savePosition(bookID: bookID, offset: offset, at: nil, admission: admission)
    }

    func writePosition(_ id: String, offset: UInt64, expectedConfiguration: UUID?, admission: DataSessionLease?) async throws {
        try await writePosition(id, offset: offset, at: nil, expectedConfiguration: expectedConfiguration, admission: admission)
    }

    func correctChapter(_ id: String, offset: UInt64, title: String, level: UInt32) async throws {
        try await correctChapter(id, offset: offset, title: title, level: level, excluded: false)
    }
}
