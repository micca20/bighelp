import SwiftUI

/// The exact command Hermes paused, with room-task-scoped decisions only.
struct BotModeApprovalCard: View {
    let approvalID: String
    let agentName: String
    let command: String?
    let detail: String?
    let allowsOnce: Bool
    let allowsDeny: Bool
    let isSubmitting: Bool
    let errorMessage: String?
    let onAllowOnce: () -> Void
    let onDeny: () -> Void


    var body: some View {
        LoopdyCard {
            VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
                Label("Needs your approval", systemImage: "exclamationmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(agentName) asked Hermes to run this action.")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryText)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let command {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(LoopdyTokens.space12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.raisedSurface, in: .rect(cornerRadius: 12))
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(theme.danger)
                        .accessibilityIdentifier("chat.bot-approval.error.\(approvalID)")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: LoopdyTokens.space12) { decisions }
                    VStack(alignment: .leading, spacing: LoopdyTokens.space12) { decisions }
                }
                .disabled(isSubmitting)
                if isSubmitting {
                    ProgressView("Sending decision")
                }
            }
        }
        .accessibilityIdentifier("chat.bot-approval.\(approvalID)")
    }

    private var decisions: some View {
        Group {
            if allowsOnce {
                Button("Allow Once", action: onAllowOnce)
                    .loopdyProminentButtonStyle()
                    .frame(minHeight: LoopdyTokens.hitTarget)
                    .accessibilityIdentifier("chat.bot-approval.allow.\(approvalID)")
            }
            if allowsDeny {
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered)
                    .frame(minHeight: LoopdyTokens.hitTarget)
                    .accessibilityIdentifier("chat.bot-approval.deny.\(approvalID)")
            }
        }
    }

    @LoopdyThemeReader private var theme
}
