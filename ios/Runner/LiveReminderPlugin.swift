import ActivityKit
import Flutter
import UIKit

final class LiveReminderPlugin: NSObject, FlutterPlugin {
  private static weak var instance: LiveReminderPlugin?
  private static var pendingPayload: String?
  private let channel: FlutterMethodChannel
  private var ready = false
  private var generation = 0

  private init(channel: FlutterMethodChannel) { self.channel = channel }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "dontforget/live_reminder", binaryMessenger: registrar.messenger())
    let plugin = LiveReminderPlugin(channel: channel)
    instance = plugin
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  /// Deep links only navigate; authoritative occurrence/epoch validation runs
  /// in Dart after data and navigation finish loading, including cold starts.
  static func receive(_ url: URL) -> Bool {
    guard url.scheme == "dontforget-live", url.host == "reminder" else { return false }
    guard url.path.isEmpty, url.fragment == nil,
          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
          items.count == 1, items.first?.name == "payload",
          let payload = items.first?.value, payload.utf8.count <= 2048 else { return true }
    if let plugin = instance, plugin.ready {
      plugin.channel.invokeMethod("openReminder", arguments: payload)
    } else {
      pendingPayload = payload
    }
    return true
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "initialize" {
      ready = true
      let payload = Self.pendingPayload
      Self.pendingPayload = nil
      result(payload)
      return
    }
    guard #available(iOS 16.2, *) else {
      result(call.method == "status" ? ["availability": "unsupported"] : nil)
      return
    }
    if call.method == "end" || (call.method == "synchronize" && call.arguments == nil) {
      generation += 1
    }
    let ticket = generation
    Task { @MainActor in
      switch call.method {
      case "status":
        let active = Activity<ReminderActivityAttributes>.activities.first {
          $0.activityState == .active || $0.activityState == .stale
        }
        result([
          "availability": ActivityAuthorizationInfo().areActivitiesEnabled ? "available" : "disabled",
          "payload": active?.content.state.payload as Any? ?? NSNull()
        ])
      case "start":
        guard UIApplication.shared.applicationState == .active,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              let state = Self.content(call.arguments) else {
          result(FlutterError(code: "unavailable", message: "Live reminder unavailable", details: nil))
          return
        }
        for activity in Activity<ReminderActivityAttributes>.activities {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard ticket == self.generation else { result(nil); return }
        do {
          _ = try Activity.request(
            attributes: ReminderActivityAttributes(selectionID: UUID().uuidString),
            content: ActivityContent(state: state, staleDate: state.endTime), pushType: nil)
          result(nil)
        } catch {
          result(FlutterError(code: "request_failed", message: "System declined the Live Activity", details: nil))
        }
      case "synchronize":
        let state = Self.content(call.arguments)
        for activity in Activity<ReminderActivityAttributes>.activities {
          if let state, ticket == self.generation {
            await activity.update(ActivityContent(state: state, staleDate: state.endTime))
          } else {
            await activity.end(nil, dismissalPolicy: .immediate)
          }
        }
        result(nil)
      case "end":
        for activity in Activity<ReminderActivityAttributes>.activities {
          await activity.end(nil, dismissalPolicy: .immediate)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  @available(iOS 16.2, *)
  private static func content(_ value: Any?) -> ReminderActivityAttributes.ContentState? {
    guard let data = value as? [String: Any],
          let title = data["title"] as? String, title.count <= 120,
          let payload = data["payload"] as? String, payload.utf8.count <= 2048,
          let time = data["endTime"] as? Double, time.isFinite,
          let language = data["language"] as? String,
          ["en", "zh", "ja"].contains(language) else { return nil }
    let date = Date(timeIntervalSince1970: time)
    guard date > .now, date.timeIntervalSinceNow <= 8 * 60 * 60 else { return nil }
    return .init(title: title, endTime: date, payload: payload, language: language)
  }
}
