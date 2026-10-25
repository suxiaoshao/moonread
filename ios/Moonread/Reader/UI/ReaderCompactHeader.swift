import SwiftUI
import UIKit

struct ReaderCompactHeader: View {
    let session: ReaderSession
    let battery: ReaderBattery
    let book: BookInfo
    let readerWidth: CGFloat
    let compactHeaderHeight: CGFloat
    let showControls: () -> Void
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(session.showingCover ? String(localized: "封面") : (session.chapter?.title ?? book.title))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("readingChapter")
                if !session.incomplete && !session.showingCover {
                    Text("·").accessibilityHidden(true)
                    progress(book: book).fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if session.atPreparedEdge {
                Button { showControls() } label: {
                    Text(session.preparing ? String(localized: "后续准备中") : (session.snapshot?.phase == .failed ? String(localized: "查看问题") : String(localized: "继续准备")))
                        .fixedSize()
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("preparedEdge")
            }
            HStack(spacing: 5) {
                TimelineView(.everyMinute) { timeline in
                    Text(timeline.date, format: .dateTime.hour().minute())
                        .monospacedDigit()
                        .accessibilityLabel("当前时间")
                        .accessibilityValue(timeline.date.formatted(.dateTime.hour().minute()))
                        .accessibilityIdentifier("readingClock")
                }
                if let symbol = battery.symbol {
                    Image(systemName: symbol)
                        .accessibilityLabel(battery.accessibilityLabel)
                        .accessibilityIdentifier("readingBattery")
                }
            }
            .fixedSize()
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(uiColor: theme.secondary))
        .padding(.horizontal, ReadingTypography.insets(session.settings ?? defaultReaderSettings(), width: readerWidth).left)
        .frame(height: compactHeaderHeight)
        // The full-screen reader supplies the continuous paper behind this overlay.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerCompactHeader")
        .allowsHitTesting(session.atPreparedEdge)
    }

    private func progress(book: BookInfo) -> some View {
        let fraction = Double(session.anchor) / Double(max(book.byteCount, 1))
        return Text(fraction, format: .percent.precision(.fractionLength(1)))
            .monospacedDigit()
            .accessibilityLabel("阅读进度")
            .accessibilityIdentifier("readingProgress")
            #if DEBUG
            .accessibilityValue(ProcessInfo.processInfo.arguments.contains("--ui-testing")
                                ? String(session.anchor)
                                : fraction.formatted(.percent.precision(.fractionLength(1))))
            #else
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(1))))
            #endif
    }

}
