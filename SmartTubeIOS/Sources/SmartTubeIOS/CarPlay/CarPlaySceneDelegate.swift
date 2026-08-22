#if os(iOS) && canImport(CarPlay)
import CarPlay
import UIKit

// MARK: - CarPlaySceneDelegate

/// Scene delegate for the CPTemplateApplicationSceneSessionRoleApplication role.
///
/// Referenced by class name from Info.plist (UISceneDelegateClassName); the
/// @objc name keeps the plist entry stable regardless of the Swift module the
/// class lives in.
@objc(CarPlaySceneDelegate)
public final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var menu: CarPlayMenuController?

    public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // Scene delegate callbacks are delivered on the main thread; assumeIsolated
        // lets us touch the @MainActor CarPlayBridge without an async hop so the
        // flag is set before any head-unit pick can start playback.
        MainActor.assumeIsolated {
            CarPlayBridge.shared.carPlaySceneDidConnect()
        }
        let menu = CarPlayMenuController(interfaceController: interfaceController)
        self.menu = menu
        menu.installRootTemplate()
    }

    public func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        MainActor.assumeIsolated {
            CarPlayBridge.shared.carPlaySceneDidDisconnect()
        }
        menu?.disconnect()
        menu = nil
    }
}
#endif
