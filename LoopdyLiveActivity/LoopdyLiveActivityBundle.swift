import SwiftUI
import WidgetKit

@main
struct LoopdyLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LoopdySessionLiveActivity()
        LoopdyAgentWidget()
        LoopdyActiveSessionsWidget()
        LoopdyScheduledTasksWidget()
        LoopdyNewChatWidget()
        LoopdyActivityFeedWidget()
    }
}
