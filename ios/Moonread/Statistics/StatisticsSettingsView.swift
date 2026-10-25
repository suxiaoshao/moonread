import SwiftUI
import Charts

struct StatisticsSettingsView: View {
    @State private var enabled = true
    @State private var clearing = false
    @State private var error: String?
    @Environment(\.theme) private var theme
    var body: some View {
        Form {
            Section {
                Toggle("在此设备记录阅读统计", isOn: Binding(get: { enabled }, set: { value in
                    enabled = value
                    Task { do { await StatisticsWriter.shared.drain(); try await ReaderService.shared.setStatisticsEnabled(value) } catch { enabled = !value; self.error = ReaderMessages.error(error) } }
                })).accessibilityIdentifier("statisticsEnabled")
            } footer: { Text("关闭后保留历史统计，只停止此设备的新记录。只记录可见正文活动；锁屏、后台、工具面板和闲置时暂停。") }
                .listRowBackground(Color(uiColor: theme.surface))
            Section {
                Button("清除阅读统计", role: .destructive) { clearing = true }.accessibilityIdentifier("clearStatistics")
                    .foregroundStyle(Color(uiColor: theme.destructive))
            } footer: { Text("清除历史统计不改变记录开关，也不影响小说文件、续读位置、书签和笔记。历史时长无法由旧进度补算。") }
                .listRowBackground(Color(uiColor: theme.surface))
        }.themedPage().navigationTitle("阅读统计设置").navigationBarTitleDisplayMode(.inline)
            .task { enabled = await ReaderService.shared.statisticsPreferences().enabled }
            .confirmationDialog("清除阅读统计？", isPresented: $clearing, titleVisibility: .visible) {
                Button("清除阅读统计", role: .destructive) { Task { do { try await ReaderService.shared.deleteStatistics() } catch { self.error = ReaderMessages.error(error) } } }
            }
            .alert("暂时无法完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }
}
