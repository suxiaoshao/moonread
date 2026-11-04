import TipKit
import SwiftUI
import UIKit

extension ReaderScreen {
    var undoCapsule: some View {
        ReaderUndoAction(session: readerSession, tools: readerTools)
    }

    var browsePanel: some View {
        ReaderBrowseActions(session: readerSession, showsHistory: controlsVisible,
                            showHistory: { presentPanel(.history) }, finished: { controlsVisible = false })
            .padding(.horizontal, LayoutTokens.page).padding(.top, LayoutTokens.page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerBrowsePanel")
    }

    func searchContent(details: Bool, readyForInput: Bool = false) -> some View {
        ReaderSearchContent(model: readerTools, session: readerSession, expanded: Binding(get: { searchExpanded }, set: { searchExpanded = $0 }),
                            showsDetails: details, readyForInput: readyForInput,
                            compactHeight: readerDockHeight, showsHistory: controlsVisible,
                            showHistory: { presentPanel(.history) }, closeSearch: closeSearch)
    }

    @ViewBuilder var continuationControl: some View {
        if let message = readerSession.continuationMessage {
            if readerSession.continuationCollapsed {
                Button("同步进度") { readerSession.expandContinuation() }
                    .font(.footnote).buttonStyle(.plain)
                    .foregroundStyle(Color(uiColor: theme.accent))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(uiColor: theme.surface), in: .capsule)
                    .accessibilityIdentifier("showSyncedProgress")
            } else {
                ReadingContinuationBanner(message: message, busy: readerSession.navigating,
                    accept: { Task { await readerSession.acceptSyncedContinuation() } },
                    stay: { readerSession.stayAtLocalPosition() })
            }
        }
    }

    var bottomControls: some View {
        VStack(spacing: 18) {
            if readerSession.incomplete { importStatus }
            HStack(spacing: 0) {
                toolButton("目录", symbol: "list.bullet", id: "showChapters") { openLibrary(.chapters) }
                toolButton("搜索", symbol: "magnifyingglass", id: "showSearch") { presentPanel(.search) }
                toolButton("设置", symbol: "textformat.size", id: "readingSettings", selected: dock == .settings) {
                    selectFooterDock(.settings)
                }
                toolButton("更多", symbol: "ellipsis", id: "readerMore", selected: dock == .more) {
                    selectFooterDock(.more)
                }
            }
            .labelStyle(ReaderToolLabelStyle())
            .buttonStyle(.plain)

        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerBottomControls")
    }

    private func toolButton(_ title: LocalizedStringKey, symbol: String, id: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .foregroundStyle(Color(uiColor: selected ? theme.accent : theme.ink))
                .frame(maxWidth: .infinity, minHeight: 56).contentShape(.rect)
        }.accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 更多 replaces the dock content like quick settings. Its actions use the same
    /// label style, columns and targets as the tools below; at accessibility sizes the
    /// same labels stack as rows so they stay readable.
    var moreContent: some View {
        ReaderMoreContent(session: readerSession, openLibrary: openLibrary, presentPanel: presentPanel, automaticReading: openAutomaticReading, changeEncoding: changeEncoding)
    }
    func automaticContent(expanded: Bool) -> some View {
        ReaderAutoReadingContent(state: automatic, mode: readerSession.settings?.mode ?? .scroll,
            speed: Binding(get: { readerSession.settings?.autoReadingSpeed ?? autoReadingControl().defaultValue }, set: { value in
                guard var settings = readerSession.settings else { return }
                settings.autoReadingSpeed = value; readerSession.updateSettings(settings)
            }), expanded: expanded, collapse: { attachmentExpanded = false }, close: closeAutomaticReading,
            canStart: readerSession.opening.phase == .reading && readerSession.window != nil && !readerSession.showingCover
                && !readerSession.isLoading && !readerSession.navigating && readerSession.error == nil,
            start: requestAutomaticStart, end: { automatic.end(); closeAutomaticReading() }, retry: {
                automatic.retrying()
                readerSession.retryPreparation()
                readerSession.viewportAccess.controller?.requestedFrontiers.reset()
                readerSession.viewportAccess.controller?.requestMore(.forward)
            })
            .accessibilityAction(named: Text("展开自动阅读")) { attachmentExpanded = true }
    }

}
