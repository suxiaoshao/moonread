import MoonreadCoreBindings
import MoonreadDesign
import SwiftUI

public struct IdentityInventory: Sendable {
    public let shelf: LibraryShelf
    public let total: Int
    public let pending: [SourceFileSnapshot]
    public var eligiblePaths: Set<String>? = nil
    public init(shelf: LibraryShelf, total: Int, pending: [SourceFileSnapshot], eligiblePaths: Set<String>? = nil) {
        self.shelf = shelf; self.total = total; self.pending = pending; self.eligiblePaths = eligiblePaths
    }

    public var admittedPending: [SourceFileSnapshot] { pending.filter { eligiblePaths?.contains($0.relativePath) ?? true } }
    public var local: [SourceFileSnapshot] { admittedPending.filter { !$0.needsDownload } }
    public var cloudBytes: UInt64 { pending.filter(\.needsDownload).reduce(0) { $0 + $1.size } }
}

/// Retry/admission deduplication only; validity and pending identity remain Rust-owned.
public struct IndexSourceStamp: Hashable {
    let id: String
    let size: UInt64
    let modified: Int64
    let decoding: String
    public init(_ file: SourceFileSnapshot) { id = file.id; size = file.size; modified = file.modified; decoding = file.decoding }
}

public struct IndexFailure: Identifiable {
    public let file: SourceFileSnapshot
    public let message: String
    public init(file: SourceFileSnapshot, message: String) {
        self.file = file
        self.message = message
    }

    public var id: String { file.id }
    public func matches(_ other: SourceFileSnapshot) -> Bool {
        IndexSourceStamp(file) == IndexSourceStamp(other)
    }
}

public enum FullIndexSheetAction { case start, stop, retry, none }

public struct FullIndexView: View {
    @Environment(\.theme) private var theme
    public struct Status {
        public let shelfID: String?
        public let running, waitingForReader, paused: Bool
        public let failures: [IndexFailure]
        public let currentFile: SourceFileSnapshot?
        public let message: String?

        public init(shelfID: String?, running: Bool, waitingForReader: Bool, paused: Bool, failures: [IndexFailure],
                    currentFile: SourceFileSnapshot?, message: String?) {
            self.shelfID = shelfID; self.running = running; self.waitingForReader = waitingForReader
            self.paused = paused; self.failures = failures; self.currentFile = currentFile; self.message = message
        }
    }
    let indexStatus: Status
    let progress: (IdentityInventory?) -> (indexed: Int, total: Int)?
    let action: (IdentityInventory?, Bool) -> FullIndexSheetAction
    let effectiveCloud: (Bool) -> Bool
    let stop: () -> Void
    let startIndex: (Bool, [SourceFileSnapshot]?) -> Void
    let load: () async throws -> IdentityInventory
    let describeError: (Error) -> String

