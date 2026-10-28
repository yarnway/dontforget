import Foundation

@main
struct NotificationResponseTimeTests {
  static func main() {
    let times = NativeNotificationResponseTimes()
    times.record(payload: "first", actionId: "snooze_15", occurredAt: 100)
    times.record(payload: "first", actionId: "snooze_15", occurredAt: 200)
    precondition(times.firstObserved(payload: "first", actionId: "snooze_15") == 100)
    // Readback retains the first time for repeated cold-launch callbacks.
    precondition(times.firstObserved(payload: "first", actionId: "snooze_15") == 100)
    times.record(payload: "first", actionId: "complete", occurredAt: 300)
    precondition(times.firstObserved(payload: "first", actionId: "complete") == 300)
    times.record(payload: "unknown", actionId: "open", occurredAt: 400)
    precondition(times.firstObserved(payload: "unknown", actionId: "open") == nil)
    let oversized = String(repeating: "x", count: 2049)
    times.record(payload: oversized, actionId: "complete", occurredAt: 500)
    precondition(times.firstObserved(payload: oversized, actionId: "complete") == nil)
    for i in 0..<31 {
      times.record(payload: "next-\(i)", actionId: "complete", occurredAt: Int64(i))
    }
    precondition(times.firstObserved(payload: "first", actionId: "snooze_15") == nil)
    precondition(times.firstObserved(payload: "first", actionId: "complete") == 300)
    precondition(times.firstObserved(payload: "next-30", actionId: "complete") == 30)
    var completions = 0
    let completion = NotificationResponseCompletion<Void> { _ in completions += 1 }
    completion.call(())
    completion.call(())
    precondition(completions == 1)
    print("PASS: native response FIFO, first timestamp, input bounds, completion once")
  }
}
