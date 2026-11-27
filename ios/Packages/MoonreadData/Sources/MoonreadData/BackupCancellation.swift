import MoonreadCoreBindings
import Foundation

public extension BackupCancellation {
    func check() throws { if isCancelled() { throw CancellationError() } }
}
