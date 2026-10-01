import UIKit

/// A separate, credential-free UIKit lifecycle for native component tests.
/// It never initializes the reader, its persisted owners or cloud services.
@main
final class ComponentTestHost: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let controller = UIViewController()
        controller.view.backgroundColor = .systemBackground
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
