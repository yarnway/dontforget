import Flutter
import Foundation

final class ShareBridge: NSObject, FlutterPlugin {
  private let worker = DispatchQueue(label: "com.yarnway.dontforget.share")
  private var epoch: String?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.yarnway.dontforget/share", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ShareBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    worker.async {
      let response: Any?
      do {
        response = try self.perform(call)
      } catch {
        response = FlutterError(code: "share_handoff_unavailable", message: nil, details: nil)
      }
      DispatchQueue.main.async { result(response) }
    }
  }

  private func perform(_ call: FlutterMethodCall) throws -> Any? {
    switch call.method {
    case "initialize":
      guard let epoch = call.arguments as? String else { throw ShareHandoffError.invalid }
      try ShareHandoff.open().initialize(epoch: epoch)
      self.epoch = epoch
      return nil
    case "pending":
      guard let epoch else { return [[String: Any]]() }
      let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true)
      return try ShareHandoff.open().pending(epoch: epoch, attachments: support.appendingPathComponent("shared_handoff"))
    case "acknowledge":
      guard let epoch, let id = call.arguments as? String else { throw ShareHandoffError.invalid }
      try ShareHandoff.open().acknowledge(id, epoch: epoch)
      return nil
    case "reset":
      // Keep the queue until initialization confirms a different dataset epoch.
      epoch = nil
      return nil
    default:
      return FlutterMethodNotImplemented
    }
  }
}
