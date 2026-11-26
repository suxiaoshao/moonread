import Foundation
import MoonreadCoreBindings
import Observation

@MainActor @Observable
public final class BookMetadataDraft: Identifiable {
    public let id = UUID()
    public let base: BookMetadata
    public var value: BookMetadata
    public var error: String?
    public var saving = false
    public private(set) var choosingImage = false
    public var presentsPhotoPicker = false
    public var presentsFilePicker = false
    private let makeCover: @MainActor (Data) async throws -> BookCoverAsset
    private let discardCover: @MainActor (BookCoverAsset) async -> Void
    private let describeError: @MainActor (Error) -> String
    private var imageRequest = UUID()
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    private var closed = false
    public init(
        base: BookMetadata,
        makeCover: @escaping @MainActor (Data) async throws -> BookCoverAsset,
        discardCover: @escaping @MainActor (BookCoverAsset) async -> Void,
        describeError: @escaping @MainActor (Error) -> String
    ) {
        self.base = base; value = base
        self.makeCover = makeCover
        self.discardCover = discardCover
        self.describeError = describeError
    }
    var changed: Bool { value != base }
    public var blocksInteractiveDismissal: Bool {
        !closed && (changed || saving || choosingImage || presentsPhotoPicker || presentsFilePicker)
    }
    public enum LeaveAction { case close, confirmDiscard }
    public func requestLeave() -> LeaveAction { changed ? .confirmDiscard : .close }

    @discardableResult
    public func chooseImage(_ read: @escaping @Sendable () async throws -> Data?) -> Task<Void, Never>? {
        guard !closed, !saving else { return nil }
        imageTask?.cancel()
        let request = UUID(); imageRequest = request; choosingImage = true
        let task = Task {
            defer { if imageRequest == request { choosingImage = false; imageTask = nil } }
            do {
                guard let data = try await read(), !closed, imageRequest == request, !Task.isCancelled else { return }
                let cover = try await makeCover(data)
                guard !closed, imageRequest == request, !Task.isCancelled else { await discardCover(cover); return }
                discardNewCover(); value.cover = cover
            } catch is CancellationError { }
            catch { if imageRequest == request { self.error = describeError(error) } }
        }
        imageTask = task
        return task
    }
    @discardableResult private func discardNewCover() -> Task<Void, Never>? {
        guard let cover = value.cover, cover != base.cover else { return nil }
        return Task { [discardCover] in await discardCover(cover) }
    }
    private func stopChoosingImage() {
        imageRequest = UUID(); imageTask?.cancel(); imageTask = nil; choosingImage = false
    }
    public func removeCover() { stopChoosingImage(); discardNewCover(); value.cover = nil }
    @discardableResult public func cancel() -> Task<Void, Never>? {
        guard !closed else { return nil }
        closed = true; stopChoosingImage()
        return discardNewCover()
    }
}
