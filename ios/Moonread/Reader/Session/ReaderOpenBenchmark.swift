#if READER_OPEN_DIAGNOSTICS
import SwiftUI

/// Isolated storage; native Button -> LibraryModel.open -> real navigation destination.
@MainActor @Observable
final class ReaderOpenBenchmark {
    var entries: [LibraryEntry] = []
    var error: String?
    private var leases: [ReadingLease] = []
    private var sizes: [String: Int] = [:]
    func prepare() async {
        guard entries.isEmpty else { return }
        guard let session = ReaderOpenDiagnostics.session else {
            error = "请提供有效 UUID：--reader-open-session"
            return
        }
        do {
            let service = ReaderService.shared
            let core = try await service.textCore()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderOpenFixture-" + session)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let small = root.appendingPathComponent("small.txt")
            if !FileManager.default.fileExists(atPath: small.path) {
                let original = try Self.requiredURL(Bundle.main.url(forResource: "WelcomeStory", withExtension: "txt"))
                try FileManager.default.copyItem(at: original, to: small)
            }
            // Original, isolated fixture only; never inspect the user's registered shelves.
            let largeFile = root.appendingPathComponent("large.txt")
            if (try? largeFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 24_000_000 {
                try await Task.detached(priority: .utility) {
                    try Self.largeFixtureText().write(to: largeFile, atomically: true, encoding: .utf8)
                }.value
            }
            let large = (root, largeFile)
            for (role, folder, file) in [("Small", root, small), ("Large", large.0, large.1)] {
                let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let bookmark = try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                let shelf = "benchmark" + role
                try core.saveLibraryShelf(id: shelf, name: role, bookmark: bookmark, location: "external", builtin: false)
                let path = String(file.path.dropFirst(folder.path.count + 1))
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                sizes[role] = size
                try core.scanLibraryShelf(shelfId: shelf, items: [.init(relativePath: path, directory: false, size: UInt64(size), modified: 0, needsDownload: false)])
                let location = try core.sourceFiles(shelfId: shelf)[0]
                if !(role == "Large" && ReaderOpenDiagnostics.argument("--reader-open-mode") == "import") {
                    let lease = try await service.aiPrepare(SourceFile(id: location.id, shelfID: shelf, relativePath: path))
                    leases.append(lease)
                    if ReaderOpenDiagnostics.argument("--reader-open-mode") != "first" && ReaderOpenDiagnostics.argument("--reader-open-mode") != "import" { try await service.savePosition(bookID: lease.id, offset: 9) }
                }
                entries.append(try await service.libraryEntry(location.id))
                try JSONSerialization.data(withJSONObject: sizes, options: .sortedKeys).write(to: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("reader-open-samples.json"), options: .atomic)
            }
        } catch { self.error = ReaderMessages.error(error) }
    }
    /// Approximately 24 MB (decimal), generated at runtime rather than checked in.
    nonisolated static func largeFixtureText() -> String {
        let paragraph = "第一章 合成\n月光下的书页用于开书显示回归，不是小说原文。\n"
        let targetBytes = 24_000_000
        return String(repeating: paragraph, count: (targetBytes + paragraph.utf8.count - 1) / paragraph.utf8.count)
    }
    nonisolated private static func requiredURL(_ value: URL?) throws -> URL {
        guard let value else { throw CocoaError(.fileNoSuchFile) }; return value
    }
}

struct ReaderOpenBenchmarkView: View {
    @State private var benchmark = ReaderOpenBenchmark()
    @State private var library = LibraryModel()
    @State private var variant = ReaderOpenDiagnostics.variant
    @State private var counts: [String: Int] = [:]
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduced
    private var theme: ThemeSurface {
        ThemeSurface(plan: try! resolveThemes(value: defaultThemeSnapshot(), system: scheme == .dark ? .dark : .light, highContrast: false).reader)
    }
    var body: some View {
        NativeThemeHost(theme: theme) {
            NavigationStack(path: $library.libraryPath) {
                VStack(spacing: 30) {
                    if let error = benchmark.error { Text(error).accessibilityIdentifier("benchmarkError") }
                    HStack {
                        ForEach(ReaderOpenDiagnostics.variants, id: \.self) { value in
                            Button(ReaderOpenDiagnostics.label(value)) { variant = value; ReaderOpenDiagnostics.selectVariant(value) }
                                .accessibilityIdentifier("variant-" + value)
                        }
                    }
                    Text(ReaderOpenDiagnostics.label(variant)).accessibilityIdentifier("benchmarkVariant")
                    Text(ReaderOpenDiagnostics.argument("--reader-open-mode") == "first" ? "首次阅读：停在正式封面后返回" : "续读")
                    VStack(alignment: .leading) {
                        ForEach(ReaderOpenDiagnostics.variants, id: \.self) { value in
                            Text("\(ReaderOpenDiagnostics.label(value))：小书 \(counts[value + "-Small", default: 0]) 次 · 长书 \(counts[value + "-Large", default: 0]) 次").font(.caption)
                        }
                    }
                    if benchmark.entries.count == 2 {
                        ForEach(Array(benchmark.entries.enumerated()), id: \.element.id) { index, entry in
                            Button(index == 0 ? "小书" : "长书") { library.open(entry) }
                                .accessibilityIdentifier(index == 0 ? "benchmarkSmall" : "benchmarkLarge")
                        }
                    } else { ProgressView("准备隔离快开缓存") }
                }
                .navigationTitle("开书测量")
                .navigationDestination(for: LibraryRoute.self) { LibraryDestination(route: $0) }
            }
            .environment(library).environment(\.readerTheme, theme).themeScope(theme)
            .environment(\.moonreadReduceMotion, systemReduced || ProcessInfo.processInfo.arguments.contains("--reader-open-reduce-motion"))
        }
        .onChange(of: library.libraryPath.isEmpty) { _, empty in if empty { counts = ReaderOpenDiagnostics.displayedCounts() } }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--reader-open-dark") ? .dark : .light)
        .task { UIApplication.shared.isIdleTimerDisabled = true; await benchmark.prepare() }
    }
}
#endif
