import MoonreadAI
import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings

extension AppDataService {
  nonisolated var aiProposalHost: AIProposalHost {
    AIProposalHost(
      reading: aiReadingAccess,
      fileSnapshot: { try await self.aiFileSnapshot($0) },
      directoryState: { location in
        let state = try await self.aiDirectoryState(location)
        return (snapshot: state.snapshot, names: state.names)
      },
      createFolder: { try await self.aiCreateLibraryFolder(at: $0, name: $1, id: $2) },
      moveItem: { await self.aiMoveLibraryItem($0, to: $1, name: $2, check: $3) },
      renameFile: { try await self.renameLibraryItem($0, name: $1, replace: false, expected: $2) },
      saveMetadata: { try await self.saveMetadata(base: $0, edited: $1) },
      coverBytes: { try await self.coverBytes($0) },
      makeCover: { try await self.makeCover($0) },
      discardCoverDraft: { await self.discardCoverDraft($0) },
      chapterTitle: { try await self.chapter(bookID: $0, offset: $1)?.title },
      annotationAdmission: { try await self.annotationActionAdmission() },
      ensureBookmark: { try await self.ensureBookmark($0, at: $1, admission: $2) },
      prepareUserAnnotation: { try await self.prepareUserAnnotation($0, start: $1, end: $2, admission: $3) },
      saveUserNote: { try await self.saveUserNote($0, text: $1) },
      parseCoverPage: AICoverPageParser.extract
    )
  }
}

@MainActor
extension AIProposalRegistry {
  convenience init(reader: AppDataService = .shared) {
    self.init(host: reader.aiProposalHost)
  }
}
