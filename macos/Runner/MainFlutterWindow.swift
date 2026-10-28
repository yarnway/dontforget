import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var menuCommands: MacMenuCommands?
  // UNUserNotificationCenter holds its delegate weakly. Retain the proxy and
  // keep the plugin delegate behind it rather than replacing plugin routing.
  private var notificationResponses: NotificationResponseDelegateProxy?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let notificationCenter = UNUserNotificationCenter.current()
    let responseTimes = NativeNotificationResponseTimes()
    let responseProxy = NotificationResponseDelegateProxy(
      downstream: notificationCenter.delegate, responseTimes: responseTimes)
    notificationResponses = responseProxy
    notificationCenter.delegate = responseProxy

    menuCommands = MacMenuCommands(
      window: self, messenger: flutterViewController.engine.binaryMessenger)

    let scheduling = FlutterMethodChannel(
      name: "dontforget/notification_schedule",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    scheduling.setMethodCallHandler { call, result in
      if call.method == "takeResponseOccurredAt" {
        guard let args = call.arguments as? [String: Any],
              let payload = args["payload"] as? String,
              let actionId = args["actionId"] as? String else {
          result(FlutterError(code: "invalid_response", message: "Invalid notification response", details: nil))
          return
        }
        result(responseTimes.firstObserved(payload: payload, actionId: actionId))
        return
      }
      guard call.method == "schedule" else {
        result(FlutterMethodNotImplemented)
        return
      }
      Self.scheduleNotification(call.arguments, result: result)
    }

    let systemTime = FlutterMethodChannel(
      name: "dontforget/system_time",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    systemTime.setMethodCallHandler { call, result in
      guard call.method == "timeZoneIdentifier" else {
        result(FlutterMethodNotImplemented)
        return
      }
      NSTimeZone.resetSystemTimeZone()
      result(TimeZone.current.identifier)
    }

    super.awakeFromNib()
  }

  // Preserve the pinned plugin's payload/presentation contract so its existing
  // foreground and cold-start delegate handles these notifications unchanged.
  private static func scheduleNotification(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let id = args["id"] as? Int, id >= 0, id <= 0x7fffffff,
          let title = args["title"] as? String,
          let body = args["body"] as? String,
          let milliseconds = args["triggerMilliseconds"] as? Int64,
          let sound = args["playSound"] as? Bool,
          let payload = args["payload"] as? String, !payload.isEmpty else {
      result(FlutterError(code: "invalid_schedule", message: "Invalid notification request", details: nil))
      return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let category = args["categoryIdentifier"] as? String {
      content.categoryIdentifier = category
    }
    content.sound = sound ? .default : nil
    content.userInfo = [
      "payload": payload, "presentAlert": true, "presentBadge": true,
      "presentSound": sound, "presentBanner": true, "presentList": true
    ]
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    let components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second, .timeZone], from: date)
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    let request = UNNotificationRequest(identifier: String(id), content: content, trigger: trigger)
    UNUserNotificationCenter.current().add(request) { error in
      // Flutter result callbacks belong on the platform thread. Never report
      // submitted before the OS has either accepted or rejected this request.
      DispatchQueue.main.async {
        if let error = error as NSError? {
          result(FlutterError(code: "native_schedule_failed",
            message: "The system rejected notification scheduling",
            details: ["domain": error.domain, "code": error.code]))
        } else {
          result(nil)
        }
      }
    }
  }
}

/// Bounded native context, not a second pending-action queue. Keeping the first
/// value after readback makes repeated plugin cold-launch responses retain the
/// original observation time. The next process starts with an empty cache.
final class NativeNotificationResponseTimes {
  private struct Key: Hashable {
    let payload: String
    let actionId: String
  }
  private let lock = NSLock()
  private var order: [Key] = []
  private var values: [Key: Int64] = [:]
  private static let actions: Set<String> = [
    "complete", "snooze_15", "snooze_60", "skip_occurrence"
  ]

  func record(payload: String, actionId: String, occurredAt: Int64) {
    guard !payload.isEmpty, payload.utf16.count <= 2048,
          Self.actions.contains(actionId) else { return }
    let key = Key(payload: payload, actionId: actionId)
    lock.lock()
    defer { lock.unlock() }
    guard values[key] == nil else { return }
    order.append(key)
    values[key] = occurredAt
    while order.count > 32 {
      values.removeValue(forKey: order.removeFirst())
    }
  }

  func firstObserved(payload: String, actionId: String) -> Int64? {
    lock.lock()
    defer { lock.unlock() }
    return values[Key(payload: payload, actionId: actionId)]
  }
}

/// Completion forwarding is guarded because the center must receive exactly
/// one completion even if a downstream delegate accidentally invokes it twice.
final class NotificationResponseCompletion<Value> {
  private let lock = NSLock()
  private var completed = false
  private let completion: (Value) -> Void

  init(_ completion: @escaping (Value) -> Void) {
    self.completion = completion
  }

  func call(_ value: Value) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    lock.unlock()
    completion(value)
  }
}

/// Captures the earliest application-observable native response time before
/// Dart response processing. Apple exposes no original user-click timestamp on
/// UNNotificationResponse; this is the native callback observation time.
final class NotificationResponseDelegateProxy: NSObject, UNUserNotificationCenterDelegate {
  private let downstream: UNUserNotificationCenterDelegate?
  private let responseTimes: NativeNotificationResponseTimes

  init(downstream: UNUserNotificationCenterDelegate?, responseTimes: NativeNotificationResponseTimes) {
    self.downstream = downstream
    self.responseTimes = responseTimes
    super.init()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let observedAt = Int64((Date().timeIntervalSince1970 * 1_000_000).rounded(.down))
    if let payload = response.notification.request.content.userInfo["payload"] as? String {
      responseTimes.record(payload: payload, actionId: response.actionIdentifier, occurredAt: observedAt)
    }
    let completion = NotificationResponseCompletion<Void> { _ in completionHandler() }
    if let downstream = downstream,
       downstream.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
      downstream.userNotificationCenter?(center, didReceive: response) { completion.call(()) }
    } else {
      completion.call(())
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    let completion = NotificationResponseCompletion(completionHandler)
    if let downstream = downstream,
       downstream.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) {
      downstream.userNotificationCenter?(center, willPresent: notification) { completion.call($0) }
    } else {
      completion.call([])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?
  ) {
    downstream?.userNotificationCenter?(center, openSettingsFor: notification)
  }
}
