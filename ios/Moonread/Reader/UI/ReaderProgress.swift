import SwiftUI

struct ReaderProgressControls: View {
    @Bindable var session: ReaderSession
    let didNavigate: () -> Void
    @Environment(\.theme) private var theme
    @State private var percentage = 0.0
    @State private var input = ""
    @State private var preview: ReadingLocation?
    @State private var previous: ChapterInfo?
    @State private var next: ChapterInfo?
    @State private var error: String?
    @State private var locating = false
    @State private var scrubbing = false
    @State private var isEditing = false
    @State private var locationTask: Task<Void, Never>?
    @FocusState private var editingPercentage: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(scrubbing ? (preview?.chapter?.title ?? session.chapter?.title ?? "") : (session.chapter?.title ?? session.book?.title ?? ""))
                    .lineLimit(1).foregroundStyle(Color(uiColor: theme.ink))
                Spacer(minLength: 12)
                if locating { LoadingActivity(size: 22, waitingLabel: "正在定位") }
                if !session.incomplete {
                    if isEditing {
                        TextField("百分比", text: $input).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing).frame(width: 64)
                            .focused($editingPercentage).keyboardInputRegion()
                            .accessibilityIdentifier("readingPercentageInput")
                            .submitLabel(.go).onSubmit(enterPercentage)
                            .onAppear { editingPercentage = true }
                        Button("前往", systemImage: "arrow.right", action: enterPercentage)
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                            .keyboardInputRegion()
                            .accessibilityIdentifier("confirmReadingPercentage")
                    } else {
                        Button { input = String(format: "%.1f", percentage); isEditing = true } label: {
                            // A quiet capsule marks the value as editable inside a 44pt target.
                            Text(percentage / 100, format: .percent.precision(.fractionLength(1)))
                                .monospacedDigit()
                                .padding(.horizontal, LayoutTokens.compact).padding(.vertical, 4)
                                .background(Color(uiColor: theme.input), in: .capsule)
                                .frame(minHeight: LayoutTokens.hit).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(Color(uiColor: theme.ink))
                            .keyboardInputRegion().accessibilityIdentifier("editReadingPercentage")
                    }
                }
            }.font(.subheadline)
            HStack(spacing: 12) {
                Button { if let previous { jump(previous.startUtf8) } } label: {
                    Text("上一章").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }.disabled(previous == nil).accessibilityIdentifier("previousChapter")
                if !session.incomplete {
                    Slider(value: $percentage, in: 0...100, onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { navigate(percentage: percentage) }
                    }) { Text("阅读进度") }.accessibilityIdentifier("readingPositionSlider")
                } else { Spacer() }
                Button { if let next { jump(next.startUtf8) } } label: {
                    Text("下一章").frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }.disabled(next == nil).accessibilityIdentifier("nextChapter")
            }.font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(Color(uiColor: theme.destructive)) }
        }
        .padding(.horizontal, LayoutTokens.page).padding(.top, LayoutTokens.content)
        .disabled(locating).dismissKeyboardOnOutsideTap($editingPercentage)
        .accessibilityElement(children: .contain).accessibilityIdentifier("readerProgressControls")
        .onDisappear { locationTask?.cancel() }
        .onChange(of: editingPercentage) { _, focused in if !focused { isEditing = false } }
        .onChange(of: session.anchor, initial: true) { _, offset in
            if !scrubbing, !isEditing { percentage = Double(offset) / Double(max(1, session.book?.byteCount ?? 0)) * 100 }
        }
        .task(id: session.chapter?.startUtf8) {
            session.synchronizeHistory()
            guard let id = session.readingID else { return }
            do {
                let previous = try await ReaderService.shared.adjacentChapter(id, offset: session.anchor, forward: false)
                let next = try await ReaderService.shared.adjacentChapter(id, offset: session.anchor, forward: true)
                guard !Task.isCancelled else { return }
                self.previous = previous; self.next = next
            } catch { if !Task.isCancelled { self.error = ReaderMessages.error(error) } }
        }
        .task(id: percentage) {
            guard scrubbing, let id = session.readingID, !session.incomplete else { return }
            do {
                try await Task.sleep(for: .milliseconds(60))
                let target = try await ReaderService.shared.location(id, percentage: percentage)
                if !Task.isCancelled { preview = target }
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = ReaderMessages.error(error) } }
        }
    }

    private func enterPercentage() {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized), value.isFinite, (0...100).contains(value) else {
            error = String(localized: "请输入 0 到 100 之间的百分比。"); return
        }
        editingPercentage = false; percentage = value; navigate(percentage: value)
    }
    private func navigate(percentage: Double) {
        guard !locating, let id = session.readingID else { return }
        locating = true
        locationTask = Task {
            defer { locating = false }
            do {
                let value = try await ReaderService.shared.location(id, percentage: percentage)
                guard !session.isLeaving, !Task.isCancelled else { return }
                jump(value.offsetUtf8)
            } catch { self.error = ReaderMessages.error(error) }
        }
    }
    private func jump(_ offset: UInt64) {
        editingPercentage = false; session.browse(to: offset, placement: .start); didNavigate()
    }
}

