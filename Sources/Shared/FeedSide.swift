import AppIntents
import SwiftData

/// The breast a feed ended on — the one detail a breastfeeding timer still needs once it stops, so
/// picking it is enough to log the feed with no form. Each side is a breast-milk feeding with the
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

extension LocalRepository {
    /// Logs `timer` as a breast-milk feeding on `side`, removing the timer, and remembers the side
    /// so the next feed can suggest the other one. Works on a running or an already stopped timer.
    @discardableResult
    func finishFeeding(_ timer: LocalEntity, side: FeedSide) -> LocalEntity? {
        let logged = convertTimer(timer, to: .feeding, payload: side.feedingPayload(from: timer))
        if logged != nil { SharedDefaults.lastFeedSide = side }
        return logged
    }

    /// The running feeding timer a side tap finishes when nothing names one (Siri, Control Center):
    /// the newest for `childID`, else the newest with no child or with any child.
    static func runningFeedTimer(childID: Int?, in context: ModelContext) -> LocalEntity? {
        let descriptor = FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == "timer" },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        let feeds = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.isRunningTimer && TimerActivity(timer: $0) == .feeding }
        return feeds.first { $0.childID == childID } ?? feeds.first
    }
}
