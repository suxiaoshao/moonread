import MoonreadDesign
import MoonreadCoreBindings
import SwiftUI

struct StorageSelectionPage: View {
    let model: StorageSpaceModel
    let preselectedKind: StorageCleanupKind?
    @Environment(LibraryModel.self) private var library
    @Environment(\.theme) private var theme
    @State private var selectedKinds = Set<StorageCleanupKind>()
    @State private var request: StorageCleanupRequest?

    private var selection: StorageCleanupRequest {
        model.confirmation(kinds: selectedKinds, shell: library.shell)
    }

    var body: some View {
        StoragePage(title: .init("选择清理项目", table: "Storage")) {
            if model.available.isEmpty {
                StorageHint("暂无可清理项目")
            } else {
                StorageGroup("选择要清理的内容") {
                    ForEach(model.available) { kind in
                        let picked = selectedKinds.contains(kind)
                        Button {
                            if !selectedKinds.insert(kind).inserted { selectedKinds.remove(kind) }
                        } label: {
                            StorageRow(title: kind.title, bytes: model.bytes(for: kind), picked: picked)
                        }.buttonStyle(.plain).accessibilityAddTraits(picked ? .isSelected : [])
                    }
                }
            }
            if !selection.readerTitles.isEmpty {
                Text("将关闭的阅读页：\(selection.readerTitles.formatted(.list(type: .and)))", tableName: "Storage")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }
            StorageAction(title: selectionTitle, progress: cleanupProgress, disabled: selection.bytes == 0 || model.busy) {
                request = selection
            }.accessibilityIdentifier("clearRebuildableCaches")
            if let message = model.cleanupMessage { Text(verbatim: message).font(.footnote).accessibilityIdentifier("readingDataResult") }
        }
        .disabled(model.busy)
        .toolbar {
            if cleanupProgress != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消", action: model.cancelCleanup)
                        .toolbarGlyph()
                        .disabled(model.operation == .cancelling)
                        .accessibilityIdentifier("cancelStorageCleanup")
                }
            }
        }
        .onAppear {
            if selectedKinds.isEmpty {
                selectedKinds = preselectedKind.map { [$0] } ?? Set(model.available)
            }
        }
        .refreshable { if !model.busy { await model.refresh() } }
        .alert(Text(alertTitle), isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
               presenting: request) { confirmed in
            Button(role: .destructive) {
                model.clean(confirmed, shell: library.shell)
            } label: { Text(actionTitle(confirmed)) }
            Button("取消", role: .cancel) {}
        } message: { confirmed in
            Text(verbatim: confirmationMessage(confirmed))
        }
    }

    private func confirmationMessage(_ confirmed: StorageCleanupRequest) -> String {
        let size = StorageSpaceModel.formatted(confirmed.bytes)
        let kinds = confirmed.kinds.map { String(localized: $0.title) }.formatted(.list(type: .and))
        var message = [String(localized: "将清理\(kinds)，约 \(size)。", table: "Storage")]
        if !confirmed.bodies.isEmpty {
            message.append(String(localized: "再次阅读需要原文件。进度、书签、批注和统计会保留。", table: "Storage"))
        }
        if !confirmed.readerTitles.isEmpty {
            let titles = confirmed.readerTitles.formatted(.list(type: .and))
            message.append(String(localized: "将保存进度并关闭\(titles)。听书和自动阅读也会停止。", table: "Storage"))
        }
        return message.joined(separator: "\n\n")
    }

    private var cleanupProgress: LocalizedStringResource? {
        switch model.operation {
        case .cleaning: .init("正在清理…", table: "Storage")
        case .cancelling: .init("正在取消…", table: "Storage")
        default: nil
        }
    }

    private var selectionTitle: LocalizedStringResource {
        if selection.bytes == 0 { return .init("清理所选项目", table: "Storage") }
        return .init("清理 \(StorageSpaceModel.formatted(selection.bytes))", table: "Storage")
    }

    private var alertTitle: LocalizedStringResource {
        if request?.readers.isEmpty == false { return .init("关闭阅读页并清理？", table: "Storage") }
        return .init("清理所选项目？", table: "Storage")
    }

    private func actionTitle(_ confirmed: StorageCleanupRequest) -> LocalizedStringResource {
        return confirmed.readers.isEmpty ? .init("清理", table: "Storage") : .init("关闭并清理", table: "Storage")
    }
}
