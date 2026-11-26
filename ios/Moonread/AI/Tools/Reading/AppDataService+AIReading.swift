import MoonreadData
import MoonreadDataTypes
import MoonreadCoreBindings
import MoonreadAI
import Foundation

enum AICoverPageParser {
  static func extract(_ data: Data, _ responseURL: String, _ charset: String?, _ title: String?) -> [String] {
    func withBytes<T>(_ data: Data?, _ body: (MoonreadCoverBytes) -> T) -> T {
      guard let data else { return body(.init(data: nil, len: 0)) }
      return data.withUnsafeBytes { bytes in
        body(.init(data: bytes.bindMemory(to: UInt8.self).baseAddress, len: bytes.count))
      }
    }
    let result = withBytes(data) { body in
      withBytes(Data(responseURL.utf8)) { url in
        withBytes(charset.map { Data($0.utf8) }) { encoding in
          withBytes(title.map { Data($0.utf8) }) { book in
            moonread_ai_cover_extract(body, url, encoding, book)
          }
        }
      }
    }
    defer { moonread_ai_cover_release(result) }
    guard let bytes = result.data else { return [] }
    return (try? JSONDecoder().decode([String].self, from: Data(bytes: bytes, count: result.len))) ?? []
  }
}

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
    let scope = catalogueScope(location, recursive: false)
    return try await fixedReaderRead { try $0.aiCatalogue(scope, folder: location, sort: sort) }
  }
  func aiLibraryBooks(_ shelf: String) async throws -> [LibraryEntry] {
    let scope = catalogueScope(.init(shelfID: shelf), recursive: true)
    return try await fixedReaderRead { try $0.aiCatalogue(scope, folder: nil, sort: .name) }
  }
  func aiBookID(sha: String) throws -> String {
    try indexStore().textIdForSha(sha: sha)
  }
  func aiMarks(sha: String) async throws -> [String: [AnnotationCandidate]] {
    _ = try parseSha256(value: sha)
    return try await fixedReaderRead { index in
      try index.session.readUsers(index.lease) { db in
        try AnnotationRows.snapshot(db, key: sha, reducing: false, settled: true).groups
      }
    }
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
      if state.preparation.isComplete { return lease }
      if state.preparation.isFailed || state.preparation.isPaused { throw AIToolError("needs_preparation") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
