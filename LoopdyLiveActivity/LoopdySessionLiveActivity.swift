import ActivityKit
import SwiftUI
import WidgetKit

struct LoopdySessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoopdySessionActivityAttributes.self) { context in
            LoopdyLiveActivityCard(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
            .activitySystemActionForegroundColor(.primary)
            .widgetURL(context.attributes.deepLink)
        } dynamicIsland: { context in
            let presentation = LoopdyActivityPresentation(
                attributes: context.attributes,
                state: context.state,
                isStale: context.isStale
            )
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LoopdyActivityAvatar(agentID: context.attributes.agentID,
                                         name: presentation.agentName, diameter: 44)
                        .overlay(alignment: .bottomTrailing) { islandBadge(presentation, size: 18) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.agentName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(presentation.status)
                            .font(.headline)
                            .foregroundStyle(presentation.pose.tint)
                            .contentTransition(.opacity)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation.accessibilityLabel)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: presentation.symbolName)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(presentation.pose.tint)
                        .contentTransition(.symbolEffect(.replace))
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let detail = presentation.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(2)
                            .accessibilityHidden(true)
                    }
                }
            } compactLeading: {
                LoopdyActivityAvatar(agentID: context.attributes.agentID,
                                     name: presentation.agentName, diameter: 24)
                    .accessibilityHidden(false)
                    .accessibilityLabel(presentation.agentName)
            } compactTrailing: {
                Image(systemName: presentation.symbolName)
                    .foregroundStyle(presentation.pose.tint)
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityLabel(presentation.status)
            } minimal: {
                LoopdyActivityAvatar(agentID: context.attributes.agentID,
                                     name: presentation.agentName, diameter: 22)
                    .overlay(alignment: .bottomTrailing) { islandBadge(presentation, size: 11) }
                    .accessibilityLabel(presentation.accessibilityLabel)
            }
            .keylineTint(.secondary)
            .widgetURL(context.attributes.deepLink)
        }
    }

    /// The kind of work on the avatar's corner: code, globe, paintbrush…
    private func islandBadge(_ presentation: LoopdyActivityPresentation, size: CGFloat) -> some View {
        Image(systemName: presentation.symbolName)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Circle().fill(presentation.pose.tint))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }
}
