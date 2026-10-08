import SwiftUI
import SwiftData
import BackgroundTasks
import WidgetKit
import UserNotifications

@main
struct BabyBuddyApp: App {
    @State private var session: AppSession
    @State private var sync: SyncEngine
    @State private var purchases: PurchaseManager
    @State private var lock = AppLockManager()
    @State private var router: DeepLinkRouter
    @State private var liveActivity: LiveActivityManager
    @State private var icons = AppIconManager()
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer
    private let timerAlerts: TimerAlertDelegate

    private static let refreshTaskID = "com.kurtisguy.BabyBuddy.sync"

    /// Whether this process is running the unit-test suite rather than serving a customer.
    ///
    /// `BabyBuddyTests` is hosted *in* the app (`TEST_HOST`), so this initializer runs before the
    /// tests do. Left unguarded, a plain `xcodebuild test` stamps a first launch and counts every
    /// record the persistence tests create into the real support-nudge counters — leaving any
    /// simulator that has run the suite with a pre-aged, pre-counted install that can't be used to
    /// check the day-7 / 10-entry gate by hand. ``PurchaseManagerTests`` guards its own defaults the
    /// same way, by save-and-restore; automatic wiring has no test to do that from.
    ///
    /// XCTest is never loaded into a release build, so this is always `false` in the shipped app.
    private static var isHostingTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    init() {
        let container = LocalStore.makeContainer()
        #if DEBUG
        // `BB_UITEST`: wipe to a clean install before anything below reads defaults or the store.
        DemoData.resetForUITests(container.mainContext)
        #endif
        Analytics.start()
        if !Self.isHostingTests {
            // Stamped before any Dashboard can ask whether a support nudge is due — every time-based
            // rule in the policy hangs off it.
            SupportNudgeStore.shared.registerFirstLaunch()
            // Count records logged in the app, which is the nudge policy's usage gate. See the hook's
            // documentation for why `LocalRepository` doesn't reach for the store directly.
            LocalRepository.didLogActivity = { entity in
                SupportNudgeStore.shared.recordLoggedEntry()
                if UndoToastCenter.isEnabled { UndoToastCenter.shared.show(entity) }
            }
        }
        let router = DeepLinkRouter()
        _router = State(initialValue: router)
        let liveActivity = LiveActivityManager()
        _liveActivity = State(initialValue: liveActivity)
        // The feed intents run in this process (they're `LiveActivityIntent`s), so they can bring
        // the banner up for the side they just started.
        FeedFinisher.reconcileLiveActivity = { await liveActivity.reconcile() }
        timerAlerts = TimerAlertDelegate(router: router)
        UNUserNotificationCenter.current().delegate = timerAlerts
        let session = AppSession(context: container.mainContext)
        let purchases = PurchaseManager()
        purchases.start()
        self.container = container
        _session = State(initialValue: session)
        _sync = State(initialValue: SyncEngine(session: session, context: container.mainContext))
        _purchases = State(initialValue: purchases)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(sync)
                .environment(purchases)
                .environment(lock)
                .environment(router)
                .environment(liveActivity)
                .environment(icons)
                .modelContainer(container)
                .onOpenURL { router.handle($0) }
                // The feed's hour-long backup: close a forgotten side the moment it's due while
                // the app is up. Foreground and background refresh run it too, below.
                .task { await closeFeedsWhenDue() }
                // Signing out clears the cache the banner is drawn from — reconcile so a timer's
                // Live Activity doesn't outlive the data behind it.
                .onChange(of: session.isAuthenticated) { _, _ in
                    Task { await liveActivity.reconcile() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                lock.willEnterForeground()
                closeDueFeeds()
                if session.isAuthenticated && !lock.isLocked { Task { await sync.sync() } }
                // Sync the Live Activity to the current running timer — covers timers started or
                // stopped from the widget/Siri, whose extension-process intents can't touch it.
                Task { await liveActivity.reconcile() }
            case .background:
                lock.didEnterBackground()
                scheduleBackgroundSync()
                WidgetCenter.shared.reloadAllTimelines() // reflect in-app timer changes on the widgets
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await MainActor.run { _ = LocalRepository(context: container.mainContext).autoCloseFeeds() }
            await sync.sync()
            await MainActor.run { scheduleBackgroundSync() }
        }
    }

    /// Log every feed past its hour (``LocalRepository/autoCloseFeeds(now:)``), then sync it and
    /// drop its banner.
    private func closeDueFeeds() {
        guard !LocalRepository(context: container.mainContext).autoCloseFeeds().isEmpty else { return }
        Task { await sync.sync() }
        Task { await liveActivity.reconcile() }
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Closes feeds as they come due for as long as the app runs: sleeps until the next running
    /// feed's hour is up (checking at least every 30 seconds, for a feed started elsewhere).
    private func closeFeedsWhenDue() async {
        while !Task.isCancelled {
            closeDueFeeds()
            let next = LocalRepository.nextFeedAutoClose(in: container.mainContext)?.timeIntervalSinceNow ?? 30
            try? await Task.sleep(for: .seconds(min(max(next, 1), 30)))
        }
    }

    private func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
