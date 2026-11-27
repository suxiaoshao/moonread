import Foundation
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings

/// Concrete data operations used by AI reading tools. The host constructs this
/// value around its existing AppDataService so tools share the app's data session.
public struct AIReadingAccess: Sendable {
  public typealias BookSearchPage = (books: [FilteredBookHit], count: Int, unknownCount: Int)
  public typealias StatisticsRead = (value: StatisticsOverview, compatibilityNotice: String?)
  public typealias ActivitiesRead = (value: [StatisticsTimelineRow], compatibilityNotice: String?)

  let shelves: @Sendable () async throws -> [LibraryShelf]
  let metadataOptions: @Sendable (String?) async throws -> LibraryMetadataOptions
  let libraryEntries: @Sendable (LibraryLocation) async throws -> [LibraryEntry]
  let aiLibraryEntries: @Sendable (LibraryLocation, LibrarySort) async throws -> [LibraryEntry]
  let aiLibraryBooks: @Sendable (String) async throws -> [LibraryEntry]
  let aiFoundBookPage: @Sendable (String, LibraryLocation?, BookSearchConfiguration, Int, Int) async throws -> BookSearchPage
  let aiBookListEntries: @Sendable ([String], Bool) async throws -> AIBookListResolution
  let aiBookListThumbnail: @Sendable (BookCoverAsset) async -> Data?
  let aiBookID: @Sendable (String) async throws -> String
  let aiMarks: @Sendable (String) async throws -> [String: [AnnotationCandidate]]
  /// Prepares and reads identity while the host's reading lease remains alive.
  let preparedBookSHA: @Sendable (SourceFile) async throws -> String?
  let snapshot: @Sendable (String) async throws -> ReadingSnapshot
  let details: @Sendable (String) async throws -> BookDetails
  let detailsByID: @Sendable (String) async throws -> BookDetails
  let chapters: @Sendable (String) async throws -> ChapterOutline
  let book: @Sendable (String) async throws -> BookInfo
  let textContext: @Sendable (String, UInt64, UInt32, UInt32) async throws -> TextRange
  let textRange: @Sendable (String, UInt64, UInt64) async throws -> TextRange
  let paragraph: @Sendable (String, UInt64) async throws -> TextRange
  let paragraphContaining: @Sendable (String, UInt64) async throws -> TextRange
  let search: @Sendable (String, String, Bool, Bool, SearchRange?) async throws -> SearchJob
  let searchBatch: @Sendable (SearchJob) async throws -> SearchBatch
  let statisticsRead: @Sendable (Int64, Int64, String?) async throws -> StatisticsRead
  let activitiesRead: @Sendable (Int64, Int64, String?) async throws -> ActivitiesRead

  public init(
    shelves: @escaping @Sendable () async throws -> [LibraryShelf],
    metadataOptions: @escaping @Sendable (String?) async throws -> LibraryMetadataOptions,
    libraryEntries: @escaping @Sendable (LibraryLocation) async throws -> [LibraryEntry],
    aiLibraryEntries: @escaping @Sendable (LibraryLocation, LibrarySort) async throws -> [LibraryEntry],
    aiLibraryBooks: @escaping @Sendable (String) async throws -> [LibraryEntry],
    aiFoundBookPage: @escaping @Sendable (String, LibraryLocation?, BookSearchConfiguration, Int, Int) async throws -> BookSearchPage,
    aiBookListEntries: @escaping @Sendable ([String], Bool) async throws -> AIBookListResolution,
    aiBookListThumbnail: @escaping @Sendable (BookCoverAsset) async -> Data?,
    aiBookID: @escaping @Sendable (String) async throws -> String,
    aiMarks: @escaping @Sendable (String) async throws -> [String: [AnnotationCandidate]],
    preparedBookSHA: @escaping @Sendable (SourceFile) async throws -> String?,
    snapshot: @escaping @Sendable (String) async throws -> ReadingSnapshot,
    details: @escaping @Sendable (String) async throws -> BookDetails,
    detailsByID: @escaping @Sendable (String) async throws -> BookDetails,
    chapters: @escaping @Sendable (String) async throws -> ChapterOutline,
    book: @escaping @Sendable (String) async throws -> BookInfo,
    textContext: @escaping @Sendable (String, UInt64, UInt32, UInt32) async throws -> TextRange,
    textRange: @escaping @Sendable (String, UInt64, UInt64) async throws -> TextRange,
    paragraph: @escaping @Sendable (String, UInt64) async throws -> TextRange,
    paragraphContaining: @escaping @Sendable (String, UInt64) async throws -> TextRange,
    search: @escaping @Sendable (String, String, Bool, Bool, SearchRange?) async throws -> SearchJob,
    searchBatch: @escaping @Sendable (SearchJob) async throws -> SearchBatch,
    statisticsRead: @escaping @Sendable (Int64, Int64, String?) async throws -> StatisticsRead,
    activitiesRead: @escaping @Sendable (Int64, Int64, String?) async throws -> ActivitiesRead
  ) {
    self.shelves = shelves
    self.metadataOptions = metadataOptions
    self.libraryEntries = libraryEntries
    self.aiLibraryEntries = aiLibraryEntries
    self.aiLibraryBooks = aiLibraryBooks
    self.aiFoundBookPage = aiFoundBookPage
    self.aiBookListEntries = aiBookListEntries
    self.aiBookListThumbnail = aiBookListThumbnail
    self.aiBookID = aiBookID
    self.aiMarks = aiMarks
    self.preparedBookSHA = preparedBookSHA
    self.snapshot = snapshot
    self.details = details
    self.detailsByID = detailsByID
    self.chapters = chapters
    self.book = book
    self.textContext = textContext
    self.textRange = textRange
    self.paragraph = paragraph
    self.paragraphContaining = paragraphContaining
    self.search = search
    self.searchBatch = searchBatch
    self.statisticsRead = statisticsRead
    self.activitiesRead = activitiesRead
  }
}
