import AppIntents
import SwiftData

/// A breastfeeding side. A feed is timed one side at a time ("Feeding · Left"), and starting the
/// next side logs the one before, so a side is all a breastfeed needs to log with no form. Each side is a breast-milk feeding with the
/// matching Baby Buddy method. A bottle feed needs an amount, so it still goes through the editor.
enum FeedSide: String, AppEnum, CaseIterable {
    case left, right, both

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Side" }

    static var caseDisplayRepresentations: [FeedSide: DisplayRepresentation] {
        [.left: DisplayRepresentation(title: "Left", synonyms: ["left side", "left breast"]),
         .right: DisplayRepresentation(title: "Right", synonyms: ["right side", "right breast"]),
         .both: DisplayRepresentation(title: "Both", synonyms: ["both sides", "both breasts"])]
    }

    /// Button label, in the app and on the roomier widgets.
    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .both: return "Both"
        }
    }

    /// One-letter label for the tight spots: the Lock Screen and the Dynamic Island.
    var shortTitle: String {
        switch self {
        case .left: return "L"
        case .right: return "R"
        case .both: return "Both"
        }
    }

    var method: FeedingMethod {
        switch self {
        case .left: return .leftBreast
        case .right: return .rightBreast
        case .both: return .bothBreasts
        }
    }

    /// The two sides a feed is timed on; `both` is only for logging a feed that wasn't timed by side.
    static let timedSides: [FeedSide] = [.left, .right]

    /// The side a feed pairs with: left after right, right after left.
    var other: FeedSide {
        switch self {
        case .left: return .right
        case .right, .both: return .left
        }
    }

    /// The running timer's name for a feed timed on this side, "Feeding · Left". The side rides in
    /// the name so it reaches the server and every other device with the timer.
    var timerName: String { "\(TimerActivity.feeding.timerName) · \(title)" }

    /// The side a timer's name says it's timing, or `nil` for any other name.
    init?(timerName: String) {
        guard let side = FeedSide.timedSides.first(where: { $0.timerName == timerName }) else { return nil }
        self = side
    }

    /// The side to start next, so sides come in pairs: the other side from the last one logged,
    /// else left.
    static var suggestedNext: FeedSide { SharedDefaults.lastFeedSide.map(\.other) ?? .left }

    /// How long a side may run before it closes itself, as a backup for a forgotten timer: it's
    /// logged as exactly this long. `BB_FEED_AUTOCLOSE_SECONDS=<n>` (DEBUG) shortens it for tests.
    static var autoCloseAfter: TimeInterval {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["BB_FEED_AUTOCLOSE_SECONDS"], let n = Double(s) {
            return n
        }
        #endif
        return 3600
    }

    /// The `feedings` body for `timer` finished on this side: its child, start and end
    /// (``LocalEntity/stoppedTimerPayload()``), breast milk, and this side's method. Those are all
    /// Baby Buddy requires; the amount is optional and omitted.
    func feedingPayload(from timer: LocalEntity) -> [String: Any] {
        var payload = timer.stoppedTimerPayload()
        payload["type"] = FeedingType.breastMilk.rawValue
        payload["method"] = method.rawValue
        return payload
    }
}

/// What a feed action changed, so an intent can push exactly that: the timers it stopped (with the
/// feeding each was logged as) and the timer it started.
struct FeedChange {
    var closed: [(timer: UUID, logged: UUID?)] = []
    var started: UUID?

    var isEmpty: Bool { closed.isEmpty && started == nil }
}

extension LocalEntity {
    /// The side a running feeding timer is timing, from its name; `nil` for a feed timer that
    /// wasn't started on a side (or any other timer).
    var feedSide: FeedSide? {
        guard kind == .timer else { return nil }
        return (payloadObject["name"] as? String).flatMap(FeedSide.init(timerName:))
    }
}

