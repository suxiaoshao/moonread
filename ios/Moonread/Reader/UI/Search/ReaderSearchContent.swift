import SwiftUI
import UIKit

struct ReaderSearchContent: View {
    @Bindable var model: ReaderToolsModel
    let session: ReaderSession
    @Binding var expanded: Bool
    let showsDetails: Bool
    let readyForInput: Bool
    let compactHeight: CGFloat
    let showsHistory: Bool
    let showHistory: () -> Void
    let closeSearch: () -> Void
    let selectTarget: (UInt64, UInt64) -> Void
    @Environment(\.moonreadReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    private var panelAnimation: Animation { MotionTokens.panel(reduced: reduceMotion) }
    private var activeIndex: Int? {
        guard let range = session.focusRange else { return nil }
        return model.hits.firstIndex { $0.startUtf8 == range.startUtf8 && $0.endUtf8 == range.endUtf8 }
    }

    var body: some View {
        Group {
            if showsDetails {
                ReaderSearchPage(model: model, session: session, expanded: expanded, readyForInput: readyForInput,
                                 selectHit: select, collapseSearch: collapse, closeSearch: close)
            } else { searchCapsule }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerSearchPanel")
    }

    private var searchCapsule: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Button { withAnimation(panelAnimation) { expanded = true } } label: {
                    HStack(spacing: 10) {
                        Group {
                            if model.searching {
                                LoadingActivity(size: 18, fraction: model.searchProgress, progressLabel: "搜索进度")
                            } else {
                                Image(systemName: "magnifyingglass").foregroundStyle(Color(uiColor: theme.accent))
                            }
                        }.frame(width: 44, height: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.query.isEmpty ? String(localized: "搜索这本书") : model.query)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            if let index = activeIndex {
                                Text("第 \(index + 1) 处，共 \(model.hits.count) 处")
                                    .font(.caption).monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                            } else {
                                Text("已找到 \(model.hits.count) 处").font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain).accessibilityLabel("展开搜索结果").accessibilityIdentifier("expandSearch")
                Button("上一个结果", systemImage: "chevron.up") { moveResult(-1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(session.navigating || (activeIndex ?? 0) == 0).accessibilityIdentifier("previousSearchHit")
                Button("下一个结果", systemImage: "chevron.down") { moveResult(1) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .disabled(session.navigating || model.hits.isEmpty || (activeIndex.map { $0 + 1 >= model.hits.count } ?? false))
                    .accessibilityIdentifier("nextSearchHit")
                if session.browseOrigin != nil, session.listening.active { closeButton }
            }
            if session.browseOrigin != nil {
                ReaderBrowseActions(session: session, showsHistory: showsHistory, showHistory: showHistory, finished: close)
            } else {
                HStack {
                    Spacer()
                    closeButton
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)
        .accessibilityElement(children: .contain).accessibilityIdentifier("searchCapsule")
    }

    private var closeButton: some View {
        SystemToolbarButton("结束搜索", role: .close, action: close)
            .labelStyle(.iconOnly).frame(width: 44, height: 44)
            .tint(Color(uiColor: theme.ink)).accessibilityIdentifier("closeCollapsedSearch")
    }

    private func collapse() {
        withAnimation(panelAnimation) { expanded = false }
    }
    private func close() { closeSearch() }
    private func select(_ hit: SearchHit) {
        model.searchListPosition = hit.startUtf8
        selectTarget(hit.startUtf8, hit.endUtf8)
    }
    private func moveResult(_ direction: Int) {
        let index = activeIndex.map { $0 + direction } ?? 0
        guard model.hits.indices.contains(index) else { return }
        let hit = model.hits[index]
        model.searchListPosition = hit.startUtf8
        select(hit)
    }


}
