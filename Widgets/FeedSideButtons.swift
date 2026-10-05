import AppIntents
import SwiftUI
import WidgetKit

/// Left / Right / Both for a running feed that wasn't started on a side: each tap logs it on that
/// side via ``FinishFeedTimerIntent``, no app launch. The feed's Stop control on the Active Timer
/// widget, the Live Activity and the Quick Start Lock Screen widget, so all of them finish a feed
/// the same way.
///
/// `compact` is for the Lock Screen and the Dynamic Island: one-letter labels and the system's
/// accessory styling, which tints them to fit the wallpaper. Otherwise the buttons take the
/// stop color, like the Stop button they replace.
struct FeedSideButtons: View {
    let timerLocalID: String
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            ForEach(FeedSide.allCases, id: \.self) { side in
                Button(intent: FinishFeedTimerIntent(timerLocalID: timerLocalID, side: side)) {
                    FeedButtonLabel(text: compact ? side.shortTitle : side.title, compact: compact)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish feeding on \(side.title.lowercased())")
            }
        }
    }
}

/// "Switch to Right" and "Done" for a feed timed on a side: sides come in pairs, so the next tap is
/// usually the other side, which logs this one (``SwitchFeedSideIntent``); Done logs this side and
/// ends the feed (``FinishFeedTimerIntent``). Same places and styling as ``FeedSideButtons``.
struct FeedPairButtons: View {
    let timerLocalID: String
    let side: FeedSide
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Button(intent: SwitchFeedSideIntent(timerLocalID: timerLocalID)) {
                FeedButtonLabel(text: compact ? "→ \(side.other.shortTitle)" : "Switch to \(side.other.title)",
                                compact: compact)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch to \(side.other.title.lowercased()) side")
            Button(intent: FinishFeedTimerIntent(timerLocalID: timerLocalID)) {
                FeedButtonLabel(text: "Done", compact: compact)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done feeding")
        }
    }
}

/// The feed buttons for a running feed: Switch / Done on a side, Left / Right / Both without one.
struct FeedButtons: View {
    let timerLocalID: String
    let side: FeedSide?
    var compact = false

    var body: some View {
        if let side {
            FeedPairButtons(timerLocalID: timerLocalID, side: side, compact: compact)
        } else {
            FeedSideButtons(timerLocalID: timerLocalID, compact: compact)
        }
    }
}

private struct FeedButtonLabel: View {
    let text: String
    let compact: Bool

    var body: some View {
        if compact {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        } else {
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(BBColor.stop, in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(Color(red: 0x5A / 255.0, green: 0x43 / 255.0, blue: 0x02 / 255.0))
        }
    }
}

/// The running time of a timer. A feed timed on a side stops counting at ``FeedSide/autoCloseAfter``,
/// when it closes itself, so a banner nobody has refreshed since reads the hour it was logged as rather
/// than ticking on.
struct TimerElapsedText: View {
    let start: Date
    let isFeed: Bool

    var body: some View {
        if isFeed {
            Text(timerInterval: start...start.addingTimeInterval(FeedSide.autoCloseAfter), countsDown: false)
        } else {
            Text(start, style: .timer)
        }
    }
}

/// "Last: Left", so the next feed can start on the other side. Nothing until a side has been logged.
struct LastFeedSideText: View {
    var body: some View {
        if let last = SharedDefaults.lastFeedSide {
            Text("Last: \(last.title)")
        }
    }
}
