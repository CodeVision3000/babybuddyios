import AppIntents
import SwiftUI
import WidgetKit

// Control Center, Lock Screen and Action button controls (iOS 18). Each one runs the same intent
// as the matching widget button, so a control logs exactly what a widget tap would.

/// Logs a diaper change in one tap. Wet, Solid or Wet + Solid is chosen when the control is added
/// (the Quick Log feed is offered too), so a Lock Screen slot can be "Wet" and another "Solid".
@available(iOS 18.0, *)
struct DiaperControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "BabyBuddyDiaperControl",
                                      intent: DiaperControlConfiguration.self) { configuration in
            ControlWidgetButton(action: QuickLogIntent(action: configuration.action)) {
                Label(configuration.action.controlTitle, systemImage: configuration.action.systemImage)
            }
        }
        .displayName("Log diaper")
        .description("Logs a diaper change in one tap.")
        .promptsForUserConfiguration()
    }
}

@available(iOS 18.0, *)
struct DiaperControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Diaper"
    static var isDiscoverable = false

    @Parameter(title: "Log", default: .wetDiaper)
    var action: QuickLogAction

    func perform() async throws -> some IntentResult { .result() }
}

/// Starts a feed on the side chosen when the control is added. Sides come in pairs, so a control
/// per side covers a whole feed: Left starts it, Right logs Left and starts Right.
@available(iOS 18.0, *)
struct StartFeedControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "BabyBuddyStartFeedControl",
                                      intent: StartFeedControlConfiguration.self) { configuration in
            ControlWidgetButton(action: StartFeedSideIntent(side: configuration.side)) {
                Label("Feed \(configuration.side.title.lowercased())",
                      systemImage: TimerActivity.feeding.systemImage)
            }
        }
        .displayName("Feed on a side")
        .description("Starts a feeding timer on a side, logging the other side.")
        .promptsForUserConfiguration()
    }
}

@available(iOS 18.0, *)
struct StartFeedControlConfiguration: ControlConfigurationIntent {
    static var title: LocalizedStringResource = "Feed on a side"
    static var isDiscoverable = false

    @Parameter(title: "Side", default: .left)
    var side: FeedSide

    func perform() async throws -> some IntentResult { .result() }
}

/// Finishes the running feed on the side it's timing.
@available(iOS 18.0, *)
struct FinishFeedControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "BabyBuddyFinishFeedControl") {
            ControlWidgetButton(action: FinishFeedingIntent()) {
                Label("Finish feed", systemImage: "stop.fill")
            }
        }
        .displayName("Finish feed")
        .description("Stops the feeding timer and logs its side.")
    }
}

private extension QuickLogAction {
    /// What the control says it logs: "Wet diaper", or "Quick feed" for the feeding action.
    var controlTitle: String {
        switch self {
        case .wetDiaper: return "Wet diaper"
        case .solidDiaper: return "Solid diaper"
        case .wetAndSolidDiaper: return "Wet + solid"
        case .quickFeed: return "Quick feed"
        }
    }
}
