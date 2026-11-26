import Combine
import MoonreadData
import MoonreadLibrary
import SwiftUI

extension BookTagPicker {
    init(service: AppDataService, purpose: Purpose, showsChoices: Bool = true, match: BookSearchMatch? = nil,
         selection: Binding<[String]>, @ViewBuilder controls: @escaping () -> Controls, @ViewBuilder status: @escaping () -> Status) {
        self.init(
            purpose: purpose, showsChoices: showsChoices, match: match, selection: selection,
            updates: { try await service.metadataOptionsUpdates(shelfID: nil) },
            accountChanges: NotificationCenter.default.publisher(for: .readingContinuationInvalidated, object: service)
                .receive(on: DispatchQueue.main).eraseToAnyPublisher(),
            describeError: { ReaderMessages.error($0) },
            controls: controls, status: status
        )
    }
}
