import MoonreadDataTypes
import MoonreadSettings
import SwiftUI

struct CloudSettingsView: View {
    @Environment(CloudStore.self) private var cloud

    var body: some View {
        @Bindable var cloud = cloud
        CloudSettingsPage(
            enabled: Binding(get: { cloud.status.requested }, set: cloud.setEnabled),
            confirmationAccount: $cloud.confirmationAccount, error: $cloud.error,
            busy: cloud.busy, card: cloud.syncCard, canRetry: cloud.status.canRetry,
            conflictPath: cloud.conflictPath, libraryStatus: cloud.libraryStatus,
            libraryRoute: LibraryRoute.folder(LibraryLocation(shelfID: "builtin")),
            actions: .init(updateStatus: cloud.updateStatus, retry: cloud.retry,
                           requestConfirmation: cloud.requestConfirmation, confirmAccount: cloud.confirmAccount,
                           replaceCloudFile: cloud.replaceCloudFile)
        )
    }
}
