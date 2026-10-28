import SwiftUI
import UIKit

/// Intent belongs to this reading opening. Geometry and native lifecycle never
/// write the location; they only choose where that location is presented.
enum ReaderTool: Hashable { case library, search, settings, more }
enum ReaderToolExposure: Equatable { case hidden, accessory, reference, expanded }
enum ReaderDestination: Hashable {
    case library, fullSettings, preview(UUID), palette(UUID), chapter(UUID)
    case note(String), rebuild(UUID), progress, history, details, ai

    var editorID: UUID? {
        switch self { case .palette(let id), .chapter(let id), .rebuild(let id): id; default: nil }
    }
}
struct ReaderToolLocation: Equatable {
    var selection: ReaderTool = .library
    var path: [ReaderDestination] = []
}

@MainActor @Observable final class ReaderPresentationState {
    var location = ReaderToolLocation() { didSet { if oldValue != location { revision &+= 1 } } }
    var exposure = ReaderToolExposure.hidden { didSet { if oldValue != exposure { revision &+= 1 } } }
    var controlsVisible = false { didSet { if oldValue != controlsVisible { revision &+= 1 } } }
    private(set) var revision: UInt64 = 0

    func choose(_ tool: ReaderTool, exposure: ReaderToolExposure) {
        guard location.selection != tool || self.exposure != exposure else { return }
        location = ReaderToolLocation(selection: tool)
        self.exposure = exposure
    }
    func push(_ destination: ReaderDestination) {
        guard location.path.last != destination else { return }
        location.path.append(destination)
    }
    func close(_ destination: ReaderDestination) {
        guard let index = location.path.firstIndex(of: destination) else { return }
        location.path.removeSubrange(index...)
    }
    func finishEditor(_ id: UUID) {
        guard let index = location.path.firstIndex(where: { $0.editorID == id }) else { return }
        location.path.removeSubrange(index...)
    }
    func setControlsVisible(_ visible: Bool) {
        controlsVisible = visible
        if !visible, location.path.isEmpty { location.selection = .library }
    }
    func expandSearch(_ expanded: Bool) {
        exposure = expanded ? .expanded : .accessory
        if expanded { controlsVisible = false }
    }
    func reset() { location = ReaderToolLocation(); exposure = .hidden; controlsVisible = false }
}

/// Values come from the source scene window, before reader/inspector layout.
struct ReaderContainerMetrics: Equatable {
    var bounds = CGRect.zero
    var safeArea = UIEdgeInsets.zero
    var blocked: [CGRect] = []
    var regular = false
}
enum ReaderToolContainer: Equatable { case compact, inspector, sheet }

@MainActor enum ReaderContainerPolicy {
    static func container(_ metrics: ReaderContainerMetrics, settings: ReaderSettings?) -> ReaderToolContainer {
        guard metrics.regular else { return .compact }
        guard let settings else { return .sheet }
        // Reserve the maximum preferred column (400), plus a 24pt separation.
        // Never reconstruct this budget from mounted inspector/body widths.
        let regions = ReadingContainerRegions.available(metrics.bounds.inset(by: metrics.safeArea), blocked: metrics.blocked)
        let fits = regions.contains { region in
            let remaining = region.width - 424
            guard remaining > 0 else { return false }
            let insets = ReadingTypography.insets(settings, width: remaining)
            return remaining - insets.left - insets.right >= ReadingTypography.minimumColumnWidth(settings)
        }
        return fits ? .inspector : .sheet
    }
}

/// A native callback can release only the installation that produced it. Route
/// generations distinguish user pop input from callbacks for an outgoing node.
struct ReaderHostToken: Equatable {
    let id: UUID
    let opening: UUID
    let generation: UInt64
    init(opening: UUID, generation: UInt64) { id = UUID(); self.opening = opening; self.generation = generation }
    private init(id: UUID, opening: UUID, generation: UInt64) { self.id = id; self.opening = opening; self.generation = generation }
    func updating(generation: UInt64) -> Self { Self(id: id, opening: opening, generation: generation) }
}
@MainActor @Observable final class ReaderNativeInstallation {
    private(set) var token: ReaderHostToken?
    private(set) var dismissing = false
    func install(opening: UUID, generation: UInt64) -> ReaderHostToken {
        if let token {
            guard token.opening == opening, !dismissing else { return token }
            let updated = token.updating(generation: generation)
            self.token = updated
            return updated
        }
        let value = ReaderHostToken(opening: opening, generation: generation)
        token = value; dismissing = false
        return value
    }
    func beginDismissal() { if token != nil { dismissing = true } }
    @discardableResult func completed(_ value: ReaderHostToken) -> Bool {
        guard token?.id == value.id, token?.opening == value.opening else { return false }
        token = nil; dismissing = false
        return true
    }
    func acceptsInput(_ value: ReaderHostToken, opening: UUID, generation: UInt64) -> Bool {
        token == value && !dismissing && value.opening == opening && value.generation == generation
    }
}
