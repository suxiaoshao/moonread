import MoonreadCoreBindings

public struct BodyCacheInventory: Sendable {
    public let lease: DataSessionLease
    public let clearable: [CachedBody]
    public let held: [CachedBody]
    public let coverFiles: [StorageFile]

    public init(lease: DataSessionLease, clearable: [CachedBody], held: [CachedBody], coverFiles: [StorageFile]) {
        self.lease = lease
        self.clearable = clearable
        self.held = held
        self.coverFiles = coverFiles
    }

    public var clearableBytes: UInt64 {
        clearable.reduce(0) { $0 + $1.bytes } + coverFiles.reduce(0) { $0 + $1.bytes }
    }
}
