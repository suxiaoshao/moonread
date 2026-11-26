import MoonreadCoreBindings
import Foundation

public extension PreparationState {
    var isComplete: Bool { if case .complete = self { true } else { false } }
    var isPaused: Bool { if case .paused = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
    var isActive: Bool {
        switch self {
        case .preparing, .importing, .finalizing: true
        case .complete, .paused, .failed: false
        }
    }
    var failure: ReaderError? {
        if case .failed(.reported(let error)) = self { error } else { nil }
    }
}