extension LocalRepository {
    /// Logs `timer` as a breast-milk feeding on `side`, removing the timer, and remembers the side
    /// so the next feed can suggest the other one. Works on a running or an already stopped timer.
    @discardableResult
    func finishFeeding(_ timer: LocalEntity, side: FeedSide) -> LocalEntity? {
        let logged = convertTimer(timer, to: .feeding, payload: side.feedingPayload(from: timer))
        if logged != nil { SharedDefaults.lastFeedSide = side }
        return logged
    }

    /// Starts timing a feed on `side` for `childID` from `start`. Sides come in pairs, so a feed
    /// already running for that child on the other side is logged first, ending where this one
    /// starts; one with no side is taken to be the other side. Starting the side that's already
    /// running does nothing.
    @discardableResult
    func startFeedSide(_ side: FeedSide, childID: Int?, at start: Date = .now) -> FeedChange {
        var change = FeedChange()
        let running = Self.runningFeedTimers(in: context).filter { $0.childID == childID }
        if running.contains(where: { $0.feedSide == side }) { return change }
        for timer in running {
            change.closed.append(close(timer, side: timer.feedSide ?? side.other,
                                       at: max(start, timer.timestamp)))
        }
        var payload: [String: Any] = [
            "start": APIDate.isoDateTime.string(from: start),
            "name": side.timerName,
        ]
        if let childID { payload["child"] = childID }
        change.started = create(kind: .timer, payload: payload, timerActivity: .feeding)?.localID
        return change
    }

    /// Logs every side that has run past ``FeedSide/autoCloseAfter`` as exactly that long, on that
    /// side. The backup for a forgotten timer: it runs whenever the app, a widget button or Siri next
    /// touches the store, and the record is the same whenever that is. Only feeds timed on a side
    /// close: a plain "Feeding" timer (the web UI, another app, a bottle) could be anything, so it's
    /// left for someone to log.
    @discardableResult
    func autoCloseFeeds(now: Date = .now) -> FeedChange {
        let limit = FeedSide.autoCloseAfter
        var change = FeedChange()
        for timer in Self.runningFeedTimers(in: context) where timer.timestamp.addingTimeInterval(limit) <= now {
            guard let side = timer.feedSide else { continue }
            change.closed.append(close(timer, side: side, at: timer.timestamp.addingTimeInterval(limit)))
        }
        return change
    }

    /// Stops `timer` at `end` and logs it on `side`.
    private func close(_ timer: LocalEntity, side: FeedSide, at end: Date) -> (timer: UUID, logged: UUID?) {
        let id = timer.localID // read first: logging deletes the timer
        stopTimer(timer, at: end)
        return (id, finishFeeding(timer, side: side)?.localID)
    }

    /// The side to start next for `childID`: the other side from one running now, else
    /// ``FeedSide/suggestedNext``.
    static func nextFeedSide(childID: Int?, in context: ModelContext) -> FeedSide {
        let running = runningFeedTimers(in: context).first { $0.childID == childID }
        return running?.feedSide?.other ?? FeedSide.suggestedNext
    }

    /// When the next running side will close itself, or `nil` with none running.
    static func nextFeedAutoClose(in context: ModelContext) -> Date? {
        runningFeedTimers(in: context).filter { $0.feedSide != nil }.map { $0.timestamp.addingTimeInterval(FeedSide.autoCloseAfter) }.min()
    }

    /// Every running feeding timer, newest first.
    static func runningFeedTimers(in context: ModelContext) -> [LocalEntity] {
        let descriptor = FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == "timer" },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        return ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.isRunningTimer && TimerActivity(timer: $0) == .feeding }
    }

    /// The running feeding timer a side tap finishes when nothing names one (Siri, Control Center):
    /// the newest for `childID`, else the newest with no child or with any child.
    static func runningFeedTimer(childID: Int?, in context: ModelContext) -> LocalEntity? {
        let feeds = runningFeedTimers(in: context)
        return feeds.first { $0.childID == childID } ?? feeds.first
    }
}
