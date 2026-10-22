import Foundation
import ImageIO

/// Recomputed for every redirect; a source page's query never accompanies a cross-origin image request.
final class AICoverRefererDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let page: URL
    init(page: URL) { self.page = page }
    func request(_ request: URLRequest) -> URLRequest {
        var request = request
        request.setValue(nil, forHTTPHeaderField: "Referer")
        guard let target = request.url, var source = URLComponents(url: page, resolvingAgainstBaseURL: false),
              let destination = URLComponents(url: target, resolvingAgainstBaseURL: false),
              !(source.scheme?.lowercased() == "https" && destination.scheme?.lowercased() == "http") else { return request }
        func port(_ c: URLComponents) -> Int? { c.port ?? (c.scheme?.lowercased() == "https" ? 443 : 80) }
        let sameOrigin = source.scheme?.lowercased() == destination.scheme?.lowercased()
            && source.host?.lowercased() == destination.host?.lowercased() && port(source) == port(destination)
        source.user = nil; source.password = nil; source.fragment = nil
        if !sameOrigin { source.path = ""; source.query = nil }
        request.setValue(source.url?.absoluteString, forHTTPHeaderField: "Referer")
        return request
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request(newRequest))
    }
}

fileprivate enum AICoverFetchError: Error { case tooLarge, status(Int), invalidResponse }
fileprivate struct AICoverDownloadedResponse: Sendable { let bytes: Data; let http: HTTPURLResponse }

