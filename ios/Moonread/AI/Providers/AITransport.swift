import Foundation
import AISDKProviderUtils

/// One session per running conversation. Byte delivery is independent of view
/// lifetime and does not inherit the SDK default's 16 KB streaming threshold.
final class AITransport: @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = .infinity
        configuration.timeoutIntervalForResource = .infinity
        session = URLSession(configuration: configuration)
    }
    func cancel() { session.invalidateAndCancel() }
    func finish() { session.finishTasksAndInvalidate() }
    func fetch(_ request: URLRequest) async throws -> FetchResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let isSSE = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let pump = Task {
                do {
                    var buffer = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if (isSSE && byte == 10) || buffer.count >= 4096 {
                            continuation.yield(buffer); buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
        return FetchResponse(body: .stream(stream), urlResponse: response)
    }
}
