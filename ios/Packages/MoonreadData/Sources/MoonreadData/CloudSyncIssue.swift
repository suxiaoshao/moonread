public enum CloudSyncIssue: Equatable, Sendable {
    case offline, quota, unavailable, restricted, unsupportedBuild, paused, incomplete
}