/// Count delivered chunks before retaining them; neither declared nor streamed bodies may exceed the cap.
private final class AICoverDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let continuation: CheckedContinuation<AICoverDownloadedResponse, Error>
        let referer: AICoverRefererDelegate?
        var http: HTTPURLResponse?
        var bytes = Data()
        var failure: Error?
        init(_ continuation: CheckedContinuation<AICoverDownloadedResponse, Error>, referer: AICoverRefererDelegate?) {
            self.continuation = continuation; self.referer = referer
        }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:] // All pending state is protected by lock.
    let maximumBytes: Int
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    func register(_ task: URLSessionDataTask, referer: AICoverRefererDelegate?, continuation: CheckedContinuation<AICoverDownloadedResponse, Error>) {
        lock.withLock { pending[task.taskIdentifier] = Pending(continuation, referer: referer) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let allow = lock.withLock {
            guard let state = pending[dataTask.taskIdentifier] else { return false }
            if response.expectedContentLength > Int64(maximumBytes) { state.failure = AICoverFetchError.tooLarge; return false }
            guard let http = response as? HTTPURLResponse else { state.failure = AICoverFetchError.invalidResponse; return false }
            guard (200..<300).contains(http.statusCode) else { state.failure = AICoverFetchError.status(http.statusCode); return false }
            state.http = http
            return true
        }
        completionHandler(allow ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            guard let state = pending[dataTask.taskIdentifier], state.failure == nil else { return false }
            guard data.count <= maximumBytes - state.bytes.count else { state.failure = AICoverFetchError.tooLarge; return true }
            state.bytes.append(data)
            return false
        }
        if oversized { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let state = lock.withLock({ pending.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let error = state.failure ?? error { state.continuation.resume(throwing: error) }
        else if let http = state.http { state.continuation.resume(returning: .init(bytes: state.bytes, http: http)) }
        else { state.continuation.resume(throwing: AICoverFetchError.invalidResponse) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let referer = lock.withLock { pending[task.taskIdentifier]?.referer }
        completionHandler(referer?.request(newRequest) ?? newRequest)
    }
}

/// Cancellation may precede task registration; remember it rather than losing the cancellation.
private final class AICoverDownloadControl: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    func start(_ task: URLSessionDataTask) {
        let cancel = lock.withLock { self.task = task; return cancelled }
        if cancel { task.cancel() } else { task.resume() }
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }
}

struct AICoverFetchReport: Sendable {
    struct Source: Sendable {
        let url: String
        var extractedURLs: [String] = []
        var candidates = 0
        var failures: [String] = []
    }
    var candidates: [AICoverProposal] = []
    var sources: [Source] = []
}

/// Serial source-to-image acquisition. Authorization is local to this call, never model supplied.
/// ATS, DNS and trust remain URLSession's responsibility. Bodies are capped before retaining each chunk.
final class AICoverImageFetcher: @unchecked Sendable {
    private let session: URLSession
    let network: AINetworkAccess
    private let downloader: AICoverDownloadDelegate
    private let cancellationLock = NSLock()
    private var wasCancelled = false
    static let maximumDownloadBytes = 10 * 1024 * 1024
    private static let maximumPixelsPerSide = 4096
    private let maximumCandidates: Int
    private static let minimumSide = 100
    private static let maximumAspect = 1.2
    init(configuration: URLSessionConfiguration = .ephemeral, availability: AIAvailability? = nil, maximumCandidates: Int = 8) {
        precondition((1...8).contains(maximumCandidates))
        self.maximumCandidates = maximumCandidates
        network = AINetworkAccess(availability: availability)
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        let downloader = AICoverDownloadDelegate(maximumBytes: Self.maximumDownloadBytes)
        self.downloader = downloader
        session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func cancel() {
        cancellationLock.withLock { wasCancelled = true }
        session.invalidateAndCancel()
    }
    private func checkCancellation() throws {
        try Task.checkCancellation()
        if cancellationLock.withLock({ wasCancelled }) { throw CancellationError() }
    }
    private func failure(_ error: Error) -> String {
        if case AICoverFetchError.tooLarge = error { return "too_large" }
        if case AICoverFetchError.status(let status) = error { return "http_\(status)" }
        if let error = error as? URLError { return "url_error_\(error.code.rawValue)" }
        return "invalid_response"
    }
    private typealias Response = AICoverDownloadedResponse
    private struct PageImage {
        let url: URL
        let page: URL
        // Only the authorized response's extraction below creates these values.
    }
    private func download(_ url: URL, referer: URL? = nil) async throws -> Response {
        try await network.perform { [self] in
            let delegate = referer.map(AICoverRefererDelegate.init)
            let request = delegate?.request(URLRequest(url: url)) ?? URLRequest(url: url)
            let control = AICoverDownloadControl()
            let response: Response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let task = session.dataTask(with: request)
                    downloader.register(task, referer: delegate, continuation: continuation)
                    control.start(task)
                }
            } onCancel: { control.cancel() }
            try checkCancellation()
            return response
        }
    }

    private func authorized(_ source: AIWebSource, allowedSources: [AIWebSource]) throws -> URL {
        guard source.isValid, allowedSources.contains(where: { $0.sourceRef == source.sourceRef && $0.url == source.url }),
              let url = URL(string: source.url) else { throw AIToolError("permission_denied") }
        return url
    }
    private func images(_ response: Response, title: String) -> [PageImage] {
        guard let page = response.http.url else { return [] }
        return extractPageImages(body: Data(response.bytes.prefix(2 * 1024 * 1024)), responseUrl: page.absoluteString,
                                 charset: response.http.textEncodingName, title: title)
            .compactMap { URL(string: $0).map { PageImage(url: $0, page: page) } }
    }
    /// nil is not an image; false is a decoded image rejected by cover-only dimensions.
    private func isCover(_ bytes: Data) throws -> Bool? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let w = width.int64Value, h = height.int64Value
        guard w > 0, h > 0 else { return false }
        guard w <= Int64(Self.maximumPixelsPerSide), h <= Int64(Self.maximumPixelsPerSide) else { throw AICoverFetchError.tooLarge }
        guard min(w, h) >= Int64(Self.minimumSide), Double(w) / Double(h) <= Self.maximumAspect else { return false }
        guard CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else { return nil }
        return true
    }
    /// Runs on the generic executor. Save/discard are injected to test the actual staging lifecycle.
    func candidates(sources: [AIWebSource], title: String, bookRef: String,
                    save: @Sendable (Data) async throws -> AIImageAttachment,
                    discard: @Sendable (Set<String>) async -> Void) async throws -> AICoverFetchReport {
        var report = AICoverFetchReport()
        var visited = Set<String>(), staged = Set<String>()
        func cancelled(_ error: Error) throws {
            try checkCancellation()
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
        }
        func stage(_ data: Data, source: AIWebSource) async throws -> AICoverProposal {
            try checkCancellation()
            let attachment = try await save(data)
            staged.insert(attachment.id)
            try checkCancellation()
            return .init(proposalRef: UUID().uuidString, bookRef: bookRef, attachment: attachment, origin: .web(source))
        }
        do {
            for source in sources {
                try checkCancellation()
                if report.candidates.count == maximumCandidates { break }
                let url = try authorized(source, allowedSources: sources)
                guard visited.insert(url.absoluteString).inserted else { continue }
                var record = AICoverFetchReport.Source(url: source.url)
                let response: Response
                do { response = try await download(url) }
                catch { try cancelled(error); record.failures.append("source_download:" + failure(error)); report.sources.append(record); continue }
                let cover: Bool?
                do { cover = try isCover(response.bytes) }
                catch { record.failures.append(failure(error)); report.sources.append(record); continue }
                if let accepted = cover {
                    if accepted { report.candidates.append(try await stage(response.bytes, source: source)); record.candidates += 1 }
                    else { record.failures.append("dimensions") }
                } else {
                    let images = images(response, title: title)
                    record.extractedURLs = images.map { $0.url.absoluteString }
                    for image in images {
                        try checkCancellation()
                        if report.candidates.count == maximumCandidates { break }
                        guard visited.insert(image.url.absoluteString).inserted else { continue }
                        let bytes: Data
                        do { bytes = try await download(image.url, referer: image.page).bytes }
                        catch { try cancelled(error); record.failures.append("image_download:" + failure(error)); continue }
                        let accepted: Bool?
                        do { accepted = try isCover(bytes) }
                        catch { record.failures.append(failure(error)); continue }
                        guard let accepted else { record.failures.append("image_decode"); continue }
                        guard accepted else { record.failures.append("dimensions"); continue }
                        report.candidates.append(try await stage(bytes, source: source)); record.candidates += 1
                    }
                }
                report.sources.append(record)
            }
            try checkCancellation()
            await discard(staged.subtracting(report.candidates.map { $0.attachment.id }))
            try checkCancellation()
            return report
        } catch {
            await discard(staged)
            throw error
        }
    }
}
