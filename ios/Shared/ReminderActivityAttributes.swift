import ActivityKit
import Foundation

@available(iOS 16.2, *)
struct ReminderActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var title: String
    var endTime: Date
    var payload: String
    var language: String

    var countdownLabel: String {
      language == "zh" ? "提醒倒计时" : language == "ja" ? "リマインダー" : "Upcoming reminder"
    }
    var dueLabel: String {
      language == "zh" ? "已到提醒时间" : language == "ja" ? "予定の時刻です" : "Reminder is due"
    }
    var openLabel: String {
      language == "zh" ? "查看事项" : language == "ja" ? "タスクを開く" : "View task"
    }
    var routeURL: URL? {
      var components = URLComponents()
      components.scheme = "dontforget-live"
      components.host = "reminder"
      components.queryItems = [URLQueryItem(name: "payload", value: payload)]
      return components.url
    }
  }
  let selectionID: String
}
