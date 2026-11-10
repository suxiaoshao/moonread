import Foundation

#if DEBUG
enum ReaderSmokeFixture {
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing"), args.contains("--ui-test-smoke"),
              let index = args.firstIndex(of: "--ui-test-session"), args.indices.contains(index + 1) else { return false }
        return UUID(uuidString: args[index + 1]) != nil
    }
    static let paragraph = "星灯照着归途，月光落在书页上。这是用于应用测试的合成文字。\n"
    static var text: String {
        "第一章 星灯\n" + String(repeating: paragraph, count: 14)
        + "第二話 归途\n" + String(repeating: paragraph, count: 14)
        + "終章\n" + paragraph
    }
}
#endif

#if DEBUG
extension AppDataService {
    /// The cloud scenarios exercise publication timing only, without a real account.
    func prepareOnboardingCloudFixture() async throws {
        guard testSession != nil else { throw LibraryFileError.invalidDestination }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-onboarding-existing") {
            let url = try builtinLibraryURL().appendingPathComponent("云端合成小说.txt")
            try "第一章 合成\n这份文字仅用于发现状态测试。".write(to: url, atomically: true, encoding: .utf8)
        }
        try await scanLibraryShelf("builtin")
    }

    /// Original text and a delivered-position stand-in in the isolated UI session.
    /// No real cloud account, external files, or prior local books are used.
    func createRecentRestorationFixture() async throws {
        guard testSession != nil else { return }
        let root = try builtinLibraryURL(), file = root.appendingPathComponent("原创最近阅读恢复.txt")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let heading = "第一章 回到书页\n"
        let paragraph = "这是一段原创合成文字，用来验证恢复最近阅读后可以回到原来的位置，不需要先逐本打开文件。\n"
        let text = heading + String(repeating: paragraph, count: 80)
        try Data(text.utf8).write(to: file)
        let identity = try SourceIdentityProbe().identify(filePath: file.path, decoding: "auto")
        let hint = PositionSourceHint(source_kind: .managedLocal, relative_path: file.lastPathComponent,
            file_name: file.lastPathComponent, byte_size: UInt64(text.utf8.count), decoding: "auto")
        let position = PositionValue(content_key: identity.contentSha256,
            offset: UInt64(heading.utf8.count + paragraph.utf8.count * 12), source_hint: hint)
        try await userStore().put("position/" + identity.contentSha256, value: UserSyncJSON.encode(position), device: "ui-fixture")
        try refreshLibraryShelf("builtin")
    }

    func createAITaskLibraryFixture() throws {
        guard testSession != nil else { return }
        let root = try builtinLibraryURL()
        for (name, text) in [("AI 待整理甲.txt", "第一章\n离线整理示例甲"), ("AI 待整理乙.txt", "第一章\n离线整理示例乙"), ("AI 已有名称.txt", "第一章\n同名冲突示例")] {
            let url = root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { try text.write(to: url, atomically: true, encoding: .utf8) }
        }
        try refreshLibraryShelf("builtin")
    }

    func createShelfRecoveryFixture() async throws {
        guard let testSession, ProcessInfo.processInfo.arguments.contains("--ui-test-shelf-recovery") else { return }
        let marker = "Moonread.shelfRecovery.fixture." + testSession
        guard !sourceDefaults.bool(forKey: marker) else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Recovery-" + testSession).appendingPathComponent("复原书架")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("复原样本.txt")
        try ("第一話 星光来信\n" + String(repeating: "窗前的灯照着回家的路，这是原创的恢复验证正文。\n", count: 60)).write(to: file, atomically: true, encoding: .utf8)
        let identity = try SourceIdentityProbe().identify(filePath: file.path, decoding: "auto")
        let store = try await userStore()
        try await store.put("shelf-reference/" + testSession, value: UserSyncJSON.encode(ShelfReferenceValue(name: "复原书架", locationDescription: "file-provider")), device: "recovery-fixture")
        let position = PositionValue(content_key: identity.contentSha256, offset: identity.utf8Bytes / 2, source_hint: nil)
        try await store.put("position/" + identity.contentSha256, value: UserSyncJSON.encode(position), device: "recovery-fixture")
        try await store.put("metadata/" + identity.contentSha256 + "/tag-restored", value: UserSyncJSON.encode("复原标签"), device: "recovery-fixture")
        sourceDefaults.set(true, forKey: marker)
    }
    func shelfRecoveryFixtureURL(_ reference: String) -> URL? {
        guard let testSession, testSession == reference, ProcessInfo.processInfo.arguments.contains("--ui-test-shelf-recovery") else { return nil }
        return FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Recovery-" + testSession).appendingPathComponent("复原书架")
    }

    func createSmokeFixture() async throws {
        guard let testSession else { return }
        let marker = "Moonread.smoke.seed.v1." + testSession
        guard !sourceDefaults.bool(forKey: marker) else { return }
        let root = try builtinLibraryURL(), core = try textCore()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("目标"), withIntermediateDirectories: true)
        try ReaderSmokeFixture.text.write(to: root.appendingPathComponent("月读 · 排版示例.txt"), atomically: true, encoding: .utf8)
        try ("第一章 同名\n" + String(repeating: "保留原来的目标内容。\n", count: 80)).write(to: root.appendingPathComponent("同名.txt"), atomically: true, encoding: .utf8)
        if ProcessInfo.processInfo.arguments.contains("--ui-test-encoding") {
            let text = "Chapter 1\n" + String(repeating: "An original encoding fixture.\n", count: 8)
            let bytes = text.utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }
            try Data(bytes).write(to: root.appendingPathComponent("编码恢复样本.txt"))
        }
        try refreshLibraryShelf("builtin")
        let file = try core.sourceFileSnapshots(fileId: nil).first { $0.relativePath == "月读 · 排版示例.txt" && $0.shelfId == "builtin" }
        if let file {
            let identity = try SourceIdentityProbe().identify(filePath: root.appendingPathComponent(file.relativePath).path, decoding: file.decoding)
            _ = try core.publishSourceIdentity(file: file, identity: identity)
            let base = try await details(sha: identity.contentSha256).metadata
            var edited = base; edited.tags = ["星灯"]
            try await saveMetadata(base: base, edited: edited)
            if ProcessInfo.processInfo.arguments.contains("--ui-test-data-management") {
                let chapter = ChapterValue(content_key: identity.contentSha256, offset: 0, title: "备份目录", level: 1, excluded: false)
                try await userStore().put("chapter/" + identity.contentSha256 + "/0", value: UserSyncJSON.encode(chapter), device: "data-management-fixture")
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-smoke-restored") || ProcessInfo.processInfo.arguments.contains("--ui-test-data-management") {
                let position = PositionValue(content_key: identity.contentSha256, offset: ProcessInfo.processInfo.arguments.contains("--ui-test-data-management") ? identity.utf8Bytes / 2 : 120, source_hint: nil)
                try await userStore().put("position/" + identity.contentSha256, value: UserSyncJSON.encode(position), device: "smoke-fixture")
            }
        }
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Smoke-External-" + testSession)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try "第一章 复制\n保留来源文件。".write(to: external.appendingPathComponent("复制.txt"), atomically: true, encoding: .utf8)
        try ("第一章 冲突\n" + String(repeating: "不要替换已有目标。\n", count: 80)).write(to: external.appendingPathComponent("同名.txt"), atomically: true, encoding: .utf8)
        let shelf = try registerLibraryShelf(external)
        try refreshLibraryShelf(shelf)
        sourceDefaults.set(true, forKey: marker)
    }

    func createReaderFixture() async throws {
        guard testSession != nil else { return }
        let core = try textCore(), root = try builtinLibraryURL()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-encoding") {
            let text = "Chapter 1\n" + String(repeating: "An original sample for manual encoding recovery.\n", count: 80)
            let bigEndian = arguments.contains("--ui-test-encoding-be")
            let bytes = text.utf16.flatMap { unit in
                bigEndian ? [UInt8(unit >> 8), UInt8(unit & 255)] : [UInt8(unit & 255), UInt8(unit >> 8)]
            }
            try Data(bytes).write(to: root.appendingPathComponent("编码恢复样本.txt"))
            try refreshLibraryShelf("builtin")
            return
        }
        if arguments.contains("--ui-test-blank-line-projection") {
            let gap = String(repeating:" \t　\n",count:15000)
            let prose = "用于验证真正翻阅的合成正文，正文前后的长空白不应形成空屏或空页。\n"
            let text = gap+"前段标记。\n"+String(repeating:prose,count:9)+gap+"后段标记。\n"+String(repeating:prose,count:32)+gap
            let file = root.appendingPathComponent("空行投影合成.txt")
            try Data(text.utf8).write(to:file)
            var settings = defaultReaderSettings()
            if arguments.contains("--ui-test-blank-line-pages") { settings.mode = .pages }
            try await saveSettings(settings)
            try refreshLibraryShelf("builtin")
            guard let entry = try await libraryEntries(LibraryLocation(shelfID:"builtin")).first(where:{$0.name==file.lastPathComponent}) else { throw ReaderError.NotFound }
            // Prepare through the real source pipeline, including the raw-SHA
            // reuse cache, before seeding a genuinely resumable position.
            let prepared = try await aiPrepare(entry.source)
            if arguments.contains("--ui-test-blank-line-no-cover") {
                try await savePosition(bookID:prepared.id,offset:UInt64(gap.utf8.count))
                let saved = try await snapshot(prepared.id)
                print("BLANK_FIXTURE_PREPARED", saved.preparation, "hasStarted", saved.hasStarted, "position", saved.book.positionUtf8)
            }
            withExtendedLifetime(prepared) {}
            return
        }
        let book = try core.createSampleBook()
        let file = root.appendingPathComponent("月读 · 排版示例.txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            var text = ""
            for index in 0..<book.chunkCount { text += try core.readChunk(bookId: book.id, index: index).text }
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try refreshLibraryShelf("builtin")
        guard let entry = try await libraryEntries(LibraryLocation(shelfID: "builtin")).first(where: { $0.name == file.lastPathComponent }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try core.linkLibraryFile(fileId: entry.id, bookId: book.id)
        let conflictFixture = "Moonread.conflictFixture." + (testSession ?? "")
        if ProcessInfo.processInfo.arguments.contains("--ui-test-annotation-conflict"), !sourceDefaults.bool(forKey: conflictFixture) {
            let range = try core.paragraphRange(bookId: book.id, offsetUtf8: 0)
            let original = try await prepareAnnotation(book.id, start: range.startUtf8, end: range.endUtf8)
            _ = try await saveNote(original, text: "原批注")
            let baseline = try await prepareAnnotation(book.id, start: range.startUtf8, end: range.endUtf8)
            _ = try await saveNote(baseline, text: "设备甲的评论")
            if ProcessInfo.processInfo.arguments.contains("--ui-test-annotation-delete-conflict") {
                let key = try userKey(book.id).storageKey
                try await userStore(for: key).changeDeletion(baseline.id, baseline: baseline.baselines[baseline.id] ?? [], deleted: true, restoring: nil)
            } else {
                _ = try await saveNote(baseline, text: "设备乙的评论")
            }
            sourceDefaults.set(true, forKey: conflictFixture)
        }
    }

    func createContinuationFixture() async throws {
        guard let testSession else { return }
        let marker = "Moonread.syncContinuationFixture." + testSession
        guard !sourceDefaults.bool(forKey: marker),
              let entry = try await libraryEntries(LibraryLocation(shelfID: "builtin")).first(where: { $0.name == "月读 · 排版示例.txt" }) else { return }
        // Seed the actual synthetic file's identity, never an unrelated sample.
        let prepared = try await aiPrepare(entry.source)
        let actual = try await snapshot(prepared.id).book
        let query = try textCore().querySnapshot(json: "{}")
        let local = try query.readingLocation(bookId: prepared.id, percentage: 10)
        try await savePosition(bookID: prepared.id, offset: local.offsetUtf8)
        let target = try query.readingLocation(bookId: prepared.id, percentage: 75)
        let value = PositionValue(content_key: actual.contentSha256, offset: target.offsetUtf8)
        try await userStore().put("position/" + actual.contentSha256, value: UserSyncJSON.encode(value), device: "synthetic-remote")
        sourceDefaults.set(true, forKey: marker)
        withExtendedLifetime(prepared) {}
    }

    /// A synthetic catalogue of about 10,000-character chapters with short generic titles and
    /// one long title. Coverage comes from actually reading it in the UI test.
    func createChapterCatalogueFixture() async throws {
        guard testSession != nil else { return }
        let file = try builtinLibraryURL().appendingPathComponent("目录样例.txt")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        var text = ""
        let line = "月光落在书页上，风轻轻吹过窗边，远处传来一声犬吠。"
        for index in 1...40 {
            text += (index == 6 ? "第\(index)章 一个很长的通用测试章节标题，用来检查较窄屏幕上换行显示的效果" : "第\(index)章 通用标题\(index)") + "\n"
            for _ in 0..<(400 + index % 5 * 20) { text += line + "\n" }
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
        try refreshLibraryShelf("builtin")
    }

    func createLibraryFixture() async throws {
        guard let testSession else { return }
        let root = try builtinLibraryURL()
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-External-\(testSession)/本地小说")
        for directory in [root.appendingPathComponent("奇幻/东方"), external] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let names = ["夜航", "山海之间", "长街来信"]
        for (index, name) in names.enumerated() {
            let parent = index == 1 ? root.appendingPathComponent("奇幻/东方") : root
            let file = parent.appendingPathComponent(name + ".txt")
            if !FileManager.default.fileExists(atPath: file.path) {
                try "第一章 \(name)\n\n\(String(repeating: "这是用于书架验证的原创示例文字。窗外的月光洒在书页上，风轻轻吹过窗边。\n\n", count: 100))".write(to: file, atomically: true, encoding: .utf8)
            }
        }
        let outside = external.appendingPathComponent("山中来信.txt")
        if !FileManager.default.fileExists(atPath: outside.path) { try "第一章 来信\n\n这是一段原创测试正文。".write(to: outside, atomically: true, encoding: .utf8) }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-bookshelf-batch") {
            let folder = external.appendingPathComponent("待整理")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, parent) in [("春风", external), ("夜航", external), ("长街来信", external), ("不应递归复制", folder)] {
                try "第一章\n批量复制验证：\(name)".write(to: parent.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
            }
        }
        let externalID = try registerLibraryShelf(external)
        try refreshLibraryShelf(externalID)
        try refreshLibraryShelf("builtin")
        for entry in try await libraryEntries(LibraryLocation(shelfID: "builtin"), recursive: true) where !entry.directory {
            let file = root.appendingPathComponent(entry.relativePath)
            let book = try textCore().importBook(filePath: file.path, title: entry.title)
            try textCore().linkLibraryFile(fileId: entry.id, bookId: book.id)
            try await writePosition(book.id, offset: min(160, book.byteCount))
        }
    }
}
#endif
