import AppIntents
import SwiftUI
import WidgetKit

/// Left / Right / Both for a running feed: each tap logs it on that side via
/// ``FinishFeedTimerIntent``, no app launch. The feed's Stop control on the Active Timer widget, the
/// Live Activity and the Quick Start Lock Screen widget, so all of them finish a feed the same way.
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
                Button(intent: FinishFeedTimerIntent(side: side, timerLocalID: timerLocalID)) {
                    label(side)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Finish feeding on \(side.title.lowercased())")
            }
        }
    }

    @ViewBuilder private func label(_ side: FeedSide) -> some View {
        if compact {
            Text(side.shortTitle)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        } else {
            Text(side.title)
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

/// "Last: Left", so the next feed can start on the other side. Nothing until a side has been logged.
struct LastFeedSideText: View {
    var body: some View {
        if let last = SharedDefaults.lastFeedSide {
            Text("Last: \(last.title)")
        }
    }
}
