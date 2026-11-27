import SwiftUI

@MainActor @Observable public final class AIHost {
    private let defaults: UserDefaults
    private let makeService: @MainActor (UserDefaults, AIAvailability) -> AIService
    public let availability: AIAvailability
    public private(set) var runtime: AIService?

    public init(makeService: @escaping @MainActor (UserDefaults, AIAvailability) -> AIService) {
        self.makeService = makeService
        defaults = AIAvailability.applicationDefaults
        availability = AIAvailability(defaults: defaults)
    }

    public func activate() -> AIService? {
        guard availability.isAvailable else { return nil }
        if let runtime { return runtime }
        let service = makeService(defaults, availability)
        runtime = service
        return service
    }

    public var connectionCount: Int {
        runtime?.providers.connections.count ?? AIConnectionService.storedConnections(defaults).count
    }
}

public struct AIEntry<Content: View>: View {
    @Environment(AIHost.self) private var host
    private let active: Bool
    private let content: () -> Content

    public init(active: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.active = active; self.content = content
    }

    public var body: some View {
        Group {
            if host.availability.isAvailable {
                if let runtime = host.runtime { content().environment(runtime) }
                else if active { ProgressView() }
            }
        }
        .task(id: active && host.availability.isAvailable) {
            if active { _ = host.activate() }
        }
    }
}
