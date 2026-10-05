import ActivityKit
import AppIntents
import SwiftData
import WidgetKit

/// Finishes the running breastfeed on a side, for Siri ("Finish feeding on the left") and the Finish
/// Feed control: logs it (start = the timer's start, end = now, breast milk, that side) and removes
/// the timer, with no form. Nothing names a timer here, so it finishes the selected child's running
/// feed. The side buttons on a widget or the Live Activity name theirs, through
/// ``FinishFeedTimerIntent``.
///
/// A ``LiveActivityIntent`` for the same reason as ``LogTimerIntent``: it runs in the app's process,
/// so it can end the feed's Lock Screen / Dynamic Island banner as it logs.
struct FinishFeedingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish feeding"
    static var description = IntentDescription(
        "Stops the running feeding timer and logs a breast milk feed on the side you choose.")

    @Parameter(title: "Side")
    var side: FeedSide

    static var parameterSummary: some ParameterSummary {
        Summary("Finish feeding on \(\.$side)")
    }

    init() {}
    init(side: FeedSide) { self.side = side }

    @MainActor
    func perform() async throws -> some IntentResult {
        // May run in a fresh background launch of the app process, so start analytics defensively.
        Analytics.start()
        Analytics.widgetIntent("FinishFeeding:\(side.rawValue)")
        let context = try FeedFinisher.context()
        guard let timer = LocalRepository.runningFeedTimer(
            childID: SharedDefaults.selectedChildID, in: context)
        else { throw NoFeedingTimerError() }
        await FeedFinisher.finish(timer, side: side, in: context)
        return .result()
    }
}

/// A side button on the Active Timer widget, the Quick Start Lock Screen widget or the Live
/// Activity: finishes the feed that button belongs to. Shaped exactly like ``LogTimerIntent``, the
/// Stop button beside it: a required timer id, and the banner ends even when that timer is already
/// gone (a second tap, or another device logged it), so the button never leaves a stale banner up.
struct FinishFeedTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish feeding timer"
    static var description = IntentDescription("Logs a running feeding timer on the side you choose.")
    // The widget's own button; Siri and Shortcuts use ``FinishFeedingIntent``.
    static var isDiscoverable = false

    @Parameter(title: "Side")
    var side: FeedSide

    @Parameter(title: "Timer")
    var timerLocalID: String

    init() {}
    init(side: FeedSide, timerLocalID: String) {
        self.side = side
        self.timerLocalID = timerLocalID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        Analytics.start()
        Analytics.widgetIntent("FinishFeedTimer:\(side.rawValue)")
        let context = try FeedFinisher.context()
        // Only the timer this button belongs to: finishing some other feed would log the wrong one.
        if let id = UUID(uuidString: timerLocalID),
           let timer = LocalStore.fetch(localID: id, in: context),
           timer.isRunningTimer {
            await FeedFinisher.finish(timer, side: side, in: context)
        } else {
            await FeedFinisher.endLiveActivity(timerLocalID: timerLocalID)
            WidgetCenter.shared.reloadAllTimelines()
        }
        return .result()
    }
}

/// The steps both intents share: log, push, end the banner, refresh the widgets.
enum FeedFinisher {
    @MainActor
    static func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(schema: LocalStore.schema, url: LocalStore.storeURL))
        return container.mainContext
    }

    @MainActor
    static func finish(_ timer: LocalEntity, side: FeedSide, in context: ModelContext) async {
        // Read before logging: the conversion deletes the timer from the store.
        let localID = timer.localID
        let logged = LocalRepository(context: context).finishFeeding(timer, side: side)
        Analytics.timerStopped(activity: TimerActivity.feeding.rawValue, source: .widget)
        // The DELETE goes first: if it finds the timer gone, the create parks instead.
        await TimerPush.pushTimerDelete(localID: localID, in: context)
        if let logged { await TimerPush.pushCreate(localID: logged.localID, in: context) }
        await endLiveActivity(timerLocalID: localID.uuidString)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// End any running-timer Live Activity for `timerLocalID`. A no-op in the widget-extension copy
    /// of the type, where `activities` is empty.
    @MainActor
    static func endLiveActivity(timerLocalID: String) async {
        for activity in Activity<RunningTimerAttributes>.activities
        where activity.attributes.timerLocalID == timerLocalID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Thrown by ``FinishFeedingIntent`` when there's no running feeding timer to finish, so Siri or
/// Control Center says why nothing was logged.
struct NoFeedingTimerError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "No feeding timer is running. Start one first."
    }
}
