import MoonreadCoreBindings

/// Progress uses the byte offset and length of the same normalized UTF-8 body.
public enum ReadingProgress {
    public static func fraction(_ offset: UInt64, of byteCount: UInt64) -> Double {
        Double(offset) / Double(max(1, byteCount))
    }

    public static func percentage(_ offset: UInt64, of byteCount: UInt64) -> Double {
        fraction(offset, of: byteCount) * 100
    }
}
