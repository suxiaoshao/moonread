import Combine
import Foundation

/// File coordination asks iCloud / File Provider to materialize the original.
/// It runs off the service actor so shelf navigation and reading remain usable.
/// iCloud metadata reports real download progress; other providers may omit it.
final class SourceFileAccess: @unchecked Sendable {
    private let bookmark: Data
    private let path: String
    private let access = ProtectedFileAccess()
    private let lock = NSLock()
    private var cancelled = false
    private let progress: @Sendable (Double?) -> Void
    private var monitor: SourceDownloadProgress?

    init(bookmark: Data, path: String, progress: @escaping @Sendable (Double?) -> Void = { _ in }) {
        self.bookmark = bookmark; self.path = path; self.progress = progress
    }
    func cancel() {
        let monitor = lock.withLock { cancelled = true; return self.monitor }
        DispatchQueue.main.async { monitor?.stop() }
        access.cancel()
    }
    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                continuation.resume(with: Result {
                    try checkCancellation()
                    let source = try ProtectedFileAccess.Source(bookmark: bookmark, relativePath: path)
                    defer { withExtendedLifetime(source) {} }
                    let file = source.url
                    // Metadata queries need a run loop. Only start/stop runs on
                    // main; coordinated access continues on this worker queue.
                    let isCloud = (try? file.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
                    let monitor = DispatchQueue.main.sync { () -> SourceDownloadProgress? in
                        guard isCloud else { return nil }
                        let monitor = SourceDownloadProgress(url: file, report: progress)
                        let start = lock.withLock { () -> Bool in
                            guard !cancelled else { return false }
                            self.monitor = monitor; return true
                        }
                        guard start else { return nil }
                        monitor.start(); return monitor
                    }
                    defer {
                        lock.withLock { self.monitor = nil }
                        DispatchQueue.main.async { monitor?.stop() }
                    }
                    let result = Result {
                        try access.read(at: file) { url in
                            try checkCancellation()
                            // Opening a handle verifies accessibility without loading the novel.
                            let handle = try FileHandle(forReadingFrom: url)
                            try handle.close()
                        }
                    }
                    try checkCancellation()
                    try result.get()
                })
            }
        }
    }
}

@MainActor final class SourceDownloadProgress: NSObject {
    private let query = NSMetadataQuery()
    private var notifications: [AnyCancellable] = []
    private let url: URL
    private let report: @Sendable (Double?) -> Void
    private var lastFraction: Double?
    private var stopped = false

    init(url: URL, report: @escaping @Sendable (Double?) -> Void) {
        self.url = url; self.report = report
        super.init()
    }
    func start() {
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope, NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope]
        query.searchItems = [url]
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, url.lastPathComponent)
        query.notificationBatchingInterval = 0.1
        query.operationQueue = .main
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            notifications.append(MainActorNotifications.observe(name, object: query) { [weak self] in self?.changed() })
        }
        query.start()
    }
    func stop() {
        stopped = true
        query.stop()
        notifications.removeAll()
    }
    private func changed() {
        guard !stopped else { return }
        query.disableUpdates(); defer { query.enableUpdates() }
        guard let item = (query.results as? [NSMetadataItem])?.first(where: {
            ($0.value(forAttribute: NSMetadataItemURLKey) as? URL)?.standardizedFileURL == url.standardizedFileURL
        }) else { return }
        let fraction = Self.fraction(percent: item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber)
        if fraction != lastFraction { lastFraction = fraction; report(fraction) }
    }
    nonisolated static func fraction(percent: NSNumber?) -> Double? {
        guard let value = percent?.doubleValue, value.isFinite, (0...100).contains(value) else { return nil }
        return value / 100
    }
}
