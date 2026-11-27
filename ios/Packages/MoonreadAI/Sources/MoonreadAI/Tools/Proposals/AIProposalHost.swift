import Foundation
import MoonreadCoreBindings
import MoonreadData
import MoonreadDataTypes

/// App-owned capabilities used by proposal review and application. The AI package
/// owns the proposal policy and state; the App binds these calls to its shared data service.
public struct AIProposalHost {
  public var reading: AIReadingAccess
  public var fileSnapshot: @MainActor (LibraryLocation) async throws -> AIFileSnapshot
  public var directoryState: @MainActor (LibraryLocation) async throws -> (snapshot: AIFileSnapshot, names: Set<String>)
  public var createFolder: @MainActor (AIFileSnapshot, String, String) async throws -> AIFileExecutionResult
  public var moveItem: @MainActor (LibraryEntry, LibraryLocation, String, AIFileMoveCheck) async -> AIFileExecutionResult
  public var renameFile: @MainActor (LibraryEntry, String, AIFileSnapshot) async throws -> Void
  public var saveMetadata: @MainActor (BookMetadata, BookMetadata) async throws -> Void
  public var coverBytes: @MainActor (BookCoverAsset) async throws -> Data
  public var makeCover: @MainActor (Data) async throws -> BookCoverAsset
  public var discardCoverDraft: @MainActor (BookCoverAsset) async -> Void
  public var annotationAdmission: @MainActor () async throws -> DataSessionLease
  public var ensureBookmark: @MainActor (String, UInt64, DataSessionLease) async throws -> ReaderMark
  public var prepareUserAnnotation: @MainActor (String, UInt64, UInt64, DataSessionLease) async throws -> AnnotationEdit
  public var saveUserNote: @MainActor (AnnotationEdit, String) async throws -> ReaderMark
  public var parseCoverPage: @Sendable (Data, String, String?, String?) -> [String]

  public init(
    reading: AIReadingAccess,
    fileSnapshot: @escaping @MainActor (LibraryLocation) async throws -> AIFileSnapshot,
    directoryState: @escaping @MainActor (LibraryLocation) async throws -> (snapshot: AIFileSnapshot, names: Set<String>),
    createFolder: @escaping @MainActor (AIFileSnapshot, String, String) async throws -> AIFileExecutionResult,
    moveItem: @escaping @MainActor (LibraryEntry, LibraryLocation, String, AIFileMoveCheck) async -> AIFileExecutionResult,
    renameFile: @escaping @MainActor (LibraryEntry, String, AIFileSnapshot) async throws -> Void,
    saveMetadata: @escaping @MainActor (BookMetadata, BookMetadata) async throws -> Void,
    coverBytes: @escaping @MainActor (BookCoverAsset) async throws -> Data,
    makeCover: @escaping @MainActor (Data) async throws -> BookCoverAsset,
    discardCoverDraft: @escaping @MainActor (BookCoverAsset) async -> Void,
    annotationAdmission: @escaping @MainActor () async throws -> DataSessionLease,
    ensureBookmark: @escaping @MainActor (String, UInt64, DataSessionLease) async throws -> ReaderMark,
    prepareUserAnnotation: @escaping @MainActor (String, UInt64, UInt64, DataSessionLease) async throws -> AnnotationEdit,
    saveUserNote: @escaping @MainActor (AnnotationEdit, String) async throws -> ReaderMark,
    parseCoverPage: @escaping @Sendable (Data, String, String?, String?) -> [String]
  ) {
    self.reading = reading
    self.fileSnapshot = fileSnapshot
    self.directoryState = directoryState
    self.createFolder = createFolder
    self.moveItem = moveItem
    self.renameFile = renameFile
    self.saveMetadata = saveMetadata
    self.coverBytes = coverBytes
    self.makeCover = makeCover
    self.discardCoverDraft = discardCoverDraft
    self.annotationAdmission = annotationAdmission
    self.ensureBookmark = ensureBookmark
    self.prepareUserAnnotation = prepareUserAnnotation
    self.saveUserNote = saveUserNote
    self.parseCoverPage = parseCoverPage
  }
}
