import AppIntents

/// Siri phrases and Shortcuts app actions, ready the moment the app is installed: log a diaper,
/// start a timer, finish a feed on a side. The intents are the ones the widget buttons run, so
/// "Hey Siri, log a wet diaper in Baby Buddy" logs exactly what a Quick Log tap would.
///
/// App target only: an app declares one provider, and the widget extension must not. Xcode reads
/// these at build time, so the symbol names are literals (the same ones ``EntityKind`` uses).
struct BabyBuddyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickLogIntent(),
            phrases: [
                "Log a \(\.$action) diaper in \(.applicationName)",
                "Log \(\.$action) in \(.applicationName)",
                "Log a diaper in \(.applicationName)",
            ],
            shortTitle: "Log diaper",
            systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: [
                "Start a \(\.$activity) timer in \(.applicationName)",
                "Start \(\.$activity) in \(.applicationName)",
                "Start a timer in \(.applicationName)",
            ],
            shortTitle: "Start timer",
            systemImageName: "stopwatch")
        AppShortcut(
            intent: FinishFeedingIntent(),
            phrases: [
                "Finish feeding on the \(\.$side) in \(.applicationName)",
                "Finish feeding on \(\.$side) in \(.applicationName)",
                "Finish feeding in \(.applicationName)",
            ],
            shortTitle: "Finish feed",
            systemImageName: "drop.fill")
    }
}
