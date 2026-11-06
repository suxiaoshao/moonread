import AVFoundation
import SwiftUI

struct ReaderListeningContent: View {
    let session: ListeningSession
    var showsHeader = true
    let canStart: Bool
    let openVoices: () -> Void
    let close: () -> Void
    let start: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader { HStack {
                Text("听书").font(.headline)
                Spacer()
                SystemToolbarButton("关闭", role: .close, action: close).labelStyle(.iconOnly)
                    .accessibilityIdentifier("closeListening")
            } }
            if session.active {
                Text(session.title).font(.headline).lineLimit(2)
                if !session.chapter.isEmpty { Text(session.chapter).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(2) }
            }
            Button(action: openVoices) {
                HStack {
                    Text("声音")
                    Spacer()
                    Text(session.voice?.name ?? String(localized: "选择声音")).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
                    Image(systemName: "chevron.right").font(.caption)
                }.contentShape(.rect)
            }.buttonStyle(.plain).accessibilityIdentifier("listeningVoices")
            VStack(alignment: .leading) {
                Text("语速").font(.subheadline)
                Slider(value: Binding(get: { Double(session.rate) }, set: { session.setRate(Float($0)) }),
                       in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate)) {
                    Text("语速")
                } minimumValueLabel: { Text("慢") } maximumValueLabel: { Text("快") }
                .accessibilityIdentifier("listeningRate")
            }
            HStack {
                Text("定时")
                Spacer()
                Menu {
                    ForEach([0, 15, 30, 60], id: \.self) { minutes in
                        Button { session.setTimer(minutes) } label: {
                            if minutes == session.timerMinutes { Label(timerLabel(minutes), systemImage: "checkmark") }
                            else { Text(timerLabel(minutes)) }
                        }
                    }
                } label: { Text(timerLabel(session.timerMinutes)) }
                .accessibilityIdentifier("listeningTimer")
            }
            if let notice = session.notice { Text(notice).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
            if session.phase == .preparing { ProgressView("正在准备听书") }
            if session.phase == .idle {
                Text("从当前段开始，听看共用阅读位置").font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
                playButton(title: "开始").disabled(!canStart)
            } else {
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Button { session.end() } label: { Text("结束").frame(maxWidth: .infinity) }
                        .buttonStyle(ThemedSecondaryButtonStyle()).controlSize(.large).accessibilityIdentifier("endListening")
                    if session.running {
                        Button { session.pause() } label: { Text("暂停").frame(maxWidth: .infinity) }
                            .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("pauseListening")
                    } else { playButton(title: "继续").disabled(!canStart) }
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
            .accessibilityElement(children: .contain).accessibilityIdentifier("listeningPanel")
    }
    private func playButton(title: LocalizedStringKey) -> some View {
        Button(action: start) { Text(title).frame(maxWidth: .infinity) }
            .buttonStyle(ThemedProminentButtonStyle()).controlSize(.large).accessibilityIdentifier("startListening")
    }
    private func timerLabel(_ minutes: Int) -> String {
        minutes == 0 ? String(localized: "不定时") : String(localized: "\(minutes) 分钟后结束")
    }
}

struct ListeningVoicesView: View {
    let session: ListeningSession
    @State private var search = ""
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @Environment(\.theme) private var theme
    private var filtered: [AVSpeechSynthesisVoice] {
        voices.filter { search.isEmpty || $0.name.localizedStandardContains(search) || $0.language.localizedStandardContains(search) }
    }
    private var languages: [String] { Set(filtered.map(\.language)).sorted() }
    var body: some View {
        List {
            if voices.isEmpty {
                Section { Text("没有可用的系统声音").foregroundStyle(Color(uiColor: theme.secondary)) }
            }
            ForEach(languages, id: \.self) { language in
                Section(Locale.current.localizedString(forIdentifier: language) ?? language) {
                    ForEach(filtered.filter { $0.language == language }, id: \.identifier) { voice in
                        HStack {
                            Button { session.selectVoice(voice) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(voice.name).foregroundStyle(Color(uiColor: theme.ink))
                                        Text(quality(voice)).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                                    }
                                    Spacer()
                                    if session.voiceID == voice.identifier { Image(systemName: "checkmark").foregroundStyle(Color(uiColor: theme.accent)) }
                                }.contentShape(.rect)
                            }.buttonStyle(.plain)
                            Button { session.preview(voice) } label: { Image(systemName: "play.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("试听 \(voice.name)")
                        }.listRowBackground(Color(uiColor: theme.surface)).listRowSeparatorTint(Color(uiColor: theme.separator))
                    }
                }
            }
            Section {
                Text("在系统设置的“辅助功能 → 朗读内容 → 声音”中管理声音。此处只列出系统可用声音，不会自动下载。")
                    .font(.footnote).foregroundStyle(Color(uiColor: theme.secondary))
            }.listRowBackground(Color(uiColor: theme.surface))
        }
        .overlay { if !voices.isEmpty && filtered.isEmpty { ContentUnavailableView.search(text: search) } }
        .searchable(text: $search, prompt: Text("搜索声音"))
        .navigationTitle("声音").navigationBarTitleDisplayMode(.inline).themedPage()
        .onAppear { session.pause(); voices = ListeningSession.voices }
        .onDisappear { session.stopPreview() }
    }
    private func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: String(localized: "优质")
        case .enhanced: String(localized: "增强")
        default: String(localized: "标准")
        }
    }
}
