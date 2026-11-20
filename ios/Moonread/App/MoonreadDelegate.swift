import UIKit

@MainActor
final class MoonreadDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderDeviceControls.orientationMask(for: window?.windowScene)
    }
}
