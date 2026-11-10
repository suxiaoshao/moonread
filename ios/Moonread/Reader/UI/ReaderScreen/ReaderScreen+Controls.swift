import TipKit
import SwiftUI
import UIKit

extension ReaderScreen {
    var undoCapsule: some View {
        ReaderUndoAction(session: readerSession, tools: readerTools)
    }

    func browsePanel(_ snapshot: ReaderRenderSnapshot) -> some View {
        ReaderBrowseActions(session: readerSession, showsHistory: snapshot.controls,
            showHistory: { sendTool(.open(.history), from: snapshot.context) },
            perform: { sendTool($0, from: snapshot.context) })
            .padding(.horizontal, LayoutTokens.page).padding(.top, LayoutTokens.page)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("readerBrowsePanel")
    }

    func searchContent(_ snapshot: ReaderRenderSnapshot, details: Bool, readyForInput: Bool = false) -> some View {
        let context = snapshot.context
        return ReaderSearchContent(model: readerTools, session: readerSession,
            expanded: Binding(get: { snapshot.expanded }, set: { sendTool($0 ? .expand : .collapse, from: context) }),
            showsDetails: details, readyForInput: readyForInput, compactHeight: readerDockHeight, showsHistory: snapshot.controls,
            showHistory: { sendTool(.open(.history), from: context) }, closeSearch: { sendTool(.endSearch, from: context) },
            selectTarget: { start, end in navigate(start, end: end, placement: .context, obstruction: readerDockHeight, from: context) },
            perform: { sendTool($0, from: context) })
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

    func bottomControls(_ snapshot: ReaderRenderSnapshot) -> some View {
        let context = snapshot.context
        return
        VStack(spacing: 18) {
            if readerSession.incomplete { importStatus }
            HStack(spacing: 0) {
                toolButton("目录", symbol: "list.bullet", id: "showChapters") { sendTool(.open(.library(.listing(.chapters))), from: context) }
                toolButton("搜索", symbol: "magnifyingglass", id: "showSearch") { sendTool(.openSearch, from: context) }
                toolButton("设置", symbol: "textformat.size", id: "readingSettings", selected: snapshot.compact == .settings) {
                    sendTool(.quick(.settings), from: context)
                }
                toolButton("更多", symbol: "ellipsis", id: "readerMore", selected: snapshot.compact == .more) {
                    sendTool(.quick(.more), from: context)
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
    func moreContent(_ snapshot: ReaderRenderSnapshot) -> some View {
        let context = snapshot.context
        return ReaderMoreContent(session: readerSession,
            openLibrary: { sendTool(.open(.library(.listing($0))), from: context) },
            showDetails: { openBookDetails(from: context) },
            automaticReading: { sendTool(.openAutomatic, from: context) },
            listening: { sendTool(.openListening, from: context) },
            changeEncoding: { sendTool(.encode($0), from: context) })
    }

    func automaticContent(_ automatic: ReaderAutoReading, snapshot: ReaderRenderSnapshot, expanded: Bool) -> some View {
        let context = snapshot.context
        return ReaderAutoReadingContent(state: automatic, mode: readerSession.settings?.mode ?? .scroll,
            speed: Binding(get: { readerSession.settings?.autoReadingSpeed ?? autoReadingControl().defaultValue }, set: { value in
                guard var settings = readerSession.settings else { return }
                settings.autoReadingSpeed = value; readerSession.updateSettings(settings)
            }), expanded: expanded, collapse: { sendTool(.collapse, from: context) }, close: { sendTool(.hideAccessory, from: context) },
            canStart: readerSession.opening.phase == .reading && readerSession.window != nil && !readerSession.showingCover
                && !readerSession.isLoading && !readerSession.navigating && readerSession.error == nil,
            start: { sendTool(.startAutomatic, from: context) }, end: { sendTool(.endAutomatic, from: context) }, retry: {
                automatic.retrying()
                readerSession.retryPreparation()
                readerSession.viewportAccess.controller?.requestedFrontiers.reset()
                readerSession.viewportAccess.controller?.requestMore(.forward)
            })
            .accessibilityAction(named: Text("展开自动阅读")) { sendTool(.expand, from: context) }
    }

}
