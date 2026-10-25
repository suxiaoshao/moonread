import SwiftUI
import UIKit

struct ReaderPreparationContent: View {
    let session: ReaderSession
    let route: ReaderRoute
    var statusOnly = false
    let changeEncoding: (String?) -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        if statusOnly { importStatus } else { preparationView }
    }
    private var preparationFraction: Double? {
        guard let state = session.snapshot, state.sourceByteCount > 0 else { return nil }
        return min(1, Double(state.sourceBytesRead) / Double(state.sourceByteCount))
    }

    private var preparationView: some View {
        ReaderTitlePage(title: session.book?.title ?? route.title)
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                if session.preparing && session.error == nil {
                    if session.opening.showsProgress {
                        HStack(spacing: 12) {
                            LoadingActivity(size: 24, fraction: preparationFraction, delay: .zero)
                            Text("正在准备正文").font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            Button("暂停准备", systemImage: "pause", action: session.pause).labelStyle(.iconOnly)
                        }
                    }
                } else {
                    Text(session.snapshot?.phase == .paused ? String(localized: "准备已暂停") : String(localized: "暂时无法准备正文"))
                        .font(.headline)
                    if let error = session.snapshot?.error.map { ReaderMessages.error($0) } ?? session.error {
                        Text(error).font(.subheadline).foregroundStyle(Color(uiColor: theme.secondary))
                            .multilineTextAlignment(.center)
                    }
                    if session.snapshot != nil {
                        Button("继续准备", action: session.resume).buttonStyle(.bordered)
                        encodingMenu
                    } else {
                        Button("重试") { Task { await session.retry(route) } }.buttonStyle(.bordered)
                    }
                }
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: theme.paper))
                .padding(.bottom, 12)
            }
        .accessibilityIdentifier("preparingBook")
    }

    private var importStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if session.preparing { LoadingActivity(size: 28, fraction: preparationFraction) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.preparing ? String(localized: "正在准备后续内容") : (session.snapshot?.phase == .failed ? String(localized: "准备失败") : String(localized: "准备已暂停")))
                        .font(.subheadline.weight(.medium))
                    if let fraction = preparationFraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).monospacedDigit().foregroundStyle(Color(uiColor: theme.secondary))
                    }
                }
                Spacer()
                Button(session.preparing ? String(localized: "暂停") : String(localized: "继续")) {
                    if session.preparing { session.pause() } else { session.resume() }
                }
                    .font(.subheadline).frame(minHeight: 44)
            }
            if let message = session.snapshot?.error {
                Text(ReaderMessages.error(message)).font(.caption).foregroundStyle(Color(uiColor: theme.secondary))
                HStack {
                    Button("重新准备") { session.restart() }
                    Spacer()
                    encodingMenu
                }.font(.caption)
            }
        }
        .padding(16)
        .background(theme.floatingBackground(.thinMaterial), in: .rect(cornerRadius: LayoutTokens.floatingRadius))
        .accessibilityIdentifier("importStatus")
    }

    private var encodingMenu: some View {
        ReaderEncodingMenu(isRestarting: session.restartingEncoding, select: changeEncoding)
    }

}