    public init(shelfID: String, status: Status, progress: @escaping (IdentityInventory?) -> (indexed: Int, total: Int)?,
                action: @escaping (IdentityInventory?, Bool) -> FullIndexSheetAction, includeCloud: @escaping (Bool) -> Bool,
                stop: @escaping () -> Void, start: @escaping (Bool, [SourceFileSnapshot]?) -> Void,
                load: @escaping () async throws -> IdentityInventory, describeError: @escaping (Error) -> String,
                openFailure: @escaping (String) -> Void) {
        self.shelfID = shelfID; self.indexStatus = status; self.progress = progress
        self.action = action; self.effectiveCloud = includeCloud; self.stop = stop; self.startIndex = start
        self.load = load; self.describeError = describeError; self.openFailure = openFailure
    }
    let shelfID: String
    let openFailure: (String) -> Void
    @State private var inventory: IdentityInventory?
    @State private var includeCloud = false
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .largeTitle) private var indexedSize = 38.0
    @ScaledMetric(relativeTo: .title) private var totalSize = 28.0
    @ScaledMetric(relativeTo: .body) private var unitSize = 17.0
    private var active: Bool { indexStatus.shelfID == shelfID && indexStatus.running }
    private var failures: [IndexFailure] { indexStatus.failures.filter { $0.file.shelfId == shelfID } }
    private var counts: (indexed: Int, total: Int)? { progress(inventory) }
    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 16) {
                        Spacer(minLength: 0)
                        status
                        Spacer(minLength: 0)
                        if let inventory, inventory.pending.contains(where: \.needsDownload) {
                            let cloud = inventory.pending.filter(\.needsDownload)
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(isOn: Binding(get: { effectiveCloud(includeCloud) },
                                                     set: { if !active { includeCloud = $0 } })) {
                                    Text("包含未下载的 iCloud 文件", tableName: "FullIndex")
                                }.disabled(active)
                                    .accessibilityIdentifier("fullIndexIncludeCloud")
                                Text("\(cloud.count) 本，已知下载量 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: inventory.cloudBytes), countStyle: .file))", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                                if cloud.contains(where: { $0.size == 0 }) { Text("部分文件大小未知", tableName: "ShelfRecovery").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                            }.padding().background(Color(uiColor: theme.surface), in: .rect(cornerRadius: 16))
                        }

                        if !failures.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("未能建立索引", tableName: "FullIndex").font(.headline)
                                Text("点开文件可以处理编码或查看原因。", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                                ForEach(failures) { failure in
                                    Button { openFailure(failure.id) } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(verbatim: failure.file.relativePath)
                                                Text(verbatim: failure.message).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                            }
                                            Spacer(); Image(systemName: "chevron.right").font(.footnote)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                    }.accessibilityIdentifier("fullIndexFailure-" + failure.id)
                                }
                            }
                        }
                    }.frame(maxWidth: 400)
                        .padding(.horizontal, 20).padding(.vertical)
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }.themedPage().navigationTitle(Text("建立索引", tableName: "FullIndex"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ZStack {
                    // Reserve the largest native action at the current language
                    // and Dynamic Type size, without exposing an inactive button.
                    ZStack {
                        actionButton(.start)
                        actionButton(.stop)
                        actionButton(.retry)
                    }.hidden().allowsHitTesting(false).accessibilityHidden(true)
                    actionButton(action(loadError == nil ? inventory : nil, includeCloud))
                }.frame(maxWidth: 400).frame(maxWidth: .infinity)
                    .padding(.horizontal, 20).padding(.vertical).background(Color(uiColor: theme.canvas))
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { SystemToolbarButton("关闭", role: .close) { dismiss() }.accessibilityIdentifier("closeFullIndex") } }
            .task(id: indexStatus.running) { await loadInventory() }
        }.presentationSizing(.form)
    }
    private var ownsTask: Bool { indexStatus.shelfID == shelfID }
    private var waiting: Bool { ownsTask && indexStatus.waitingForReader }
    private var paused: Bool { ownsTask && indexStatus.paused }
    private var statusTitle: LocalizedStringKey {
        if paused { return "已暂停" }
        if waiting { return "等待当前操作完成" }
        if active { return "正在建立索引" }
        if let counts, counts.total == 0 { return "书架中还没有小说" }
        if let counts, counts.total == counts.indexed { return "索引已完成" }
        return "已索引"
    }
    private var status: some View {
        VStack(spacing: 14) {
            if let inventory {
                Text(inventory.shelf.builtin ? String(localized: "我的书架") : inventory.shelf.name)
                    .font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
            }
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(uiColor: theme.accent)).accessibilityHidden(true)
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.circle").foregroundStyle(Color(uiColor: theme.destructive))
                Button { Task { await loadInventory() } } label: { Text("重试", tableName: "FullIndex") }
                    .buttonStyle(.bordered).accessibilityIdentifier("fullIndexLoadError")
            } else if let counts {
                Text(statusTitle, tableName: "FullIndex").font(.title3.weight(.semibold))
                if counts.total > 0 {
                    Text(progressLabel(indexed: counts.indexed, total: counts.total))
                        .monospacedDigit().accessibilityIdentifier("fullIndexProgress")
                    if active && !waiting && !paused {
                        ProgressView(value: Double(counts.indexed), total: Double(max(1, counts.total)))
                            .frame(maxWidth: 260).accessibilityLabel(Text("索引进度", tableName: "FullIndex"))
                    }
                    if waiting {
                        Text("当前操作完成后继续建立索引", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    } else if active && !paused {
                        VStack(spacing: 6) {
                            Text(indexStatus.currentFile == nil ? "正在准备" : "正在处理", tableName: "FullIndex")
                                .font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            Text(verbatim: indexStatus.currentFile?.relativePath ?? " ").font(.subheadline)
                                .lineLimit(2, reservesSpace: true).truncationMode(.middle)
                                .accessibilityLabel(Text(verbatim: indexStatus.currentFile?.relativePath ?? ""))
                                .accessibilityHidden(indexStatus.currentFile == nil)
                                .accessibilityIdentifier("fullIndexCurrentFile")
                        }
                        Text("关闭此页后，前台仍会继续。", tableName: "FullIndex").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                    } else if counts.total > counts.indexed && !paused {
                        Text("还有 \(counts.total - counts.indexed) 本未建立索引", tableName: "FullIndex")
                            .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)).accessibilityIdentifier("fullIndexRemaining")
                    }
                }
                if ownsTask, let message = indexStatus.message {
                    Text(verbatim: message).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
            } else {
                ProgressView { Text("正在检查书架…", tableName: "FullIndex") }.accessibilityIdentifier("fullIndexChecking")
            }
        }.multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }
    private func progressLabel(indexed: Int, total: Int) -> AttributedString {
        var label = AttributedString(String(localized: "\(indexed) / \(total) 本", table: "FullIndex"))
        label.font = .system(size: unitSize)
        if let range = label.range(of: "/") { label[range].font = .system(size: totalSize, weight: .medium) }
        if let range = label.range(of: String(total), options: .backwards) { label[range].font = .system(size: totalSize, weight: .medium) }
        if let range = label.range(of: String(indexed)) { label[range].font = .system(size: indexedSize, weight: .semibold) }
        return label
    }
    @ViewBuilder private func actionButton(_ action: FullIndexSheetAction) -> some View {
        switch action {
        case .stop:
            Button { stop() } label: { Text("停止", tableName: "FullIndex").font(.body.weight(.medium)).frame(maxWidth: .infinity) }.buttonStyle(.bordered).foregroundStyle(Color(uiColor: theme.accent)).controlSize(.large).accessibilityIdentifier("fullIndexStop")
        case .start:
            Button { start() } label: { Text("开始建立索引", tableName: "FullIndex").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("fullIndexStart")
        case .retry:
            Button { start() } label: { Text("重试失败项", tableName: "FullIndex").frame(maxWidth: .infinity) }.buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("fullIndexRetry")
        case .none: EmptyView()
        }
    }
    private func start() { startIndex(includeCloud, inventory?.pending) }
    private func loadInventory() async {
        do { inventory = try await load(); loadError = nil }
        catch { loadError = describeError(error) }
    }
}
