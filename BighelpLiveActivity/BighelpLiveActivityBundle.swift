import SwiftUI
import WidgetKit

@main
struct BighelpLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        BighelpSessionLiveActivity()
        BighelpAgentWidget()
        BighelpActiveSessionsWidget()
        BighelpScheduledTasksWidget()
        BighelpNewChatWidget()
        BighelpActivityFeedWidget()
    }
}
