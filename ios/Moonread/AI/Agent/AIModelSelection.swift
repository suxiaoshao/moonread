import MoonreadAI

extension AIService {
    func modelSelection(for target: AIModelSelectionTarget) -> AIModelSelection? {
        let connectionID: String?, modelID: String?, thinking: String?
        switch target {
        case .defaults: connectionID = providers.defaultTextConnectionID; modelID = nil; thinking = nil
        case .conversation(let id), .session(let id):
            guard let value = conversation(id) else { return nil }
            connectionID = value.connectionID ?? providers.defaultTextConnectionID
            modelID = value.modelID.flatMap { $0.isEmpty ? nil : $0 }; thinking = value.thinking
        }
        guard let connection = providers.connections.first(where: { $0.id == connectionID }),
              let model = providers.model(modelID ?? connection.modelChoice.id ?? "", in: connection) else { return nil }
        let effort = thinking ?? (modelID == nil && model.id == connection.modelChoice.id ? connection.modelChoice.thinking : nil)
        return AIModelSelection(connectionID: connection.id, modelID: model.id,
                                thinking: effort.flatMap { model.thinking.contains($0) ? $0 : nil } ?? AIModelSelection.defaultThinking(model))
    }
    @discardableResult func applyModelSelection(_ selection: AIModelSelection, to target: AIModelSelectionTarget) async -> Bool {
        guard let index = providers.connections.firstIndex(where: { $0.id == selection.connectionID }),
              let model = providers.model(selection.modelID, in: providers.connections[index]),
              selection.thinking == nil || model.thinking.contains(selection.thinking!) else { return false }
        guard AINativeCapabilities.supportsText(connection: providers.connections[index], model: model) else { return false }
        let thinking = selection.thinking ?? AIModelSelection.defaultThinking(model)
        switch target {
        case .defaults:
            providers.defaultTextConnectionID = selection.connectionID
            providers.connections[index].modelChoice = .selected(id: selection.modelID, thinking: thinking)
            providers.saveConnections(); return true
        case .conversation(let id), .session(let id):
            guard let value = conversation(id) else { return false }
            do {
                try await selectRuntime(.init(connectionID: selection.connectionID, modelID: selection.modelID, thinking: thinking), conversation: value)
                return true
            } catch { return false }
        }
    }
}
