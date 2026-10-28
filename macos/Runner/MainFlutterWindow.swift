import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var menuCommands: MacMenuCommands?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    menuCommands = MacMenuCommands(
      window: self, messenger: flutterViewController.engine.binaryMessenger)

    let scheduling = FlutterMethodChannel(
      name: "dontforget/notification_schedule",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    scheduling.setMethodCallHandler { call, result in
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
