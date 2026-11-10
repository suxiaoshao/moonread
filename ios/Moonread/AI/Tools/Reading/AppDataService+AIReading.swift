import Foundation

enum AIPreparationEntry {
  case preparing(token: UUID, task: Task<Void, Never>, waiters: Int)
  case completed(token: UUID, result: Result<ReadingLease, Error>, waiters: Int)

  var waiters: Int {
    switch self {
    case .preparing(_, _, let count), .completed(_, _, let count): count
    }
  }
  func withWaiters(_ count: Int) -> Self {
    switch self {
    case .preparing(let token, let task, _): .preparing(token: token, task: task, waiters: count)
    case .completed(let token, let result, _): .completed(token: token, result: result, waiters: count)
    }
  }
}

extension AppDataService {
  func aiLibraryEntries(_ location: LibraryLocation, sort: LibrarySort) async throws
    -> [LibraryEntry]
  {
    let query = try await catalogueQuery(location, recursive: false)
    let metadata = try query.librarySearchCandidates(scope: catalogueScope(location, recursive: false), booksOnly: false)
    let byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.entry.id, $0.resolvedMetadata) })
    try await requireAIMetadataReadable(location, recursive: false)
    return try query.libraryEntries(shelfId: location.shelfID, parentPath: location.path, sort: sort).map { entry in
      entry.withMetadata(byID[entry.id] ?? nil)
    }
  }
  func aiLibraryBooks(_ shelf: String) async throws -> [LibraryEntry] {
    let location = LibraryLocation(shelfID: shelf)
    let candidates = try await catalogueQuery(location, recursive: true).librarySearchCandidates(scope: catalogueScope(location, recursive: true), booksOnly: true)
    try await requireAIMetadataReadable(location, recursive: true)
    return candidates.map { candidate in
      candidate.entry.withMetadata(candidate.resolvedMetadata)
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
    if let existing = aiPreparations[file.id] {
      aiPreparations[file.id] = existing.withWaiters(existing.waiters + 1)
    } else {
      let token = UUID()
      let task = Task {
        let result: Result<ReadingLease, Error>
        do { result = .success(try await aiPrepareUnshared(file)) }
        catch { result = .failure(error) }
        guard case .preparing(let activeToken, _, let waiters) = aiPreparations[file.id],
              activeToken == token else { return }
        aiPreparations[file.id] = .completed(token: token, result: result, waiters: waiters)
      }
      aiPreparations[file.id] = .preparing(token: token, task: task, waiters: 1)
    }
    defer { releaseAIPreparation(file.id) }
    while true {
      try Task.checkCancellation()
      if case .completed(_, let result, _) = aiPreparations[file.id] { return try result.get() }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func releaseAIPreparation(_ fileID: String) {
    guard let entry = aiPreparations[fileID] else { return }
    if entry.waiters > 1 {
      aiPreparations[fileID] = entry.withWaiters(entry.waiters - 1)
    } else {
      aiPreparations[fileID] = nil
      if case .preparing(_, let task, _) = entry { task.cancel() }
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
