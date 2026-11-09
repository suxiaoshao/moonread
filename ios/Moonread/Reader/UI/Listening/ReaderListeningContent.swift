import AVFoundation
import SwiftUI

struct ReaderListeningContent: View {
    let session: ListeningSession
    var showsHeader = true
    var navigatesToVoices = false
    @State private var rateDraft: Double?
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
            Group {
                if navigatesToVoices {
                    NavigationLink { ListeningVoicesView(session: session) } label: { voiceLabel }
                } else { Button(action: openVoices) { voiceLabel } }
            }.buttonStyle(.plain).accessibilityIdentifier("listeningVoices")
            VStack(alignment: .leading) {
                Text("语速").font(.subheadline)
                Slider(value: Binding(get: { rateDraft ?? Double(session.rate) }, set: { rateDraft = $0 }),
                    in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate),
                    label: { Text("语速") }, minimumValueLabel: { Text("慢") }, maximumValueLabel: { Text("快") },
                    onEditingChanged: { editing in
                        if !editing, let rateDraft { session.setRate(Float(rateDraft)); self.rateDraft = nil }
                    })
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
    private var voiceLabel: some View {
        HStack {
            Text("声音"); Spacer()
            Text(session.voice?.name ?? String(localized: "选择声音")).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1)
            if !navigatesToVoices { Image(systemName: "chevron.right").font(.caption) }
        }.contentShape(.rect)
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
            Section { } footer: {
                Text("在系统设置的“辅助功能 → 朗读内容 → 声音”中管理声音。此处只列出系统可用声音，不会自动下载。")
                    .foregroundStyle(Color(uiColor: theme.secondary))
            }
        }
        .overlay {
            if voices.isEmpty { ContentUnavailableView("没有可用的系统声音", systemImage: "speaker.slash") }
            else if filtered.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .searchable(text: $search, prompt: Text("搜索声音"))
        .navigationTitle("声音").navigationBarTitleDisplayMode(.inline).themedPage()
        .onAppear { session.voiceSelectionPresented = true; session.pause(); voices = ListeningSession.voices }
        .onDisappear { session.voiceSelectionPresented = false; session.stopPreview() }
    }
    private func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: String(localized: "优质")
        case .enhanced: String(localized: "增强")
        default: String(localized: "标准")
        }
    }
}

/// Its background measures the largest compact state without displaying an empty
/// return row. Following/detaching therefore does not repeatedly repaginate text.
struct ReaderListeningCompact: View {
    let session: ListeningSession
    let expand: () -> Void
    let resume: () -> Void
    let returnToSpeech: () -> Void
    let measured: (CGFloat) -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: LayoutTokens.compact) {
            controls
            if session.following == .detached { returnButton }
            if let notice = session.notice { Text(notice).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
        }
        .padding(.horizontal, LayoutTokens.content).padding(.vertical, LayoutTokens.compact)
        .background {
            VStack(spacing: LayoutTokens.compact) {
                controls; returnButton
                if let notice = session.notice { Text(notice).font(.footnote).foregroundStyle(Color(uiColor: theme.secondary)) }
            }
                .padding(.horizontal, LayoutTokens.content).padding(.vertical, LayoutTokens.compact)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
                .hidden().accessibilityHidden(true).allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("listeningCompact")
    }
    private var controls: some View {
        HStack(spacing: LayoutTokens.control) {
            Button(action: expand) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.phase == .preparing ? "正在准备听书" : session.running ? "正在朗读" : "已暂停").font(.subheadline.weight(.semibold))
                    if !session.chapter.isEmpty { Text(session.chapter).font(.caption).foregroundStyle(Color(uiColor: theme.secondary)).lineLimit(1) }
                }.frame(maxWidth: .infinity, minHeight: LayoutTokens.hit, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.plain).accessibilityLabel("展开听书控制")
            if session.phase == .preparing { ProgressView() }
            Button { if session.running { session.pause() } else { resume() } } label: {
                Image(systemName: session.running ? "pause.fill" : "play.fill").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit)
            }.accessibilityLabel(session.running ? "暂停" : "继续").accessibilityIdentifier("compactListeningPlayback")
            Button(action: expand) { Image(systemName: "chevron.up").frame(minWidth: LayoutTokens.hit, minHeight: LayoutTokens.hit) }
                .accessibilityLabel("展开听书控制")
        }.foregroundStyle(Color(uiColor: theme.ink))
    }
    private var returnButton: some View {
        Button(action: returnToSpeech) { Label("回到朗读处", systemImage: "scope").frame(maxWidth: .infinity, minHeight: LayoutTokens.hit) }
            .accessibilityIdentifier("returnToSpeech")
    }
}
