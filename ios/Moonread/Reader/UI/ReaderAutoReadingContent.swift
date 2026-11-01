import SwiftUI

struct ReaderAutoReadingContent: View {
    let state: ReaderAutoReading
    let mode: ReadingMode
    @Binding var seconds: Double
    let expanded: Bool
    let collapse: () -> Void
    let close: () -> Void
    let canStart: Bool
    let start: () -> Void
    let end: () -> Void
    let retry: () -> Void
    @Environment(\.theme) private var theme
    private var control: ReaderNumberControl { autoReadingControl() }
    private var speedVisible: Bool { mode == .scroll && state.phase != .finished }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if expanded {
                    Button("收起", systemImage: "chevron.down", action: collapse).labelStyle(.iconOnly)
                }
                if state.phase == .preparing { ProgressView().controlSize(.small) }
                Text(expanded ? String(localized: "自动阅读") : title).font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark", action: close).labelStyle(.iconOnly)
                    .accessibilityIdentifier("closeAutoReading")
            }
            if expanded { Text(title).font(.headline) }
            if mode != .scroll {
                Text("自动阅读适用于上下滚动").foregroundStyle(Color(uiColor: theme.secondary))
                Button("开始自动阅读", action: start).disabled(true)
            } else if state.phase == .finished {
                Text("自动阅读已结束，可以向上回看正文").foregroundStyle(Color(uiColor: theme.secondary))
                Button("回到正文", action: close)
            } else {
                if speedVisible {
                    Stepper(value: $seconds, in: control.minimum...control.maximum, step: control.step) {
                        Text("每屏用时 \(Int(seconds)) 秒").monospacedDigit()
                    }.accessibilityIdentifier("autoReadingSpeed")
                    Text("数值越大，滚动越慢。点正文可暂停。")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
                if state.phase == .idle { Text("运行时保持亮屏").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                if state.phase == .preparing {
                    Text("当前位置已保留，准备完成后请点继续。")
                        .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                }
                if state.phase == .failed {
                    Text("读取后续正文失败，当前位置已保留")
                        .foregroundStyle(Color(uiColor: theme.secondary))
                    if let failure = state.failure { Text(failure).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
                }
                HStack {
                    if state.phase != .idle { Button("结束自动阅读", action: end) }
                    Spacer()
                    if state.phase == .failed {
                        Button("重试", action: retry)
                        Button("继续阅读", action: start).disabled(true)
                    } else {
                        Button(action: start) {
                            if state.phase == .idle { Text("开始自动阅读") }
                            else { Text("继续阅读") }
                        }
                        .disabled(!canStart || state.phase == .preparing || state.phase == .starting)
                        .accessibilityIdentifier("startAutoReading")
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .accessibilityElement(children: .contain).accessibilityIdentifier("autoReadingPanel")
    }
    private var title: String {
        switch state.phase {
        case .idle: String(localized: "自动阅读")
        case .starting: String(localized: "正在准备自动阅读")
        case .running: String(localized: "自动阅读中")
        case .paused: String(localized: "自动阅读已暂停")
        case .preparing: String(localized: "正文准备中")
        case .ready: String(localized: "后续正文已准备好")
        case .failed: String(localized: "读取后续正文失败")
        case .finished: String(localized: "已到书末")
        }
    }
}
