import SwiftUI
import UIKit

/// Manual choices do not perform detection in Swift. Labels are encoding_rs names;
/// the Rust decoding policy validates and canonicalizes every selected value.
enum ReadingEncodingGroup: String, CaseIterable, Identifiable {
    case simplifiedChinese, traditionalChinese, japanese, korean, westernEuropean, other
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁体中文"
        case .japanese: "日文"
        case .korean: "韩文"
        case .westernEuropean: "西欧"
        case .other: "其他编码"
        }
    }
    var encodings: [String] {
        switch self {
        case .simplifiedChinese: ["gb18030", "GBK"]
        case .traditionalChinese: ["Big5"]
        case .japanese: ["Shift_JIS", "EUC-JP", "ISO-2022-JP"]
        case .korean: ["EUC-KR"]
        case .westernEuropean: ["windows-1252", "ISO-8859-14", "ISO-8859-15", "macintosh"]
        case .other: ["UTF-8", "UTF-16LE", "UTF-16BE", "IBM866", "ISO-8859-2", "ISO-8859-3", "ISO-8859-4",
                      "ISO-8859-5", "ISO-8859-6", "ISO-8859-7", "ISO-8859-8", "ISO-8859-8-I", "ISO-8859-10",
                      "ISO-8859-13", "ISO-8859-16", "KOI8-R", "KOI8-U", "windows-1250", "windows-1251",
                      "windows-1253", "windows-1254", "windows-1255", "windows-1256", "windows-1257",
                      "windows-1258", "windows-874", "x-mac-cyrillic"]
        }
    }
}

struct ReaderEncodingMenu: View {
    var title: LocalizedStringKey = "更换编码重新打开"
    var value: String? = nil
    var symbol: String? = nil
    var isRestarting = false
    let select: (String?) -> Void
    @State private var pendingEncoding: String?
    @Environment(\.theme) private var theme
    var body: some View {
        Menu {
            Button("自动识别") { pendingEncoding = "auto" }
            ForEach(ReadingEncodingGroup.allCases) { group in
                Menu {
                    ForEach(group.encodings, id: \.self) { encoding in
                        Button(encoding) { pendingEncoding = encoding }
                    }
                } label: { Text(group.title) }
            }
        } label: {
            HStack {
                if isRestarting, value == nil {
                    Label("正在重新读取", systemImage: "hourglass")
                } else if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
                if let value {
                    Spacer()
                    if isRestarting {
                        ProgressView().controlSize(.small)
                        Text("正在重新读取")
                    } else {
                        HStack(spacing: 5) {
                            Text(value)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .accessibilityHidden(true)
                        }.foregroundStyle(Color(uiColor: theme.accent))
                    }
                }
            }.contentShape(.rect)
        }
        .menuOrder(.fixed)
        .disabled(isRestarting)
        .onChange(of: isRestarting) { _, busy in if busy { pendingEncoding = nil } }
        .accessibilityLabel(isRestarting ? Text("正在重新读取") : value.map { Text("文字编码，\($0)，可更换") } ?? Text(title))
        .accessibilityIdentifier("readerEncodingMenu")
        .alert("更换文字编码？", isPresented: Binding(get: { pendingEncoding != nil }, set: { if !$0 { pendingEncoding = nil } }), presenting: pendingEncoding) { encoding in
            Button("重新读取") { pendingEncoding = nil; select(encoding == "auto" ? nil : encoding) }
            Button("取消", role: .cancel) { pendingEncoding = nil }
        } message: { _ in
            Text("正文会按新编码重新读取。当前编码下的阅读位置、书签和批注不会带到不同的新正文，原数据会保留。原文件未变时，换回原编码可找回。")
        }
    }
}
