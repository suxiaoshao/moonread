import SwiftUI
import UniformTypeIdentifiers

extension LibraryModel {
    func acquire(_ kind: FileWork.Kind) -> FileWork? {
        guard canAcceptFileWork else { return nil }
        let work = FileWork(kind); fileWork = work
        return work
    }
    func rejectFileWork() -> Bool {
        error = ReaderMessages.error(LibraryFileError.fileWorkBusy); return false
    }
    func launch(_ work: FileWork, operation: @escaping @MainActor () async throws -> Void) {
        work.stage = .running
        work.task = Task {
            var outcome = FileWork.Outcome.completed
            defer {
                work.task = nil
                if self.fileWork === work {
                    if Task.isCancelled {
                        self.discardDecision(work)
                        work.stage = .finished(.cancelled)
                    } else if case .running = work.stage {
                        work.stage = .finished(outcome)
                    }
                    self.finish(work)
                }
            }
            do { try Task.checkCancellation(); try await operation() }
            catch is CancellationError { outcome = .cancelled }
            catch { outcome = .failed; self.error = ReaderMessages.error(error) }
        }
    }
    private func discardDecision(_ work: FileWork) {
        if case .awaitingDecision(.replacement(.receive(let file, _), _)) = work.stage { file.finish() }
    }
    func finish(_ work: FileWork) {
        guard fileWork === work, case .finished = work.stage else { return }
        for (file, _) in work.imports { file.finish() }; work.imports = []
        for command in work.commands { if case .receive(let file, _) = command { file.finish() } }
        work.commands = []; fileWork = nil
        if !systemImports.isEmpty {
            let next = systemImports.removeFirst()
            startImport(next.files, at: next.location, completion: next.files.count == 1 ? .openSingle : .showFolder)
        } else if Onboarding.shared.completed { Task { await receiveSharedInbox() } }
    }
    /// Observes the current runner; a paused decision keeps ownership but has no runner.
    func waitForFileWork() async {
        while let work = fileWork, let task = work.task {
            await task.value
            if fileWork === work, work.task == nil { return }
        }
    }
    func cancelFileWork() {
        guard let work = fileWork else { return }
        if let task = work.task { task.cancel() }
        else {
            discardDecision(work)
            work.stage = .finished(.cancelled)
            finish(work)
        }
    }
    func canAcceptDrop(at destination: LibraryLocation) -> Bool {
        canAcceptFileWork && destinationAvailable(destination)
    }
    private func destinationAvailable(_ destination: LibraryLocation) -> Bool {
        shelves.contains { $0.id == destination.shelfID && $0.error == nil }
    }
    /// Admission is synchronous; preparation and decisions retain this same owner.
    func acceptDrop(_ request: LibraryDropRequest, at destination: LibraryLocation) -> Bool {
        guard canAcceptDrop(at: destination) else { return false }
        switch request {
        case .moveIDs(let ids):
            guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count,
                  let work = acquire(.commands) else { return false }
            launch(work) { try await self.prepareMove(ids, to: destination, work: work) }
        case .moveProviders(let providers):
            guard !providers.isEmpty,
                  providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.moonreadLibraryItem.identifier) }),
                  let work = acquire(.commands) else { return false }
            launch(work) {
                var ids: [String] = []
                for provider in providers {
                    ids.append(try await LibraryDragPayload.load(provider).fileID)
                    try Task.checkCancellation()
                }
                guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw LibraryFileError.invalidDestination }
                try await self.prepareMove(ids, to: destination, work: work)
            }
        case .importProviders(let providers):
            let candidates = providers.compactMap { LibraryDropPolicy.candidate($0, at: destination) }
            guard !providers.isEmpty, candidates.count == providers.count,
                  let work = acquire(.imports) else { return false }
            launch(work) {
                var files: [LibraryDropFile] = []
                for candidate in candidates { files.append(try await LibraryDropFile.load(candidate)); try Task.checkCancellation() }
                guard self.destinationAvailable(destination) else { throw LibraryFileError.missingShelf }
                work.imports = files.map { (LibraryImportFile(url: $0.url, staged: $0), destination) }
                try await self.continueFileWork(work)
            }
        }
        return true
    }
    private func prepareMove(_ ids: [String], to destination: LibraryLocation, work: FileWork) async throws {
        var entries: [LibraryEntry] = []
        for id in ids {
            let entry = try await lookupDropEntry(id)
            try Task.checkCancellation()
            guard destinationAvailable(destination) else { throw LibraryFileError.missingShelf }
            guard LibraryDropPolicy.canMove(entry, to: destination, available: true) else { throw LibraryFileError.invalidDestination }
            entries.append(entry)
        }
        work.commands = entries.map { .move($0, destination) }
        try await continueFileWork(work)
    }
    func deleteEntries(_ entries: [LibraryEntry]) { runBatch(entries.map { .delete($0) }) }

    @discardableResult
    func runBatch(_ commands: [LibraryCommand], onSuccess: ((LibraryCommand) -> Void)? = nil) -> Bool {
        guard !commands.isEmpty else { return false }
        guard let work = acquire(.commands) else { return rejectFileWork() }
        work.commands = commands; work.onSuccess = onSuccess
        launch(work) { try await self.continueFileWork(work) }
        return true
    }
    func continueFileWork(_ work: FileWork) async throws {
        guard fileWork === work else { throw CancellationError() }
        while case .running = work.stage {
            try Task.checkCancellation()
            let command: LibraryCommand
            if work.kind == .imports {
                guard !work.imports.isEmpty else { break }
                let (file, location) = work.imports.removeFirst(); command = .receive(file, location)
            } else {
                guard !work.commands.isEmpty else { break }; command = work.commands.removeFirst()
            }
            _ = await perform(command, work: work)
        }
        if case .running = work.stage, work.kind == .imports {
            if let entry = work.imported.first {
                switch work.importCompletion {
                case .openSingle: work.stage = .awaitingOpen(entry)
                case .showFolder: path.append(.folder(entry.parent))
                case .stayInFolder: break
                }
            }
            if work.sharedInputCount > 1 || !work.skippedSharedNames.isEmpty {
                var result = String(localized: "已导入 \(work.imported.count) 本，取消 \(work.cancelledImports) 本", table: "ShareReceive")
                if !work.skippedSharedNames.isEmpty {
                    result += "\n" + String(localized: "跳过 \(work.skippedSharedNames.count) 个：\(work.skippedSharedNames.joined(separator: "、"))", table: "ShareReceive")
                }
                sharedImportResult = result
            }
            if !importFailures.isEmpty || sharedImportResult != nil { sheet = .importResults }
            for id in Set(work.imported.map(\.shelfId)) { await offerIndex(id) }
            // Both ordinary and shared imports finish here: import → index choice → open.
            finishImportOpening()
        }
    }
    /// A decision resumes the existing task, never re-enters admission.
    func resolveDecision(_ id: UUID, accepting: Bool) async {
        guard let decision = pendingDecision, decision.id == id, let work = fileWork, work.task == nil else { return }
        launch(work) {
            switch decision {
            case .replacement(let command, _):
                if accepting { _ = await self.perform(command, work: work, replace: true) }
                else if case .receive(let file, _) = command { file.finish(); work.cancelledImports += 1 }
            case .trashUnsupported(let entry, _):
                work.trashChoice = accepting ? .permanentlyDelete : .skip
                if accepting { _ = await self.perform(.delete(entry), work: work, permanently: true) }
            }
            try await self.continueFileWork(work)
        }
        await work.task?.value
    }
    func runAfterSheetDismiss(_ action: @escaping () -> Void) { afterSheetDismiss = action; sheet = nil }
    func sheetDidDismiss() {
        sharedImportResult = nil
        let action = afterSheetDismiss; afterSheetDismiss = nil; action?()
        if canAcceptFileWork, sheet == nil {
            releaseImportFailures()
            if Onboarding.shared.completed { Task { await receiveSharedInbox() } }
        }
        // A deferred index prompt is a new presentation, not the old import
        // result's owner. Clean up the dismissed result before presenting it.
        showDeferredIndexPrompt()
        finishImportOpening()
    }
    /// Only an admitted runner may execute filesystem work.
    private func perform(_ command: LibraryCommand, work: FileWork, replace: Bool = false, permanently: Bool = false) async -> Bool {
        do {
            switch command {
            case let .rename(entry, name): try await service.renameLibraryItem(entry, name: name, replace: replace)
            case let .move(entry, destination): try await service.moveLibraryItem(entry, to: destination, replace: replace)
            case let .copy(entry): _ = try await service.copyToBuiltin(entry, replace: replace)
            case let .create(location, name): try await service.createLibraryFolder(at: location, name: name)
            case let .delete(entry):
                cancelOpening(deleting: entry)
                let result: LibraryDeletionResult
                do { result = try await service.deleteLibraryItem(entry, permanently: permanently) }
                catch LibraryFileError.trashUnsupported where !permanently {
                    switch work.trashChoice {
                    case .permanentlyDelete: result = try await service.deleteLibraryItem(entry, permanently: true)
                    case .skip: return false
                    case nil: work.stage = .awaitingDecision(.trashUnsupported(entry)); return false
                    }
                }
                if let error = result.refreshError { self.error = ReaderMessages.error(error) }
            case let .receive(file, destination):
                let entry = try await service.receiveLibraryFile(file.url, at: destination, replace: replace)
                work.imported.append(entry); file.finish(); Onboarding.shared.didImport()
            }
            revision += 1
            work.onSuccess?(command)
            do {
                if let fileMutationReload { try await fileMutationReload() }
                else { try await reload() }
            } catch { self.error = ReaderMessages.error(error) }
            return true
        } catch is CancellationError {
            if case .receive(let file, _) = command { file.finish() }
        }
        catch LibraryFileError.conflict { work.stage = .awaitingDecision(.replacement(command)) }
        catch {
            if case let .receive(file, location) = command {
                importFailures.append(ImportFailure(file: file, location: location, message: ReaderMessages.error(error), completion: work.importCompletion == .stayInFolder ? .stayInFolder : .showFolder))
            } else { self.error = ReaderMessages.error(error) }
        }
        return false
    }
    @discardableResult
    func export(_ entries: [LibraryEntry], sharing: Bool) -> Bool {
        guard !entries.isEmpty else { return false }
        guard let work = acquire(.export) else { return rejectFileWork() }
        launch(work) {
            let urls = try await self.service.exportLibraryFiles(entries)
            try Task.checkCancellation()
            self.sheet = sharing ? .share(urls) : .export(urls)
        }
        return true
    }
}
