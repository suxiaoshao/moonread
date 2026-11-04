import SwiftUI
import UniformTypeIdentifiers

extension LibraryModel {
    @discardableResult
    func receive(_ urls: [URL], at location: LibraryLocation = LibraryLocation(shelfID: "builtin")) -> Bool {
        guard !urls.isEmpty else { return false }
        guard canAcceptFileWork else { return rejectFileWork() }
        startImport(urls.map { LibraryImportFile(url: $0) }, at: location, completion: urls.count == 1 ? .openSingle : .showFolder)
        return true
    }
    /// URLs already delivered by the system must retain access while waiting behind work.
    func receiveSystemURLs(_ urls: [URL], at location: LibraryLocation = LibraryLocation(shelfID: "builtin")) {
        guard !urls.isEmpty else { return }
        let files = urls.map { LibraryImportFile(url: $0) }
        if canAcceptFileWork { startImport(files, at: location, completion: files.count == 1 ? .openSingle : .showFolder) }
        else { systemImports.append(SystemImport(files: files, location: location)) }
    }
    /// Foreground delivery shares the existing runner. The set only deduplicates
    /// this process's retained files; there are no persistent claims or receipts.
    #if DEBUG
    func receiveSmokeTXT(shared: Bool) async {
        guard ReaderSmokeFixture.enabled else { return }
        do {
            let bytes = Data(ReaderSmokeFixture.text.utf8)
            if shared {
                let inbox = ShareInbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Smoke-Inbox-" + UUID().uuidString))
                let draft = try ShareInbox.Draft(in: inbox)
                let provider = NSItemProvider(); provider.suggestedName = "分享样本.txt"
                provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in completion(bytes, nil); return nil }
                let item = try await draft.load(provider)
                try draft.publish(items: [item], skippedNames: [])
                await receiveSharedInbox(inbox)
            } else {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Moonread-Smoke-Incoming-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let source = root.appendingPathComponent("导入样本.txt"); try bytes.write(to: source)
                receive([source])
            }
        } catch { self.error = ReaderMessages.error(error) }
    }
    #endif

    func receiveSharedInbox(_ source: ShareInbox? = nil) async {
        #if DEBUG
        // Isolated UI-test libraries must never consume the real shared inbox.
        if source == nil, await service.testSession != nil { return }
        #endif
        guard initialized, !scanningSharedInbox, canAcceptFileWork, sheet == nil, !filePickerPresented else { return }
        scanningSharedInbox = true
        defer { scanningSharedInbox = false }
        do {
            let inbox = try source ?? ShareInbox.shared()
            let scan = try await Task.detached { try inbox.scan() }.value
            guard canAcceptFileWork, sheet == nil, !filePickerPresented else { return }
            let batches = scan.batches.filter { !enqueuedSharedBatches.contains($0.directory) }
            let files = batches.flatMap { batch in batch.files.map { item in
                LibraryImportFile(url: item.url(in: batch.directory), inbox: (batch, item))
            } }
            if !scan.errors.isEmpty { error = scan.errors.joined(separator: "\n") }
            guard !files.isEmpty else { return }
            enqueuedSharedBatches.formUnion(batches.map(\.directory))
            selectedTab = .library
            let skipped = batches.flatMap { $0.manifest.skippedNames }
            startImport(files, at: .init(shelfID: "builtin"), completion: files.count + skipped.count == 1 ? .openSingle : .showFolder,
                        shared: true, skippedNames: skipped)
        } catch { self.error = ReaderMessages.error(error) }
    }
    func startImport(_ files: [LibraryImportFile], at location: LibraryLocation, completion: LibraryImportCompletion,
                             shared: Bool = false, skippedNames: [String] = []) {
        guard let work = acquire(.imports) else { preconditionFailure("Import continuation lost ownership") }
        work.imports = files.map { ($0, location) }; work.importCompletion = completion
        work.sharedInputCount = shared ? files.count + skippedNames.count : 0; work.skippedSharedNames = skippedNames
        launch(work) { try await self.continueFileWork(work) }
    }
    func releaseImportFailures() {
        for failure in importFailures { failure.file.finish() }; importFailures = []
    }
    @discardableResult
    func retryImport(_ failure: ImportFailure) -> Bool {
        guard canAcceptFileWork else { return rejectFileWork() }
        guard importFailures.contains(where: { $0.id == failure.id }) else { return false }
        importFailures.removeAll { $0.id == failure.id }
        startImport([failure.file], at: failure.location, completion: failure.completion)
        return true
    }
}
