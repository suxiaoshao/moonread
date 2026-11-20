import XCTest

@testable import Moonread

@MainActor class AINativeToolsFixture: XCTestCase {
  var nativeRepository: AIRepository?
  func fixture(_ mode: String) async throws -> (
    AIConnectionService, AINativeTools, AIConnection, UserDefaults
  ) {
    AITestURLProtocol.state.reset(mode)
    let defaults = UserDefaults(suiteName: "AINative-\(UUID().uuidString)")!
    let auth = TestAI.authentication(
      makeCallbackSource: { CallbackFixture.make() },
      credentialResolver: { _ in
        AICredentialStorage(
          accessToken: "test-only", refreshToken: "", expires: .distantFuture, accountID: "fixture")
      })
    let providers = TestAI.connections(defaults: defaults, auth: auth)
    providers.sharing.waitingChanged = { owner, waiting in
      if waiting, let request = providers.sharing.requests.first(where: { $0.owner == owner }) {
        providers.sharing.answer(request.id, approved: true)
      }
    }
    var connection = AIProviderPreset.all.first { $0.auth == .chatGPT }!.connection()
    connection.authMethod = .apiKey
    connection.models = [
      .init(id: "gpt-6-astra", name: "Astra", contextWindow: 32000, thinking: [], directoryOrigin: .account, isListed: true)
    ]
    // Native-tool tests start with a successfully loaded connection directory;
    // an unmarked public candidate is intentionally not restored by D2.
    connection.modelsOrigin = .account
    connection.modelsIdentity = connection.catalogIdentity
    connection.modelsChecked = TestAI.now
    connection.modelID = "gpt-6-astra"
    _ = providers.addConnection(connection)
    for purpose in AIModelPurpose.allCases {
      XCTAssertTrue(
        providers.setPurpose(
          purpose, selection: .init(connectionID: connection.id, modelID: connection.modelID)))
    }
    let images = AIImageStore()
    let repository = try await AIRepository.open(inMemory: true)
    try await repository.create(.init(id: "test-session", title: "Native fixture"))
    await images.bind("test-session", repository: repository)
    nativeRepository = repository
    let tools = AINativeTools(
      providers: providers, owner: "test-session", images: images,
      makeTransport: {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AITestURLProtocol.self]
        return AITransport(configuration: config)
      })
    return (providers, tools, connection, defaults)
  }
  func commitNative(_ output: AINativeResult, tools: AINativeTools) async throws {
    let refs = Set(output.data.attachments?.map(\.id) ?? [])
    let stage = await tools.images.staged(owner: tools.owner, refs: refs)
    // Test fixture explicitly records the same pending-output first-reference transaction as runtime.
    guard let repository = nativeRepository else { throw AIError.storage }
    var head = try await repository.head(tools.owner)
    head.pendingCalls = [
      .init(
        id: "native", name: "generate_image", input: .null, output: try AIAgentEntry.json(output))
    ]
    try await repository.commit(tools.owner, head: head, assets: stage, references: Array(refs))
    await tools.images.didCommit(owner: tools.owner, refs: refs)
  }

}

