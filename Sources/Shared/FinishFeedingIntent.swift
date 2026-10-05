import ActivityKit
import AppIntents
import SwiftData
import WidgetKit

// The feed intents. A feed is timed one side at a time, and starting the next side logs the one
// before, so sides come in pairs. Every one of these is a ``LiveActivityIntent`` for the same reason
// as ``LogTimerIntent``: it runs in the app's process, so it can update the feed's Lock Screen /
// Dynamic Island banner as it goes. Each also closes any feed past its hour first (the backup for a
// forgotten timer) and pushes what it changed straight to the server, best-effort via ``TimerPush``.

/// Starts timing a feed on a side, for Siri ("Start feeding on the left"), the Feed control and the
/// Quick Start widget. A feed running on the other side is logged first.
struct StartFeedSideIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Start feeding on a side"
    static var description = IntentDescription(
        "Starts a feeding timer on a side, logging the other side if it's running.")

    @Parameter(title: "Side")
    var side: FeedSide

    static var parameterSummary: some ParameterSummary {
        Summary("Start feeding on \(\.$side)")
    }

    init() {}
    init(side: FeedSide) { self.side = side }

    @MainActor
    func perform() async throws -> some IntentResult {
        Analytics.start()
        Analytics.widgetIntent("StartFeedSide:\(side.rawValue)")
        let context = try FeedFinisher.context()
        var change = LocalRepository(context: context).autoCloseFeeds()
        let started = LocalRepository(context: context).startFeedSide(
            side == .both ? .left : side, childID: SharedDefaults.validChildID)
        change.closed += started.closed
        change.started = started.started
        if started.started != nil { Analytics.timerStarted(activity: TimerActivity.feeding.rawValue, source: .widget) }
        await FeedFinisher.apply(change, in: context)
        return .result()
    }
}

/// "Switch to Right" on a running side's widget or banner: logs that side and starts the other.
/// Takes its timer by id, like ``LogTimerIntent``, and does nothing but clear the banner if that
/// timer is already gone (a second tap, or another device logged it).
struct SwitchFeedSideIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Switch feeding side"
    static var description = IntentDescription("Logs the running side and starts the other one.")
    // The widget's own button; Siri switches by starting the other side.
    static var isDiscoverable = false

    @Parameter(title: "Timer")
    var timerLocalID: String

    init() {}
    init(timerLocalID: String) { self.timerLocalID = timerLocalID }

    @MainActor
    func perform() async throws -> some IntentResult {
        Analytics.start()
        Analytics.widgetIntent("SwitchFeedSide")
        let context = try FeedFinisher.context()
        let repo = LocalRepository(context: context)
        // Read the timer before closing anything: a side switched at or past the hour closes
        // itself first, and the next side must still start.
        var next: (side: FeedSide, child: Int?)?
        if let id = UUID(uuidString: timerLocalID),
           let timer = LocalStore.fetch(localID: id, in: context),
           timer.isRunningTimer {
            next = ((timer.feedSide ?? .right).other, timer.childID)
        }
        var change = repo.autoCloseFeeds()
        if let next {
            let started = repo.startFeedSide(next.side, childID: next.child)
            change.closed += started.closed
            change.started = started.started
        }
        await FeedFinisher.apply(change, in: context, alsoEnd: timerLocalID)
        return .result()
    }
}

/// Finishes the running feed, for Siri ("Finish feeding") and the Finish Feed control: logs it on
/// the side it's timing (both, for a feed that wasn't started on a side).
struct FinishFeedingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish feeding"
    static var description = IntentDescription("Stops the running feeding timer and logs it.")

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        Analytics.start()
        Analytics.widgetIntent("FinishFeeding")
        let context = try FeedFinisher.context()
        let repo = LocalRepository(context: context)
        var change = repo.autoCloseFeeds()
        guard let timer = LocalRepository.runningFeedTimer(
            childID: SharedDefaults.validChildID, in: context)
        else {
            await FeedFinisher.apply(change, in: context)
            // A feed that just closed itself still counts as finished; otherwise there was none.
            if change.closed.isEmpty { throw NoFeedingTimerError() }
            return .result()
        }
        let id = timer.localID
        change.closed.append((id, repo.finishFeeding(timer, side: timer.feedSide ?? .both)?.localID))
        await FeedFinisher.apply(change, in: context)
        return .result()
    }
}

