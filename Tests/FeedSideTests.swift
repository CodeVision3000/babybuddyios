import XCTest
import SwiftData
@testable import BabyBuddy

/// Finishing a breastfeed by its side: the payload each side logs, the repository step every side
/// button shares (the app's Stop sheet, the widgets, the Live Activity, Siri), and which running
/// timer a side tap with no named timer finishes.
@MainActor
final class FeedSideTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var repo: LocalRepository!
    private var savedLastSide: FeedSide?

    override func setUp() async throws {
        container = LocalStore.makeContainer(inMemory: true)
        context = container.mainContext
        repo = LocalRepository(context: context)
        savedLastSide = SharedDefaults.lastFeedSide
        SharedDefaults.lastFeedSide = nil
    }

    override func tearDown() async throws {
        SharedDefaults.lastFeedSide = savedLastSide
    }

    private func timer(_ activity: TimerActivity, child: Int?, start: String = "2024-01-15T10:00:00-05:00")
        -> LocalEntity {
        var payload: [String: Any] = ["name": activity.timerName, "start": start]
        if let child { payload["child"] = child }
        return repo.create(kind: .timer, payload: payload, timerActivity: activity.convertKind)!
    }

    // MARK: Payload

    /// Each side is a breast-milk feed with that side's Baby Buddy method, over the timer's span.
    func testEachSideLogsBreastMilkWithItsMethod() {
        let expected: [FeedSide: String] = [.left: "left breast", .right: "right breast", .both: "both breasts"]
        let feed = timer(.feeding, child: 4)
        for side in FeedSide.allCases {
            let payload = side.feedingPayload(from: feed)
            XCTAssertEqual(payload["type"] as? String, "breast milk", side.rawValue)
            XCTAssertEqual(payload["method"] as? String, expected[side], side.rawValue)
            XCTAssertEqual(payload["child"] as? Int, 4, side.rawValue)
            XCTAssertEqual(payload["start"] as? String, "2024-01-15T10:00:00-05:00", side.rawValue)
            XCTAssertNotNil((payload["end"] as? String).flatMap(APIDate.parse), side.rawValue)
        }
    }

    /// The methods are Baby Buddy's own choices, so the server accepts them.
    func testSideMethodsAreServerChoices() {
        for side in FeedSide.allCases {
            XCTAssertNotNil(FeedingMethod(rawValue: side.method.rawValue))
        }
    }

    // MARK: Finishing

    func testFinishFeedingReplacesTheTimerWithAFeed() throws {
        let feed = timer(.feeding, child: 1)

        let logged = repo.finishFeeding(feed, side: .left)

        let remaining = try context.fetch(FetchDescriptor<LocalEntity>())
        XCTAssertEqual(remaining.count, 1, "The timer goes; only the feed stays")
        XCTAssertEqual(remaining.first?.kind, .feeding)
        XCTAssertEqual(logged?.syncState, .pendingCreate)
        XCTAssertEqual(logged?.payloadObject["method"] as? String, "left breast")
        XCTAssertEqual(logged?.childID, 1)
        let mutations = try context.fetch(FetchDescriptor<PendingMutation>())
        XCTAssertEqual(mutations.map(\.kind), [.feeding])
    }

    /// The side is remembered wherever it was tapped, for the next feed's "Last: Left".
    func testFinishFeedingRemembersTheSide() {
        XCTAssertNil(SharedDefaults.lastFeedSide)
        repo.finishFeeding(timer(.feeding, child: 1), side: .right)
        XCTAssertEqual(SharedDefaults.lastFeedSide, .right)
        repo.finishFeeding(timer(.feeding, child: 1), side: .both)
        XCTAssertEqual(SharedDefaults.lastFeedSide, .both)
    }

    /// The Stop sheet finishes a timer the Stop tap already stopped; its end is that tap.
    func testFinishFeedingAStoppedTimerEndsAtTheStop() {
        let feed = timer(.feeding, child: 1)
        let stop = Date(timeIntervalSince1970: 1_705_331_700) // 10:15 EST
        repo.stopTimer(feed, at: stop)

        let logged = repo.finishFeeding(feed, side: .left)

        XCTAssertEqual((logged?.payloadObject["end"] as? String).flatMap(APIDate.parse), stop)
    }

    // MARK: Which timer

    func testRunningFeedTimerPrefersTheChildsNewestFeed() {
        let older = timer(.feeding, child: 1, start: "2024-01-15T09:00:00-05:00")
        let newer = timer(.feeding, child: 1, start: "2024-01-15T10:00:00-05:00")
        _ = timer(.feeding, child: 2, start: "2024-01-15T11:00:00-05:00")
        _ = timer(.sleep, child: 1, start: "2024-01-15T12:00:00-05:00")

        let found = LocalRepository.runningFeedTimer(childID: 1, in: context)

        XCTAssertEqual(found?.localID, newer.localID)
        XCTAssertNotEqual(found?.localID, older.localID)
    }

    /// No feed for the selected child: an unassigned or other child's feed is still the one running.
    func testRunningFeedTimerFallsBackToAnyFeed() {
        let unassigned = timer(.feeding, child: nil)
        XCTAssertEqual(LocalRepository.runningFeedTimer(childID: 1, in: context)?.localID, unassigned.localID)
    }

    func testRunningFeedTimerIgnoresStoppedAndOtherTimers() {
        _ = timer(.sleep, child: 1)
        let stopped = timer(.feeding, child: 1)
        repo.stopTimer(stopped)
        XCTAssertNil(LocalRepository.runningFeedTimer(childID: 1, in: context))
    }
}
