import SwiftUI
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var model: ShareReceiveModel?
    override func viewDidLoad() {
        super.viewDidLoad()
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let model = ShareReceiveModel(providers: providers, context: extensionContext)
        self.model = model
        let host = UIHostingController(rootView: ShareReceiveView(model: model))
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        model?.stopReceiving()
    }
}

@MainActor @Observable
private final class ShareReceiveModel {
    enum State { case ready, receiving, received(Int, [String]), failed(String) }
    private(set) var state: State = .ready
    private let providers: [NSItemProvider]
    private let context: NSExtensionContext?
    private var task: Task<Void, Never>?
    var count: Int { providers.count }
    var canCancel: Bool { if case .received = state { false } else { true } }
    init(providers: [NSItemProvider], context: NSExtensionContext?) { self.providers = providers; self.context = context }
    func receive() {
        guard task == nil else { return }
        state = .receiving
        task = Task {
            defer { task = nil }
            do {
                let draft = try ShareInbox.Draft(in: .shared())
                var published = false
                defer { if !published { draft.discard() } }
                var items: [ShareInbox.Item] = [], skipped: [String] = []
                for provider in providers {
                    try Task.checkCancellation()
                    do { items.append(try await draft.load(provider)) }
                    catch let skippedFile as ShareInbox.SkippedFile { skipped.append(skippedFile.name) }
                    catch ShareInbox.InboxError.unsupported {
                        skipped.append(provider.suggestedName ?? String(localized: "未命名文件", table: "ShareReceive"))
                    }
                }
                try Task.checkCancellation()
                if !items.isEmpty { try draft.publish(items: items, skippedNames: skipped); published = true }
                state = .received(items.count, skipped)
            } catch is CancellationError { }
            catch { state = .failed(error.localizedDescription) }
        }
    }
    func cancel() {
        let running = task
        running?.cancel()
        Task { await running?.value; context?.cancelRequest(withError: CocoaError(.userCancelled)) }
    }
    func stopReceiving() { task?.cancel() }
    func done() { context?.completeRequest(returningItems: nil) }
}

private struct ShareReceiveView: View {
    let model: ShareReceiveModel
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "books.vertical").font(.system(size: 48)).foregroundStyle(.tint).accessibilityHidden(true)
                switch model.state {
                case .ready:
                    Text("接收 \(model.count) 个文件", tableName: "ShareReceive").font(.title2)
                    Text("TXT 将存入‘我的书架’根目录，来源文件会保留。", tableName: "ShareReceive").foregroundStyle(.secondary)
                    Button { model.receive() } label: { Text("加入书架", tableName: "ShareReceive") }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("shareReceiveImport")
                case .receiving:
                    ProgressView { Text("正在接收…", tableName: "ShareReceive") }
                case .received(let count, let skipped):
                    Text("已接收 \(count) 本", tableName: "ShareReceive").font(.title2)
                    if !skipped.isEmpty { Text("跳过 \(skipped.count) 个：\(skipped.joined(separator: "、"))", tableName: "ShareReceive").foregroundStyle(.secondary) }
                    if count > 0 { Text("打开月读后将自动导入。同名文件会询问是否替换。", tableName: "ShareReceive").foregroundStyle(.secondary) }
                    Button { model.done() } label: { Text("完成", tableName: "ShareReceive") }.buttonStyle(.borderedProminent).accessibilityIdentifier("shareReceiveDone")
                case .failed(let message):
                    Text("接收未完成", tableName: "ShareReceive").font(.title2)
                    Text(verbatim: message).foregroundStyle(.secondary)
                    Button { model.receive() } label: { Text("重试", tableName: "ShareReceive") }.buttonStyle(.borderedProminent)
                }
            }.padding(28).frame(maxWidth: 540).frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
                .navigationTitle(Text("月读", tableName: "ShareReceive"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.canCancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(role: .cancel) { model.cancel() } label: { Text("取消", tableName: "ShareReceive") }
                                .accessibilityIdentifier("shareReceiveCancel")
                        }
                    }
                }
        }
    }
}
