import Foundation
import MoonreadAI
import MoonreadDesign

@MainActor func makeAppAIService(
    repository: AIRepository? = nil, defaults: UserDefaults? = nil,
    storefront: AIStorefrontSource = .live, auth: AIAuthentication = AIAuthentication(),
    reader: AppDataService = .shared,
    makeTransport: @escaping @Sendable () -> AITransport = { AITransport() },
    availability: AIAvailability? = nil
) -> AIService {
    AIService(
        repository: repository, defaults: defaults, storefront: storefront, auth: auth,
        proposals: AIProposalRegistry(reader: reader),
        readingAccess: reader.aiReadingAccess, privacyPolicy: { AppLinks.privacy() },
        makeTransport: makeTransport, availability: availability, didLoad: { service in
            #if DEBUG
            service.installTaskFixturesIfRequested()
            #endif
        }
    )
}

#if DEBUG
private extension AIService {
    func installTaskFixturesIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--ui-test-ai-tasks") else { return }
        fixtureObserver = MainActorNotifications.observe(.aiTaskFixtureReady) { [weak self] in
            Task { @MainActor in do { try await self?.seedTaskFixturesIfReady() } catch { self?.error = AIRequestError.message(error) } }
        }
        Task { do { try await seedTaskFixturesIfReady() } catch { self.error = AIRequestError.message(error) } }
    }
}
#endif
