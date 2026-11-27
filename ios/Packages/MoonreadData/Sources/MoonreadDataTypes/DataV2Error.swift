
public enum DataV2Error: Error, Equatable {
    case unsupportedSchema(String, Int)
    case missingResource(String)
    case incompatibleSource(String)
    case invalidOwnerState
    case sessionClosed
    case leaseExpired
    case migrationInProgress
    case migrationAlreadyComplete
    case migrationNotVerified
    case conflictingLocalData(String)
}
