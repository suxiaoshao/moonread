import Foundation

struct StorageFile: Hashable, Sendable {
    let url: URL
    let bytes: UInt64
    let device, inode: UInt64
    let modified: Date

    private static let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]

    static func file(at url: URL) throws -> Self? {
        do {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber, let device = attrs[.systemNumber] as? NSNumber,
                  let inode = attrs[.systemFileNumber] as? NSNumber, let modified = attrs[.modificationDate] as? Date else {
                throw CocoaError(.fileReadUnknown)
            }
            return .init(url: url.standardizedFileURL, bytes: size.uint64Value, device: device.uint64Value,
                         inode: inode.uint64Value, modified: modified)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    static func children(of root: URL) throws -> [URL] {
        do {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return [] }
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return []
        }
    }

    static func files(in root: URL) throws -> [Self] {
        if let file = try file(at: root) { return [file] }
        var work = try children(of: root), files: [Self] = []
        while let url = work.popLast() {
            try Task.checkCancellation()
            if let file = try file(at: url) { files.append(file) }
            else { work += try children(of: url) }
        }
        return files
    }

    static func remove(_ files: [Self]) -> UInt64 {
        var bytes: UInt64 = 0
        for file in files {
            if Task.isCancelled { break }
            guard (try? self.file(at: file.url)) == file else { continue }
            do {
                try FileManager.default.removeItem(at: file.url)
                bytes += file.bytes
            } catch {
                // The caller compares the measured result with the selection.
                continue
            }
        }
        return bytes
    }
}

struct StorageDirectory: Sendable {
    let url: URL
    let files: [StorageFile]

    init(_ url: URL) throws {
        self.url = url
        files = try StorageFile.files(in: url)
    }

    var bytes: UInt64 { files.reduce(0) { $0 + $1.bytes } }

    func removeIfUnchanged() throws -> UInt64 {
        try Task.checkCancellation()
        guard Set(try StorageFile.files(in: url)) == Set(files) else { return 0 }
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        try FileManager.default.removeItem(at: url)
        return bytes
    }
}

enum MetadataTemporaryFiles {
    private static let process = UUID().uuidString
    private static let lock = NSLock()
    nonisolated(unsafe) private static var prepared = Set<URL>()

    static func root(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    static func current(_ root: URL) -> URL {
        root.appending(path: process, directoryHint: .isDirectory)
    }

    static func stale(_ root: URL) throws -> [StorageDirectory] {
        try StorageFile.children(of: root).filter { $0.lastPathComponent != process }.map(StorageDirectory.init)
    }

    static func prepare(_ root: URL) -> URL {
        lock.withLock {
            if prepared.insert(root).inserted, let stale = try? stale(root) {
                for item in stale { _ = try? item.removeIfUnchanged() }
            }
            return current(root)
        }
    }
}
