import MoonreadCoreBindings
import Foundation

/// Coordinated access and task cancellation stay with the caller. EOF means a
/// zero-byte read, not a short read from a file provider.
enum IndexInput {
    static func encoding(read: (Int) throws -> Data) throws -> String {
        let limit = 64 * 1024 + 1
        var sample = Data()
        while sample.count < limit {
            let next = try read(limit - sample.count)
            if next.isEmpty { break }
            sample.append(next)
        }
        return try detectImportEncoding(sample: sample)
    }

    static func rawHash(read: (Int) throws -> Data) throws -> String {
        var state = beginRawHash()
        while true {
            let bytes = try read(1024 * 1024)
            let step = try advanceRawHash(previous: state, bytes: bytes, eof: bytes.isEmpty)
            if let hash = step.sha256 { return hash }
            guard let next = step.next else { throw ReaderError.InvalidSettings }
            state = next
        }
    }

    static func file<T>(_ path: String, _ read: (FileHandle) throws -> T) throws -> T {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        return try read(handle)
    }
}

/// Used by read-only identity callers that already hold coordinated source
/// access. Rust accepts bytes only and has no knowledge of source paths.
final class SourceIdentityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    private func checkedRead(_ file: FileHandle, maximum: Int) throws -> Data {
        if lock.withLock({ cancelled }) { throw ReaderError.Paused }
        let bytes = try file.read(upToCount: maximum) ?? Data()
        if lock.withLock({ cancelled }) { throw ReaderError.Paused }
        return bytes
    }

    func rawSha256(filePath: String) throws -> String {
        try IndexInput.file(filePath) { file in
            try IndexInput.rawHash { try checkedRead(file, maximum: $0) }
        }
    }

    func identify(filePath: String, decoding: String) throws -> SourceTextIdentity {
        let policy = try normalizeSourceDecoding(decoding: decoding)
        return try IndexInput.file(filePath) { file in
            let encoding: String
            if policy == "auto" {
                encoding = try IndexInput.encoding { try checkedRead(file, maximum: $0) }
                try file.seek(toOffset: 0)
            } else { encoding = policy }
            var state = try beginTextImport(encoding: encoding, mode: .identity, publishedChunkCount: 0)
            while true {
                let bytes = try checkedRead(file, maximum: 8192)
                let output = try advanceTextImport(previous: state, bytes: bytes, eof: bytes.isEmpty, replay: [])
                if lock.withLock({ cancelled }) { throw ReaderError.Paused }
                if let result = output.identity { return result }
                guard let next = output.next else { throw ReaderError.InvalidSettings }
                state = next
            }
        }
    }
}
