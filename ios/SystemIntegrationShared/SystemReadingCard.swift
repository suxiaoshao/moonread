import SwiftUI
import WidgetKit
import CoreText

/// One display decision for the App, widgets and system thumbnails. Providers
/// supply decoded user images; missing assets never become a second cover fact.
struct SystemBookCover: View {
    let title: String
    var compact = false
    var contentSHA256: String? = nil
    var author: String? = nil
    var userImage: UIImage? = nil
    var contentMode: ContentMode = .fill
    var rendersSynchronously = false
    var body: some View {
        GeometryReader { geometry in
            Group {
                if let userImage {
                    Image(uiImage: userImage).resizable().widgetAccentedRenderingMode(.desaturated)
                        .aspectRatio(contentMode: contentMode).accessibilityIdentifier("bookCoverImage")
                } else {
                    SystemDefaultBookCover(title: title, compact: compact, contentSHA256: contentSHA256, author: author, rendersSynchronously: rendersSynchronously)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .clipShape(.rect(cornerRadius: compact ? 3 : 6))
        }.accessibilityHidden(true)
    }
}

/// The same text-cover drawing is used by App shelves, Spotlight and widgets.
private struct SystemDefaultBookCover: View {
    let title: String
    var compact = false
    var contentSHA256: String? = nil
    var author: String? = nil
    var rendersSynchronously = false
    @State private var chineseFace = SystemInstalledFont.coverFace
    var body: some View {
        Group {
            if let id = presetCoverID(contentSHA256: contentSHA256) {
                SystemPresetBookCover(id: id, title: title, author: author, chineseFace: chineseFace, rendersSynchronously: rendersSynchronously)
            } else { textCover }
        }.accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name(kCTFontManagerRegisteredFontsChangedNotification as String)).receive(on: DispatchQueue.main)) { _ in chineseFace = SystemInstalledFont.coverFace }
    }
    private var textCover: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: compact ? 3 : 6).fill(Color(uiColor: SystemCoverTypography.fallbackPaper))
            Rectangle().fill(Color(uiColor: SystemCoverTypography.fallbackInk).opacity(0.18)).frame(width: 1).padding(.leading, compact ? 4 : 7)
            GeometryReader { geometry in
              Text(verbatim: title)
                .font(Font(SystemCoverTypography.chineseFont(face: chineseFace, size: titleSize(width: geometry.size.width))))
                .foregroundStyle(Color(uiColor: SystemCoverTypography.fallbackInk)).multilineTextAlignment(.center).lineLimit(compact ? 4 : 5)
                .minimumScaleFactor(0.8).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(compact ? 6 : 12)
        }.accessibilityHidden(true)
    }
    private func titleSize(width: CGFloat) -> CGFloat {
        let base: CGFloat = compact ? 10 : UIFont.preferredFont(forTextStyle: .headline).pointSize
        let font = SystemCoverTypography.chineseFont(face: chineseFace, size: base)
        // Fit whole Latin words before wrapping, rather than splitting a word
        // across cover lines. CJK continues to use its natural character wraps.
        let longest = title.split(whereSeparator: \.isWhitespace).filter { $0.unicodeScalars.allSatisfy(\.isASCII) }
            .map { ($0.description as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return longest > width && longest > 0 ? base * width / longest : base
    }
}

struct SystemWidgetColors {
    let tokens: SystemReadingSnapshot.Appearance.Tokens?
    var monochrome = false
    private func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
    var ink: Color { !monochrome ? tokens.map { color($0.ink) } ?? .primary : .primary }
    var secondary: Color { !monochrome ? tokens.map { color($0.secondary) } ?? .secondary : .secondary }
    var accent: Color { !monochrome ? tokens.map { color($0.accent) } ?? .accentColor : .primary }
    var accentSurface: Color { !monochrome ? tokens.map { color($0.accentSurface) } ?? .primary.opacity(0.08) : .primary.opacity(0.08) }
    var border: Color { !monochrome ? tokens.map { color($0.border) } ?? .primary.opacity(0.15) : .primary.opacity(0.15) }
    var paper: Color { tokens.map { color($0.paper) } ?? Color(uiColor: .systemBackground) }
    var canvas: Color { tokens.map { color($0.canvas) } ?? Color(uiColor: .secondarySystemBackground) }
}

struct SystemWidgetBrand: View {
    let title: LocalizedStringKey
    let colors: SystemWidgetColors
    var body: some View {
        Label { Text("月读 · \(Text(title))") } icon: { Image(systemName: "moon") }
            .font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
    }
}

struct SystemWidgetCover: View {
    let book: SystemReadingSnapshot.Book
    let colors: SystemWidgetColors
    var file: SystemReadingSnapshotFile? = nil
    var compact = true
    var body: some View {
        let image = book.coverThumbnail.flatMap { (file ?? (try? .shared()))?.coverData($0) }.flatMap { UIImage(data: $0) }
        SystemBookCover(title: book.title, compact: compact, contentSHA256: SystemReadingLink.contentSHA256(bookID: book.id), author: book.author, userImage: image)
    }
}

/// A: paper and cover. The entire continuation widget is one destination.
struct SystemReadingCard: View {
    let book: SystemReadingSnapshot.Book?
    var specificBook = false
    var wide = false
    var appearance: SystemReadingSnapshot.Appearance? = nil
    var monochrome = false
    var backgroundRemoved = false
    @Environment(\.colorScheme) private var scheme
    private var colors: SystemWidgetColors { .init(tokens: scheme == .dark ? appearance?.dark : appearance?.light, monochrome: monochrome) }
    var body: some View {
        Group {
            if let book {
                if backgroundRemoved {
                    HStack(spacing: 12) {
                        SystemWidgetCover(book: book, colors: colors).frame(width: 48, height: 70)
                        VStack(alignment: .leading, spacing: 6) {
                            title(book).font(.title3)
                            percentage(book).font(.title2.weight(.semibold))
                            chapter(book).font(.caption2)
                        }
                    }
                } else if wide {
                    GeometryReader { geometry in
                        HStack(spacing: 16) {
                            SystemWidgetCover(book: book, colors: colors, compact: false)
                                .frame(width: min(88, geometry.size.width * 0.27), height: max(60, min(128, geometry.size.height)))
                            VStack(alignment: .leading, spacing: 7) {
                                SystemWidgetBrand(title: "继续阅读", colors: colors)
                                title(book).font(.headline)
                                chapter(book).font(.caption)
                                Spacer(minLength: 0)
                                progress(book)
                                continuation(book)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SystemWidgetBrand(title: "继续阅读", colors: colors)
                        HStack(spacing: 10) {
                            SystemWidgetCover(book: book, colors: colors).frame(width: 40, height: 58)
                            VStack(alignment: .leading, spacing: 5) {
                                title(book).font(.subheadline.weight(.semibold))
                                chapter(book).font(.caption2)
                                percentage(book).font(.caption2)
                            }
                        }
                        Spacer(minLength: 0)
                        if let value = book.progress { SystemWidgetProgress(value: value, colors: colors) }
                        continuation(book)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    SystemWidgetBrand(title: "继续阅读", colors: colors)
                    Image(systemName: "book.closed").font(.title2).foregroundStyle(colors.accent)
                    Text(specificBook ? "打开月读查找此书" : "打开月读继续阅读").font(.headline).foregroundStyle(colors.ink)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }.accessibilityElement(children: .combine)
    }
    private func title(_ book: SystemReadingSnapshot.Book) -> some View {
        Text(verbatim: book.title).fontDesign(.serif).foregroundStyle(colors.ink).lineLimit(2)
    }
    @ViewBuilder private func chapter(_ book: SystemReadingSnapshot.Book) -> some View {
        if book.availability == .reconnectRequired {
            Text("需要重新连接书架", tableName: "SystemReading").foregroundStyle(colors.secondary).lineLimit(1)
        } else if let chapter = book.chapterLabel { Text(verbatim: chapter).foregroundStyle(colors.secondary).lineLimit(1) }
    }
    @ViewBuilder private func percentage(_ book: SystemReadingSnapshot.Book) -> some View {
        if let value = book.progress { Text(value / 100, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(colors.accent) }
    }
    @ViewBuilder private func progress(_ book: SystemReadingSnapshot.Book) -> some View {
        if let value = book.progress {
            VStack(spacing: 5) {
                HStack { Text("全书进度").foregroundStyle(colors.secondary); Spacer(); percentage(book) }.font(.caption2)
                SystemWidgetProgress(value: value, colors: colors)
            }
        }
    }
    private func continuation(_ book: SystemReadingSnapshot.Book) -> some View {
        HStack(spacing: 4) {
            if book.availability == .reconnectRequired { Text("打开月读处理", tableName: "SystemReading") }
            else { Text("继续阅读") }
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
        }
            .font(.caption2.weight(.semibold)).foregroundStyle(colors.accent).lineLimit(1)
            .frame(maxWidth: .infinity).padding(.vertical, 6).background(colors.accentSurface, in: .capsule)
    }
}

struct SystemRecentReadingCard: View {
    let books: [SystemReadingSnapshot.Book]
    let colors: SystemWidgetColors
    var large = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SystemWidgetBrand(title: "最近阅读", colors: colors)
            if books.isEmpty {
                Text("打开月读继续阅读").font(.headline).foregroundStyle(colors.ink).frame(maxHeight: .infinity)
            } else if large {
                VStack(spacing: 0) {
                    ForEach(books) { book in
                        Link(destination: SystemReadingLink.book(book.id) ?? SystemReadingLink.resume) {
                            HStack(spacing: 12) {
                                SystemWidgetCover(book: book, colors: colors).frame(width: 32, height: 46)
                                labels(book)
                                if let value = book.progress { Text(value / 100, format: .percent.precision(.fractionLength(0))).font(.caption).foregroundStyle(colors.accent).monospacedDigit() }
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(colors.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain)
                        if book.id != books.last?.id { Rectangle().fill(colors.border).frame(height: 0.5).accessibilityHidden(true) }
                    }
                }
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 16) {
                    ForEach(books) { book in
                        Link(destination: SystemReadingLink.book(book.id) ?? SystemReadingLink.resume) {
                            HStack(spacing: 10) {
                                SystemWidgetCover(book: book, colors: colors).frame(width: 38, height: 56)
                                VStack(alignment: .leading, spacing: 5) {
                                    labels(book)
                                    if let value = book.progress { Text(value / 100, format: .percent.precision(.fractionLength(0))).font(.caption2).foregroundStyle(colors.secondary) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain)
                    }
                }.frame(maxHeight: .infinity)
            }
            HStack {
                Text("按最近阅读顺序").foregroundStyle(colors.secondary)
                Spacer(minLength: 4)
                Link(destination: SystemReadingLink.recent) { Text("查看全部 ›").foregroundStyle(colors.accent) }
            }.font(.caption2)
        }
    }
    private func labels(_ book: SystemReadingSnapshot.Book) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: book.title).font(.subheadline.weight(.semibold)).foregroundStyle(colors.ink).lineLimit(1)
            if let chapter = book.chapterLabel { Text(verbatim: chapter).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Native linear progress; WidgetKit supplies its rendering environment.
struct SystemWidgetProgress: View {
    let value: Double
    let colors: SystemWidgetColors
    var body: some View {
        ProgressView(value: min(100, max(0, value)), total: 100)
            .progressViewStyle(.linear).tint(colors.accent).accessibilityHidden(true)
    }
}
