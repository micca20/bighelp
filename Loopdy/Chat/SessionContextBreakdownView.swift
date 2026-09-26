import SwiftUI

struct SessionContextBreakdownView: View {
    let breakdown: DirectHermesContextBreakdown

    var body: some View {
        Form {
            Section {
                summary
            } header: {
                Text("Usage")
            }

            Section {
                categoryGrid
            } header: {
                Text("Categories")
            }

            if breakdown.estimatedTotal != breakdown.contextUsed || !breakdown.contextSource.isEmpty {
                Section {
                    sourceNote
                } header: {
                    Text("Source")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Context")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("chat.session-context-breakdown")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
                    Text(breakdown.model.isEmpty ? "Current model" : breakdown.model)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(breakdown.contextEstimated ? "Estimated context use" : "Context use")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: LoopdyTokens.space12)
                Text("\(clampedPercent)%")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }

            ProgressView(value: progressValue, total: progressTotal)
                .tint(.accentColor)
                .accessibilityLabel("Context used")
                .accessibilityValue(contextAccessibilityValue)

            Text("\(breakdown.contextUsed.formatted()) of \(breakdown.contextMax.formatted()) tokens")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(contextAccessibilityValue)
    }

    private var categoryGrid: some View {
        ForEach(Array(breakdown.categories.enumerated()), id: \.offset) { index, category in
            LabeledContent {
                Text(category.tokens.formatted())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } label: {
                Label {
                    Text(category.label.isEmpty ? category.id : category.label)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Circle()
                        .fill(categoryColor(index))
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(category.label.isEmpty ? category.id : category.label)
            .accessibilityValue("\(category.tokens.formatted()) tokens")
            .accessibilityIdentifier("chat.session-context-category.\(category.id)")
        }
    }

    private var sourceNote: some View {
        VStack(alignment: .leading, spacing: LoopdyTokens.space4) {
            if breakdown.estimatedTotal != breakdown.contextUsed {
                Text("Estimated total: \(breakdown.estimatedTotal.formatted()) tokens")
                    .monospacedDigit()
            }
            if !breakdown.contextSource.isEmpty {
                Text("Source: \(breakdown.contextSource)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private var clampedPercent: Int {
        min(100, max(0, breakdown.contextPercent))
    }

    private var progressValue: Double {
        min(progressTotal, max(0, Double(breakdown.contextUsed)))
    }

    private var progressTotal: Double {
        max(1, Double(breakdown.contextMax))
    }

    private var contextAccessibilityValue: String {
        let estimate = breakdown.contextEstimated ? "Estimated. " : ""
        return "\(estimate)\(clampedPercent) percent, \(breakdown.contextUsed.formatted()) of \(breakdown.contextMax.formatted()) tokens"
    }

    private func categoryColor(_ index: Int) -> Color {
        let colors: [Color] = [.accentColor, .blue, .indigo, .purple, .teal, .orange, .pink]
        return colors[index % colors.count]
    }
}
