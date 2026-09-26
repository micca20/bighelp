import SwiftUI

struct BotModeObservedToolView: View {
    let row: BotModeObservedTool
    let memberName: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            Button(action: onToggle) {
                HStack(spacing: LoopdyTokens.space8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(memberName) · \(row.observation.tool.name)")
                            .font(.subheadline.weight(.semibold))
                        Text(row.observation.kind == .started ? "Started · live observation" : "Finished · outcome not reported")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: LoopdyTokens.space8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .accessibilityHidden(true)
                }
                .frame(minHeight: LoopdyTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            if isExpanded {
                detail(row.observation.arguments, title: "Arguments")
                detail(row.observation.result, title: "Result")
            }
        }
        .padding(.horizontal, LoopdyTokens.space16)
        .accessibilityIdentifier("bot-mode.observed-tool")
    }

    @ViewBuilder
    private func detail(_ detail: HermesBotModeActivityDetail, title: String) -> some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
            Text(title).font(.caption.weight(.semibold))
            if let text = detail.text, detail.state == .available {
                ChatToolDetailText(label: title, value: text, identifier: "\(row.id).\(title)")
            } else {
                Text(omissionMessage(detail.state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func omissionMessage(_ state: HermesBotModeActivityDetail.State) -> String {
        switch state {
        case .available, .unavailable: "Not provided by the host."
        case .omittedSize: "Omitted by the host because of its size."
        case .omittedSensitive: "Omitted by the host's sensitive-content check."
        }
    }
}