/// Chapter and search browsing share actions and the same temporary history.
struct ReaderBrowseActions: View {
    let session: ReaderSession
    let showsHistory: Bool
    let showHistory: () -> Void
    let finished: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await session.returnFromBrowse(); if session.browseOrigin == nil { finished() } }
            } label: { Text("回到刚才").frame(minHeight: 44).contentShape(.rect) }
                .accessibilityIdentifier("returnFromBrowse")
            Spacer(minLength: 0)
            if showsHistory {
                Menu {
                    Button("跳转历史", systemImage: "clock", action: showHistory)
                        .disabled(session.history.entries.isEmpty)
                    Button("返回上个位置", systemImage: "arrow.uturn.backward") { moveHistory(-1) }
                        .disabled(session.history.cursor == 0)
                    Button("前进", systemImage: "arrow.uturn.forward") { moveHistory(1) }
                        .disabled(Int(session.history.cursor) + 1 >= session.history.entries.count)
                } label: {
                    Text("历史").font(.caption).frame(minWidth: 44, minHeight: 44).contentShape(.rect)
                }.accessibilityIdentifier("readingHistoryMenu")
            } else { ThemedDivider().frame(height: 16) }
            Spacer(minLength: 0)
            Button {
                Task { await session.continueReading(); if session.browseOrigin == nil { finished() } }
            } label: { Text("从这里继续读").frame(minHeight: 44).contentShape(.rect) }
                .accessibilityIdentifier("continueFromHere")
        }
        .font(.subheadline).disabled(session.navigating)
        .onAppear { session.synchronizeHistory() }
    }

    private func moveHistory(_ direction: Int) {
        let index = Int(session.history.cursor) + direction
        guard session.history.entries.indices.contains(index) else { return }
        let visit = session.history.entries[index]
        session.browse(to: visit.offsetUtf8, placement: .start, historyID: visit.id)
    }
}

struct ReaderHistorySheet: View {
    let session: ReaderSession
    let close: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationStack {
            List(session.history.entries, id: \.id) { visit in
                Button {
                    session.browse(to: visit.offsetUtf8, placement: .start, historyID: visit.id); close()
                } label: {
                    HStack {
                        Text(visit.title).foregroundStyle(Color(uiColor: theme.ink))
                        Spacer()
                        if session.history.entries.indices.contains(Int(session.history.cursor)), session.history.entries[Int(session.history.cursor)].id == visit.id {
                            Image(systemName: "checkmark")
                        }
                    }.frame(minHeight: 44)
                }.listRowBackground(Color(uiColor: theme.surface))
            }.themedPage().navigationTitle("跳转历史").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark", action: close).labelStyle(.iconOnly)
                        .accessibilityIdentifier("closeReadingHistory")
                } }
        }
    }
}
