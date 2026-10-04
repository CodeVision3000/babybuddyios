import WidgetKit
import SwiftUI
import AppIntents

/// Home-screen widget: a 2×2 grid of activity tiles that each start a Baby Buddy timer with
/// one tap, via ``StartTimerIntent``. Static content — it looks the same whether or not a
/// timer is running, so it's always useful.
///
/// The Lock Screen rectangle is the exception: Feed / Sleep / Tummy, and while a feed runs, its
/// Left / Right / Both instead, so one Lock Screen widget starts a feed and finishes it.
struct QuickStartWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BabyBuddyQuickStart", provider: QuickStartProvider()) { entry in
            QuickStartView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Quick start timer")
        .description("Start a feeding, sleep, tummy time, or pumping timer.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct QuickStartEntry: TimelineEntry {
    let date: Date
    /// The running feed, for the Lock Screen's side buttons. `nil` when no feed is running.
    var feed: TimerSnapshot? = nil
}

struct QuickStartProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickStartEntry { QuickStartEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (QuickStartEntry) -> Void) {
        completion(entry(for: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickStartEntry>) -> Void) {
        // Timer starts and stops reload every widget, so no periodic reloads are needed.
        completion(Timeline(entries: [entry(for: context.family)], policy: .never))
    }

    /// Only the Lock Screen size shows the running feed, so only it reads the store.
    private func entry(for family: WidgetFamily) -> QuickStartEntry {
        guard family == .accessoryRectangular,
              let timer = ActiveTimerProvider.currentTimer(activity: .feeding)
        else { return QuickStartEntry(date: .now) }
        return QuickStartEntry(date: .now, feed: timer)
    }
}

struct QuickStartView: View {
    @Environment(\.widgetFamily) private var family
    let entry: QuickStartEntry

    var body: some View {
        if family == .accessoryRectangular { accessory } else { grid }
    }

    // MARK: Lock Screen

    @ViewBuilder private var accessory: some View {
        if let feed = entry.feed {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: TimerActivity.feeding.systemImage)
                    Text(feed.start, style: .timer).monospacedDigit()
                    LastFeedSideText()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.headline)
                .widgetAccentable()
                FeedSideButtons(timerLocalID: feed.localID, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Label("Start", systemImage: "stopwatch")
                    LastFeedSideText()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.headline)
                .widgetAccentable()
                HStack(spacing: 4) {
                    ForEach([TimerActivity.feeding, .sleep, .tummyTime], id: \.self) { activity in
                        Button(intent: StartTimerIntent(activity: activity)) {
                            Image(systemName: activity.systemImage)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Start \(activity.timerName.lowercased()) timer")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Home Screen

    private var grid: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                Text("Start a timer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "stopwatch")
                    .font(.system(size: 12))
                    .foregroundStyle(BBColor.brand)
            }
            Grid(horizontalSpacing: 7, verticalSpacing: 7) {
                GridRow { tile(.feeding); tile(.sleep) }
                GridRow { tile(.tummyTime); tile(.pumping) }
            }
        }
    }

    private func tile(_ activity: TimerActivity) -> some View {
        let tint = BBColor.tint(for: activity)
        return Button(intent: StartTimerIntent(activity: activity)) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: activity.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 2)
                Text(activity.timerName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
