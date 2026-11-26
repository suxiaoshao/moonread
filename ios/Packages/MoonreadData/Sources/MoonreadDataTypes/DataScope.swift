import CryptoKit
import Foundation

public enum DataScope: Codable, Equatable, Sendable {
    case local
    case account(String)

    public enum Environment: String, Codable, Sendable { case development, production }

    public static func confirmed(container: String, environment: Environment, recordName: String) throws -> Self {
        guard !container.isEmpty, !recordName.isEmpty else { throw DataV2Error.invalidOwnerState }
        return .account(DataIdentity.id("account", [container, environment.rawValue, recordName]))
    }

    public var key: String {
        switch self { case .local: "local"; case .account(let key): key }
    }

    public var metadataImportKey: String { self == .local ? key : "account:" + key }

    public var valid: Bool {
        switch self {
        case .local: true
        case .account(let key):
            key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }
}

public enum DataIdentity {
    public static func canonical(_ value: String) -> String { value.precomposedStringWithCanonicalMapping }
    public static func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    /// v1 identities: explicit UTF-8 byte lengths, independent of separator,
    /// process, row ordering and locale. Original strings stay in the rows.
    public static func id(_ domain: String, _ components: [String]) -> String {
        var input = Data()
        for component in ["1", domain] + components {
            let bytes = Data(canonical(component).utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { input.append(contentsOf: $0) }
            input.append(bytes)
        }
        return sha(input)
    }

    public static func unsigned(_ value: UInt64) -> String {
        let text = String(value)
        return String(repeating: "0", count: 20 - text.count) + text
    }
}

public enum DataIdentityStatus: Sendable {
    /// Scene suspension stops network capability without asserting the
    /// account became unknown or authorizing a different library.
    case paused
    case unknown
    case signedOut
    case confirmed(DataScope, syncRequested: Bool, verifiedRecordName: String? = nil)
}

public struct DataScopeSelection: Equatable, Sendable {
    public var scope: DataScope
    public var maySync: Bool

    public init(scope: DataScope, maySync: Bool) {
        self.scope = scope
        self.maySync = maySync
    }
}
