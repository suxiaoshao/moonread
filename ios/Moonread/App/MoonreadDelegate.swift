import UIKit

@MainActor
final class MoonreadDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if CloudConfiguration.availableInBuild { application.registerForRemoteNotifications() }
        return true
    }
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderDeviceControls.orientationMask(for: window?.windowScene)
    }
}
