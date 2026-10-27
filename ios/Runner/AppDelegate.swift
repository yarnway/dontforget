import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Flutter forwards notification responses to registered plugins only when
    // the system notification center is connected to this application delegate.
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LocalSpeechPlugin") {
      LocalSpeechPlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LiveReminderPlugin") {
      LiveReminderPlugin.register(with: registrar)
    }
  }
}
