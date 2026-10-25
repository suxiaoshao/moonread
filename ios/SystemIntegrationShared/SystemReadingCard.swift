import SwiftUI

/// Stateless content shared by the real Widget and its synthetic settings preview.
struct SystemReadingCard: View {
    let book: SystemReadingSnapshot.Book?
    var specificBook = false
    var wide = false
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            if wide { cover.frame(width: 64, height: 88) }
            VStack(alignment: .leading, spacing: 8) {
                if !wide { Image(systemName: "book.closed").font(.title3).foregroundStyle(.tint).accessibilityHidden(true) }
                if let book {
                    Text(verbatim: book.title).font(.headline).lineLimit(wide ? 2 : 3)
                    Spacer(minLength: 0)
                    if let progress = book.progress {
                        Text(progress / 100, format: .percent.precision(.fractionLength(1))).font(.subheadline).monospacedDigit()
                        ProgressView(value: progress, total: 100).accessibilityHidden(true)
                    }
                    Text(book.availability == .reconnectRequired ? "打开月读查找此书" : "继续阅读")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("打开月读继续阅读").font(.headline).lineLimit(3)
                    if specificBook { Text("打开月读查找此书").font(.caption).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.tint.opacity(0.12))
            if let book { Text(String(book.title.prefix(1))).font(.largeTitle).foregroundStyle(.tint) }
            else { Image(systemName: "book.closed").font(.largeTitle).foregroundStyle(.tint) }
        }.accessibilityHidden(true)
    }
}
