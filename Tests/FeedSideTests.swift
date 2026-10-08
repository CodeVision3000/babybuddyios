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

    // MARK: Timing a feed one side at a time

    private let t0 = Date(timeIntervalSince1970: 1_705_330_800) // 2024-01-15 10:00 EST

    private func runningTimers() throws -> [LocalEntity] {
        try context.fetch(FetchDescriptor<LocalEntity>()).filter(\.isRunningTimer)
    }
    private func feedings() throws -> [LocalEntity] {
        try context.fetch(FetchDescriptor<LocalEntity>()).filter { $0.kind == .feeding }
    }

    /// The side rides in the timer's name, so it reaches the server and every other device.
    func testSideTimerNamesRoundTrip() {
        XCTAssertEqual(FeedSide.left.timerName, "Feeding · Left")
        XCTAssertEqual(FeedSide(timerName: "Feeding · Right"), .right)
        XCTAssertNil(FeedSide(timerName: "Feeding"))
        XCTAssertNil(FeedSide(timerName: "Feeding · Both"), "Both isn't a side a feed is timed on")
        XCTAssertEqual(TimerActivity(timerName: "Feeding · Left"), .feeding,
                       "A side timer pulled from the server, with no local hint, is still a feed")
        XCTAssertEqual(FeedSide.left.other, .right)
        XCTAssertEqual(FeedSide.right.other, .left)
    }

    func testStartingASideStartsANamedFeedTimer() throws {
        let change = repo.startFeedSide(.left, childID: 1, at: t0)

        let timers = try runningTimers()
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers.first?.localID, change.started)
        XCTAssertEqual(timers.first?.feedSide, .left)
        XCTAssertEqual(timers.first.flatMap(TimerActivity.init(timer:)), .feeding)
        XCTAssertEqual(timers.first?.timestamp, t0)
        XCTAssertTrue(change.closed.isEmpty)
    }

    /// Sides come in pairs: starting the next side logs the one before, ending where it starts.
    func testStartingTheOtherSideLogsTheFirst() throws {
        repo.startFeedSide(.left, childID: 1, at: t0)
        let change = repo.startFeedSide(.right, childID: 1, at: t0.addingTimeInterval(600))

        let logged = try feedings()
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.payloadObject["method"] as? String, "left breast")
        XCTAssertEqual((logged.first?.payloadObject["start"] as? String).flatMap(APIDate.parse), t0)
        XCTAssertEqual((logged.first?.payloadObject["end"] as? String).flatMap(APIDate.parse),
                       t0.addingTimeInterval(600))
        XCTAssertEqual(change.closed.count, 1)
        XCTAssertEqual(change.closed.first?.logged, logged.first?.localID)

        let timers = try runningTimers()
        XCTAssertEqual(timers.map(\.feedSide), [.right])
        XCTAssertEqual(SharedDefaults.lastFeedSide, .left)
    }

    func testStartingTheRunningSideDoesNothing() throws {
        repo.startFeedSide(.left, childID: 1, at: t0)
        let change = repo.startFeedSide(.left, childID: 1, at: t0.addingTimeInterval(60))

        XCTAssertTrue(change.isEmpty)
        XCTAssertEqual(try runningTimers().count, 1)
        XCTAssertTrue(try feedings().isEmpty)
    }

    /// One child's next side never logs another child's feed.
    func testAnotherChildsFeedKeepsRunning() throws {
        repo.startFeedSide(.left, childID: 1, at: t0)
        repo.startFeedSide(.right, childID: 2, at: t0.addingTimeInterval(60))

        XCTAssertEqual(try runningTimers().count, 2)
        XCTAssertTrue(try feedings().isEmpty)
    }

    /// A feed started without a side is taken to be the other side of the one starting.
    func testAFeedWithNoSideIsLoggedAsTheOtherSide() throws {
        _ = timer(.feeding, child: 1)
        repo.startFeedSide(.right, childID: 1, at: Date(timeIntervalSince1970: 1_705_331_400))

        XCTAssertEqual(try feedings().first?.payloadObject["method"] as? String, "left breast")
        XCTAssertEqual(try runningTimers().map(\.feedSide), [.right])
    }

    // MARK: Closing a forgotten side

    /// A side still running past the hour is logged as exactly an hour, on its own side.
    func testAutoCloseCapsAForgottenSideAtAnHour() throws {
        repo.startFeedSide(.right, childID: 1, at: t0)
        let change = repo.autoCloseFeeds(now: t0.addingTimeInterval(3 * 3600))

        let logged = try feedings()
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.payloadObject["method"] as? String, "right breast")
        XCTAssertEqual((logged.first?.payloadObject["end"] as? String).flatMap(APIDate.parse),
                       t0.addingTimeInterval(FeedSide.autoCloseAfter))
        XCTAssertTrue(try runningTimers().isEmpty)
        XCTAssertEqual(change.closed.count, 1)
    }

    func testAutoCloseLeavesAFeedUnderTheHour() throws {
        repo.startFeedSide(.left, childID: 1, at: t0)
        let change = repo.autoCloseFeeds(now: t0.addingTimeInterval(FeedSide.autoCloseAfter - 1))

        XCTAssertTrue(change.isEmpty)
        XCTAssertEqual(try runningTimers().count, 1)
        XCTAssertEqual(LocalRepository.nextFeedAutoClose(in: context), t0.addingTimeInterval(FeedSide.autoCloseAfter))
    }

    /// A plain "Feeding" timer (the web UI, another device, a bottle) could be anything, so only
    /// feeds timed on a side close themselves.
    func testAutoCloseLeavesAFeedWithNoSide() throws {
        _ = timer(.feeding, child: 1)
        repo.autoCloseFeeds(now: t0.addingTimeInterval(3 * 3600))

        XCTAssertEqual(try runningTimers().count, 1)
        XCTAssertTrue(try feedings().isEmpty)
        XCTAssertNil(LocalRepository.nextFeedAutoClose(in: context))
    }

    /// Only feeds close themselves; a long nap runs on.
    func testAutoCloseLeavesOtherTimers() throws {
        _ = timer(.sleep, child: 1, start: "2024-01-15T06:00:00-05:00")
        repo.autoCloseFeeds(now: t0.addingTimeInterval(3 * 3600))

        XCTAssertEqual(try runningTimers().count, 1)
        XCTAssertTrue(try feedings().isEmpty)
    }

    // MARK: Which side is next

    func testNextSideAlternates() throws {
        XCTAssertEqual(FeedSide.suggestedNext, .left, "Left with nothing logged yet")
        SharedDefaults.lastFeedSide = .left
        XCTAssertEqual(FeedSide.suggestedNext, .right)

        // A side running now wins over the last one logged.
        repo.startFeedSide(.right, childID: 1, at: t0)
        XCTAssertEqual(LocalRepository.nextFeedSide(childID: 1, in: context), .left)
        XCTAssertEqual(LocalRepository.nextFeedSide(childID: 2, in: context), .right)
    }

    /// The heads-up fires when the side closes, and names it.
    func testAutoCloseNotice() throws {
        repo.startFeedSide(.left, childID: 1, at: t0)
        let timer = try XCTUnwrap(try runningTimers().first)
        let request = FeedAutoClosePolicy.request(for: timer, childName: "Maya")

        XCTAssertEqual(request.fireDate, t0.addingTimeInterval(FeedSide.autoCloseAfter))
        XCTAssertTrue(request.id.hasPrefix("feedclose-"))
        XCTAssertTrue(request.body.contains("Maya's left side"), request.body)
    }

    // MARK: Banner buttons (LogTimerIntent carrying a FeedButtonAction)

    func testFeedButtonActionRoundTrips() {
        let id = UUID().uuidString
        let action = FeedButtonAction(.switch, timerLocalID: id)
        XCTAssertEqual(FeedButtonAction(encoded: action.encoded), action)
        XCTAssertNil(FeedButtonAction(encoded: id), "A plain timer id is Stop's, not a feed button's")
        XCTAssertNil(FeedButtonAction(encoded: "feed:nap:\(id)"))
    }

    func testSwitchButtonLogsTheSideAndStartsTheOther() async throws {
        let hook = FeedFinisher.reconcileLiveActivity
        FeedFinisher.reconcileLiveActivity = nil
        defer { FeedFinisher.reconcileLiveActivity = hook }
        repo.startFeedSide(.left, childID: 1)
        let left = try XCTUnwrap(try runningTimers().first)

        await FeedButtonAction(.switch, timerLocalID: left.localID.uuidString).perform(in: context)

        XCTAssertEqual(try feedings().first?.payloadObject["method"] as? String, "left breast")
        XCTAssertEqual(try runningTimers().map(\.feedSide), [.right])
    }

    func testDoneButtonLogsItsOwnSide() async throws {
        let hook = FeedFinisher.reconcileLiveActivity
        FeedFinisher.reconcileLiveActivity = nil
        defer { FeedFinisher.reconcileLiveActivity = hook }
        repo.startFeedSide(.right, childID: 1)
        let right = try XCTUnwrap(try runningTimers().first)

        await FeedButtonAction(.done, timerLocalID: right.localID.uuidString).perform(in: context)
        // A second tap (the banner lingering) logs nothing more.
        await FeedButtonAction(.done, timerLocalID: right.localID.uuidString).perform(in: context)

        XCTAssertEqual(try feedings().map { $0.payloadObject["method"] as? String }, ["right breast"])
        XCTAssertTrue(try runningTimers().isEmpty)
    }

    func testStartButtonStartsASideAndLogsTheOther() async throws {
        let hook = FeedFinisher.reconcileLiveActivity
        FeedFinisher.reconcileLiveActivity = nil
        let savedChild = SharedDefaults.selectedChildID
        defer { FeedFinisher.reconcileLiveActivity = hook; SharedDefaults.selectedChildID = savedChild }
        SharedDefaults.selectedChildID = 1
        let encoded = FeedButtonAction(.startLeft, timerLocalID: "").encoded
        XCTAssertEqual(FeedButtonAction(encoded: encoded)?.kind, .startLeft, "An empty id still decodes")

        await FeedButtonAction(.startLeft, timerLocalID: "").perform(in: context)
        await FeedButtonAction(.startRight, timerLocalID: "").perform(in: context)

        XCTAssertEqual(try feedings().map { $0.payloadObject["method"] as? String }, ["left breast"])
        XCTAssertEqual(try runningTimers().map(\.feedSide), [.right])
    }
}
