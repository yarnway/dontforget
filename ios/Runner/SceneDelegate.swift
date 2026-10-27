import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                      options connectionOptions: UIScene.ConnectionOptions) {
    for context in connectionOptions.urlContexts { _ = LiveReminderPlugin.receive(context.url) }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let unhandled = URLContexts.filter { !LiveReminderPlugin.receive($0.url) }
    if !unhandled.isEmpty { super.scene(scene, openURLContexts: Set(unhandled)) }
  }
}
