import Foundation

/// The action a Stop control performs for a running timer — the single source of truth shared by
/// the Active Timer widget and the Live Activity so both route identically:
///
/// - sleep / tummy time (`isInstantLoggable`) → log in one tap via `LogTimerIntent`
/// - feeding on a side → "Switch to <other side>" (`SwitchFeedSideIntent`) and "Done"
///   (`FinishFeedTimerIntent` on its own side), since sides come in pairs
/// - feeding not started on a side → one button per side via `FinishFeedTimerIntent`
/// - pumping → open a pre-filled convert form (needs an amount)
/// - uncategorized / custom timer → open the Stop sheet to pick a type
enum TimerStopRoute: Equatable {
    /// Instant-loggable: record via `LogTimerIntent(timerLocalID:)` in one tap (no app launch).
    case log(localID: String)
    /// A feed not started on a side: Left / Right / Both, each logging it via
    /// `FinishFeedTimerIntent` (no app launch).
    case feedSide(localID: String)
    /// A feed timed on `side`: switch to the other side, or finish on this one (no app launch).
    case feedPair(localID: String, side: FeedSide)
    /// Needs extra fields: open the pre-filled convert form via a `babybuddy://convert` deep link.
    case convertForm(localID: String, kind: EntityKind)
    /// Uncategorized/custom timer: open the Stop sheet via a `babybuddy://stop` deep link.
    case openActions(localID: String)

    /// Resolve the route for a timer's activity (or `nil` for an uncategorized timer) and, for a
    /// feed, the side it's timing (``FeedSide/init(timerName:)``).
    static func resolve(localID: String, activity: TimerActivity?, side: FeedSide? = nil) -> TimerStopRoute {
        guard let activity else { return .openActions(localID: localID) }
        if activity == .feeding {
            return side.map { .feedPair(localID: localID, side: $0) } ?? .feedSide(localID: localID)
        }
        return activity.isInstantLoggable
            ? .log(localID: localID)
            : .convertForm(localID: localID, kind: activity.convertKind)
    }

    /// The `babybuddy://` deep link the route opens, or `nil` for `.log` and the feed routes (which run
    /// an intent rather than launching the app).
    var deepLink: URL? {
        switch self {
        case .log, .feedSide, .feedPair:
            return nil
        case .convertForm(let id, let kind):
            return URL(string: "babybuddy://convert/\(id)/\(kind.rawValue)")
        case .openActions(let id):
            return URL(string: "babybuddy://stop/\(id)")
        }
    }
}
