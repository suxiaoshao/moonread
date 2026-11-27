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

  public let shelves: @Sendable () async throws -> [LibraryShelf]
  public let metadataOptions: @Sendable (String?) async throws -> LibraryMetadataOptions
  public let libraryEntries: @Sendable (LibraryLocation) async throws -> [LibraryEntry]
  public let aiLibraryEntries: @Sendable (LibraryLocation, LibrarySort) async throws -> [LibraryEntry]
  public let aiLibraryBooks: @Sendable (String) async throws -> [LibraryEntry]
  public let aiFoundBookPage: @Sendable (String, LibraryLocation?, BookSearchConfiguration, Int, Int) async throws -> BookSearchPage
  public let aiBookListEntries: @Sendable ([String], Bool) async throws -> AIBookListResolution
  public let aiBookListThumbnail: @Sendable (BookCoverAsset) async -> Data?
  public let aiBookID: @Sendable (String) async throws -> String
  public let aiMarks: @Sendable (String) async throws -> [String: [AnnotationCandidate]]
  /// Prepares and reads identity while the host's reading lease remains alive.
  public let preparedBookIdentity: @Sendable (SourceFile) async throws -> (id: String, formalSHA256: String?)
  public let snapshot: @Sendable (String) async throws -> ReadingSnapshot
  public let details: @Sendable (String) async throws -> BookDetails
  public let detailsByID: @Sendable (String) async throws -> BookDetails
  public let chapters: @Sendable (String) async throws -> ChapterOutline
  public let book: @Sendable (String) async throws -> BookInfo
  public let textContext: @Sendable (String, UInt64, UInt32, UInt32) async throws -> TextRange
  public let textRange: @Sendable (String, UInt64, UInt64) async throws -> TextRange
  public let paragraph: @Sendable (String, UInt64) async throws -> TextRange
  public let paragraphContaining: @Sendable (String, UInt64) async throws -> TextRange
  public let search: @Sendable (String, String, Bool, Bool, SearchRange?) async throws -> SearchJob
  public let searchBatch: @Sendable (SearchJob) async throws -> SearchBatch
  public let statisticsRead: @Sendable (Int64, Int64, String?) async throws -> StatisticsRead
  public let activitiesRead: @Sendable (Int64, Int64, String?) async throws -> ActivitiesRead

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
    preparedBookIdentity: @escaping @Sendable (SourceFile) async throws -> (id: String, formalSHA256: String?),
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
    self.preparedBookIdentity = preparedBookIdentity
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
