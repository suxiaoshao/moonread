import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

/// Task setup and lifecycle. The app supplies only the existing conversation host.
public struct AIQuickTaskSheetContent<Chat: View>: View {
    public init(request: AIQuickTaskRequest, @ViewBuilder chat: @escaping (String, AITaskObject) -> Chat) {
        self.request = request
        self.chat = chat
    }

    @Environment(AIService.self) private var ai
    @Environment(\.dismiss) private var dismiss
    private let request: AIQuickTaskRequest
    private let chat: (String, AITaskObject) -> Chat
    @State private var startedID: String?
    @State private var starting = false
    @State private var coverMode: AICoverMode = .find
    @State private var notice: AIActionNotice?
    @State private var visible = false
    @State private var transferring = false
    @State private var detent = PresentationDetent.large
    private var sessionID: String? { startedID ?? request.task(ai)?.id }

    public var body: some View {
        NavigationStack {
            Group {
                if let id = sessionID, let session = ai.conversation(id) {
                    chat(id, request.object)
                        .toolbar {
                            if !session.listed {
                                ToolbarItem(placement: .topBarLeading) {
                                    Button("转入对话") {
                                        transferring = true
                                        Task {
                                            defer { transferring = false }
                                            do { _ = try await ai.transferTask(id) } catch { ai.notify(error) }
                                        }
                                    }.disabled(transferring || session.deleting).accessibilityIdentifier("transferAITask")
                                }
                            }
                        }
                } else {
                    AITaskSetup(object: request.object, canStart: request.family != .cover || AICoverModePicker.canStart(coverMode, ai), starting: starting) {
                        if request.family == .cover { AICoverModePicker(mode: $coverMode) }
                    } start: { instruction, selection in start(instruction, selection) }
                        .modifier(AIDataSharingPresentation(owner: request.id))
                }
            }
            .navigationTitle(request.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SystemToolbarButton("关闭", role: .close) { dismiss() }.toolbarGlyph().accessibilityIdentifier("closeAITask") } }
        }
        .presentationDetents([.medium, .large], selection: $detent).presentationDragIndicator(.visible)
        .onAppear { visible = true }.onDisappear { visible = false; notice = nil }
        .onReceive(NotificationCenter.default.publisher(for: .aiActionFailed).receive(on: DispatchQueue.main)) { notification in
            guard visible, let event = notification.object as? AIActionNotice, event.sessionID == nil else { return }
            notice = event
        }
        .alert("暂时无法完成", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) { notice = nil }
        } message: { Text(notice?.message ?? "") }
        .task { await ai.load(); if startedID == nil { startedID = request.task(ai)?.id } }
    }

    private func start(_ instruction: String, _ selection: AIModelSelection) {
        guard !starting else { return }
        // Reserve before creating the asynchronous work, including repeated clicks in this run loop.
        starting = true
        let kind: AITaskKind = switch request.family {
        case .metadata: .metadata
        case .cover: .cover(mode: coverMode)
        case .organization: .organization
        case .statistics: .statistics
        }
        Task {
            defer { starting = false }
            do {
                startedID = try await ai.startTask(origin: request.origin, kind: kind, attachments: request.attachments, instruction: instruction, selection: selection, consentOwner: request.id).id
            } catch { ai.notify(error) }
        }
    }
}
