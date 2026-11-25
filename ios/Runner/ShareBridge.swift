import Flutter
import Foundation
import QuickLook
import UIKit

final class ShareBridge: NSObject, FlutterPlugin {
  private let worker = DispatchQueue(label: "com.yarnway.dontforget.share")
  private var epoch: String?
  private var previewSource: SharePDFPreviewSource?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "com.yarnway.dontforget/share", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(ShareBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "previewPDF" {
      DispatchQueue.main.async { result(self.previewPDF(call.arguments)) }
      return
    }
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

  @MainActor private func previewPDF(_ arguments: Any?) -> Bool {
    guard let arguments = arguments as? [String: String],
          let id = arguments["id"], ShareHandoff.validID(id),
          let name = arguments["name"], ShareHandoff.validName(name),
          (name as NSString).pathExtension.lowercased() == "pdf",
          let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: false),
          let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow),
          let presenter = window.rootViewController, presenter.presentedViewController == nil else {
      return false
    }
    let file = support.resolvingSymlinksInPath().appendingPathComponent("shared_handoff", isDirectory: true)
      .appendingPathComponent(id, isDirectory: true).appendingPathComponent(name)
    guard file.resolvingSymlinksInPath().path == file.path,
          (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return false }
    let item = file as NSURL
    guard QLPreviewController.canPreview(item) else { return false }
    let source = SharePDFPreviewSource(item)
    previewSource = source
    let controller = QLPreviewController()
    controller.dataSource = source
    presenter.present(controller, animated: true)
    return true
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

@MainActor private final class SharePDFPreviewSource: NSObject, QLPreviewControllerDataSource {
  private let item: NSURL

  init(_ item: NSURL) {
    self.item = item
  }

  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    item
  }
}
