import ActivityKit
import AppIntents
import SwiftData
import WidgetKit

/// Finishes a breastfeeding timer by picking the side it ended on: logs the feed (start = the
/// timer's start, end = now, breast milk, that side) and removes the timer, with no form. Behind
/// the side buttons on the Active Timer widget, the Live Activity, the Quick Start Lock Screen
/// widget and the Finish Feed control, and Siri's "Finish feeding on the left side".
///
/// With a `timerLocalID` it finishes that timer; without one (Siri, Control Center) it finds the
/// selected child's running feed. The logged feed is pushed to the server right away (best-effort
/// via ``TimerPush``); on failure it stays queued for the app's next sync.
///
/// A ``LiveActivityIntent`` for the same reason as ``LogTimerIntent``: it runs in the app's process,
/// so it can end the timer's Lock Screen / Dynamic Island banner the moment a side is tapped.
struct FinishFeedingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish feeding"
    static var description = IntentDescription(
        "Stops the running feeding timer and logs a breast milk feed on the side you choose.")

    @Parameter(title: "Side")
    var side: FeedSide

    @Parameter(title: "Timer")
    var timerLocalID: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Finish feeding on \(\.$side)")
    }

    init() {}
    init(side: FeedSide, timerLocalID: String? = nil) {
        self.side = side
        self.timerLocalID = timerLocalID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // May run in a fresh background launch of the app process, so start analytics defensively.
        Analytics.start()
        Analytics.widgetIntent("FinishFeeding:\(side.rawValue)")
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(schema: LocalStore.schema, url: LocalStore.storeURL))
        let context = container.mainContext

        // A widget names its timer; if that one is already logged (a second tap, or another
        // device), finishing some other feed instead would log the wrong one, so stop there.
        let candidate: LocalEntity? = if let timerLocalID {
            UUID(uuidString: timerLocalID).flatMap { LocalStore.fetch(localID: $0, in: context) }
        } else {
            LocalRepository.runningFeedTimer(childID: SharedDefaults.selectedChildID, in: context)
        }
        guard let timer = candidate, timer.isRunningTimer else { throw NoFeedingTimerError() }

        // Read before logging: the conversion deletes the timer from the store.
        let localID = timer.localID
        let logged = LocalRepository(context: context).finishFeeding(timer, side: side)
        Analytics.timerStopped(activity: TimerActivity.feeding.rawValue, source: .widget)
        // The DELETE goes first: if it finds the timer gone, the create parks instead.
        await TimerPush.pushTimerDelete(localID: localID, in: context)
        if let logged { await TimerPush.pushCreate(localID: logged.localID, in: context) }

        let id = localID.uuidString
        for activity in Activity<RunningTimerAttributes>.activities
        where activity.attributes.timerLocalID == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

/// Thrown by ``FinishFeedingIntent`` when there's no running feeding timer to finish, so Siri or
/// Control Center says why nothing was logged.
struct NoFeedingTimerError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "No feeding timer is running. Start one first."
    }
}
