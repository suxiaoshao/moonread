import MoonreadReader
import UIKit

@MainActor
final class MoonreadDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        readerOrientationMask(for: window?.windowScene)
    }
}
