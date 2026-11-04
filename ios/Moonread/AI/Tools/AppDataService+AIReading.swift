import Foundation

extension AppDataService {
  func aiLibraryEntries(_ location: LibraryLocation, sort: LibrarySort) async throws
    -> [LibraryEntry]
  {
    let query = try await catalogueQuery(location, recursive: false)
    let metadata = try query.librarySearchCandidates(scope: catalogueScope(location, recursive: false), booksOnly: false)
    let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.entry.id, $0.resolvedMetadata) })
    try await requireAIMetadataReadable(location, recursive: false)
    return try query.libraryEntries(shelfId: location.shelfID, parentPath: location.path, sort: sort).map { entry in
      var entry = entry; entry.metadata = byID[entry.id] ?? nil; return entry
    }
  }
  func aiLibraryBooks(_ shelf: String) async throws -> [LibraryEntry] {
    let location = LibraryLocation(shelfID: shelf)
    let candidates = try await catalogueQuery(location, recursive: true).librarySearchCandidates(scope: catalogueScope(location, recursive: true), booksOnly: true)
    try await requireAIMetadataReadable(location, recursive: true)
    return candidates.map { candidate in
      var entry = candidate.entry; entry.metadata = candidate.resolvedMetadata; return entry
    }
  }
  func aiBookID(sha: String) throws -> String {
    try textCore().textIdForSha(sha: sha)
  }
  func aiMarks(sha: String) async throws -> [String: [AnnotationCandidate]] {
    try await userStore().candidates(key: sha)
  }
  func aiSearchBatch(_ job: SearchJob) throws -> SearchBatch { try job.nextBatch() }
  /// Uses the same import lease as readers, without setting preferred source/position
  /// or starting a ReadingActivityRecorder. Cancellation releases only this waiter.
  func aiPrepare(_ file: SourceFile) async throws -> ReadingLease {
    aiPreparationWaiters[file.id, default: 0] += 1
    if aiPreparationTasks[file.id] == nil {
      let token = UUID()
      aiPreparationTokens[file.id] = token
      aiPreparationTasks[file.id] = Task {
        do {
          let lease = try await aiPrepareUnshared(file)
          if aiPreparationTokens[file.id] == token {
            aiPreparationResults[file.id] = .success(lease)
          }
        } catch {
          if aiPreparationTokens[file.id] == token {
            aiPreparationResults[file.id] = .failure(error)
          }
        }
      }
    }
    defer {
      aiPreparationWaiters[file.id, default: 1] -= 1
      if aiPreparationWaiters[file.id] == 0 {
        aiPreparationTasks.removeValue(forKey: file.id)?.cancel()
        aiPreparationResults[file.id] = nil
        aiPreparationWaiters[file.id] = nil
        aiPreparationTokens[file.id] = nil
      }
    }
    while true {
      try Task.checkCancellation()
      if let result = aiPreparationResults[file.id] { return try result.get() }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
  private func aiPrepareUnshared(_ file: SourceFile) async throws -> ReadingLease {
    try await prepareSourceFile(file)
    let lease = try await openSourceFile(file, trackReadingSource: false)
    while true {
      try Task.checkCancellation()
      let state = try await snapshot(lease.id)
      if state.phase == .complete { return lease }
      if state.phase == .failed || state.phase == .paused { throw AIToolError("needs_preparation") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
