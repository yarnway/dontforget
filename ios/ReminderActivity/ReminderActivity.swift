import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ReminderActivityBundle: WidgetBundle {
  var body: some Widget { ReminderActivityWidget() }
}

struct ReminderActivityWidget: Widget {
  private let accent = Color(red: 0.48, green: 0.86, blue: 0.82)

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ReminderActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label(context.state.countdownLabel, systemImage: "bell.badge")
            .font(.caption.weight(.semibold)).foregroundStyle(accent)
          Spacer()
          Text("DontForget").font(.caption2).foregroundStyle(.white.opacity(0.65))
        }
        Text(context.state.title).font(.headline).lineLimit(2)
        HStack {
          if context.isStale {
            Text(context.state.dueLabel).font(.subheadline.weight(.medium))
          } else {
            Text(timerInterval: Date.now...max(Date.now, context.state.endTime), countsDown: true)
              .font(.title2.monospacedDigit().weight(.semibold))
              .contentTransition(.numericText())
          }
          Spacer()
          Label(context.state.openLabel, systemImage: "arrow.up.right")
            .font(.caption).foregroundStyle(accent)
        }
      }
      .padding(16)
      .foregroundStyle(.white)
      .activityBackgroundTint(Color(red: 0.07, green: 0.13, blue: 0.14))
      .activitySystemActionForegroundColor(.white)
      .widgetURL(context.state.routeURL)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "bell.badge.fill").foregroundStyle(accent)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(context.state.endTime, style: .time).font(.caption.monospacedDigit())
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 6) {
            Text(context.state.title).font(.headline).lineLimit(2)
            if context.isStale {
              Text(context.state.dueLabel).foregroundStyle(accent)
            } else {
              Text(timerInterval: Date.now...max(Date.now, context.state.endTime), countsDown: true)
                .font(.title3.monospacedDigit()).foregroundStyle(accent)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        Image(systemName: context.isStale ? "bell.fill" : "bell.badge.fill").foregroundStyle(accent)
      } compactTrailing: {
        if context.isStale {
          Image(systemName: "clock.badge.exclamationmark").foregroundStyle(accent)
        } else {
          Text(timerInterval: Date.now...max(Date.now, context.state.endTime), countsDown: true)
            .monospacedDigit().frame(maxWidth: 58)
        }
      } minimal: {
        Image(systemName: "bell.fill").foregroundStyle(accent)
      }
      .widgetURL(context.state.routeURL)
      .keylineTint(accent)
    }
  }
}
