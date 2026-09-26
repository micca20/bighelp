import SwiftUI

struct QuickActionsView: View {
    let model: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space8) {
            ForEach(QuickAction.allCases) { action in
                quickActionButton(action, fillsWidth: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quickActionButton(_ action: QuickAction, fillsWidth: Bool) -> some View {
        Button {
            Task { await model.perform(action) }
        } label: {
            // UIHostingConfiguration can resolve Label's automatic style as
            // icon-only and then measure the title at zero width. Keep the
            // compact prompt's two visual parts explicit so native row sizing
            // has a finite intrinsic width and height.
            HStack(spacing: LoopdyTokens.space8) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(action.title)
                    .loopdyFont(.label)
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                    // Keep the compact pill bounded on large Dynamic Type and
                    // allow longer/localized titles to wrap instead of
                    // forcing their intrinsic width beyond the viewport.
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
                .padding(.horizontal, LoopdyTokens.space12)
                .frame(
                    minWidth: fillsWidth ? nil : 120,
                    maxWidth: fillsWidth ? .infinity : 320,
                    minHeight: LoopdyTokens.hitTarget,
                    alignment: .leading
                )
                .background(theme.raisedSurface, in: .capsule)
                .overlay {
                    Capsule()
                        .stroke(theme.border, lineWidth: LoopdyTokens.hairline)
                }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .disabled(!model.canPerformQuickAction)
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }

    @LoopdyThemeReader private var theme: LoopdyTheme

}
