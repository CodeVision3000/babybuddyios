import WidgetKit
import SwiftUI

/// Widget extension entry point.
@main
struct BabyBuddyWidgets: WidgetBundle {
    var body: some Widget {
        QuickStartWidget()
        QuickLogWidget()
        ActiveTimerWidget()
        StatusWidget()
        RunningTimerLiveActivity()
        // The deployment target is iOS 17; controls arrived in 18.
        if #available(iOS 18.0, *) {
            DiaperControl()
            StartFeedControl()
            FinishFeedControl()
        }
    }
}