/// A side button on a widget or the Live Activity: "Done" on a side, or Left / Right / Both on a
/// feed that wasn't started on one. Logs the feed that button belongs to. Shaped exactly like
/// ``LogTimerIntent``, the Stop button that works from the banner: plain-text parameters only (the
/// timer's id, and the side's raw value, empty for the side the timer is already timing), and the
/// banner ends even when that timer is already gone, so the button never leaves a stale banner up.
struct FinishFeedTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Finish feeding timer"
    static var description = IntentDescription("Logs a running feeding timer.")
    // The widget's own button; Siri and Shortcuts use ``FinishFeedingIntent``.
    static var isDiscoverable = false

    @Parameter(title: "Timer")
    var timerLocalID: String

    /// A ``FeedSide`` raw value, or empty for the side the timer is timing.
    @Parameter(title: "Side")
    var sideRaw: String

    init() {}
    init(timerLocalID: String, side: FeedSide? = nil) {
        self.timerLocalID = timerLocalID
        self.sideRaw = side?.rawValue ?? ""
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        Analytics.start()
        Analytics.widgetIntent("FinishFeedTimer:\(sideRaw.isEmpty ? "own" : sideRaw)")
        let context = try FeedFinisher.context()
        let repo = LocalRepository(context: context)
        var change = repo.autoCloseFeeds()
        // Only the timer this button belongs to: finishing some other feed would log the wrong one.
        if let id = UUID(uuidString: timerLocalID),
           let timer = LocalStore.fetch(localID: id, in: context),
           timer.isRunningTimer {
            let side = FeedSide(rawValue: sideRaw) ?? timer.feedSide ?? .both
            change.closed.append((id, repo.finishFeeding(timer, side: side)?.localID))
        }
        await FeedFinisher.apply(change, in: context, alsoEnd: timerLocalID)
        return .result()
    }
}

/// The steps the feed intents share: open the store, then deliver a ``FeedChange``.
enum FeedFinisher {
    /// Set by the app at launch to bring the Live Activity in line with the store (start one for a
    /// timer that just started). The intents above run in the app's process, where it's set; it
    /// stays `nil` in the widget extension, whose copy of these types never runs them.
    @MainActor static var reconcileLiveActivity: (() async -> Void)?

    @MainActor
    static func context() throws -> ModelContext {
        let container = try ModelContainer(
            for: LocalStore.schema,
            configurations: ModelConfiguration(schema: LocalStore.schema, url: LocalStore.storeURL))
        return container.mainContext
    }

    /// Push what `change` did to the server, end the banners of the timers it stopped (and of
    /// `alsoEnd`, the timer a widget button belonged to), bring the banner in line with what's
    /// running now, and refresh the widgets.
    @MainActor
    static func apply(_ change: FeedChange, in context: ModelContext, alsoEnd: String? = nil) async {
        for (timer, logged) in change.closed {
            Analytics.timerStopped(activity: TimerActivity.feeding.rawValue, source: .widget)
            // The DELETE goes first: if it finds the timer gone, the create parks instead.
            await TimerPush.pushTimerDelete(localID: timer, in: context)
            if let logged { await TimerPush.pushCreate(localID: logged, in: context) }
        }
        if let started = change.started { await TimerPush.pushCreate(localID: started, in: context) }

        var ended = Set(change.closed.map(\.timer.uuidString))
        if let alsoEnd { ended.insert(alsoEnd) }
        for activity in Activity<RunningTimerAttributes>.activities
        where ended.contains(activity.attributes.timerLocalID) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        await reconcileLiveActivity?()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Thrown by ``FinishFeedingIntent`` when there's no running feeding timer to finish, so Siri or
/// Control Center says why nothing was logged.
struct NoFeedingTimerError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "No feeding timer is running. Start one first."
    }
}
