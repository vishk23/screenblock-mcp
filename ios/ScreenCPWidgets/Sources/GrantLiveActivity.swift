import SwiftUI
import WidgetKit
import ActivityKit

/// The grant countdown, rendered on the Lock Screen and in the Dynamic Island.
/// `Text(timerInterval:)` ticks down automatically — no updates required.
struct GrantLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GrantActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            HStack(spacing: 14) {
                Image(systemName: "hourglass")
                    .font(.title2).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(context.attributes.groupName) unlocked")
                        .font(.headline).foregroundStyle(.white)
                    Text("re-locks when the timer ends")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                Spacer()
                Text(timerInterval: Date()...context.state.expiresAt, countsDown: true)
                    .font(.system(.title2, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 78)
            }
            .padding(18)
            .activityBackgroundTint(Color(red: 0.14, green: 0.09, blue: 0.32))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.groupName, systemImage: "hourglass")
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.expiresAt, countsDown: true)
                        .monospacedDigit().frame(width: 60).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Enjoy it — it re-locks itself when time's up.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            } compactLeading: {
                Image(systemName: "hourglass").foregroundStyle(.white)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.expiresAt, countsDown: true)
                    .monospacedDigit().frame(width: 44)
            } minimal: {
                Image(systemName: "hourglass").foregroundStyle(.white)
            }
        }
    }
}

@main
struct ScreenCPWidgetBundle: WidgetBundle {
    var body: some Widget { GrantLiveActivity() }
}
