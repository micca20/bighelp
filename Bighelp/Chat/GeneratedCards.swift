import SwiftUI

struct BudgetAndPlanView: View {
    let summary: BudgetSummary

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            BighelpCard {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    Label("Budget summary", systemImage: "chart.pie.fill")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space20) {
                            budgetMetric(title: "Spent", value: summary.spent)
                            budgetMetric(title: "Budget", value: summary.budget)
                        }
                        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                            budgetMetric(title: "Spent", value: summary.spent)
                            budgetMetric(title: "Budget", value: summary.budget)
                        }
                    }

                    ProgressView(value: Double(summary.percentUsed), total: 100)
                        .tint(theme.action)
                        .accessibilityLabel("Budget used")
                        .accessibilityValue("\(summary.percentUsed) percent")

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(summary.remaining)
                            Spacer(minLength: BighelpTokens.space12)
                            Text(summary.period)
                        }
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(summary.remaining)
                            Text(summary.period)
                        }
                    }
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                }
            }

            BighelpCard {
                VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                    Label("Today’s Plan", systemImage: "list.bullet.clipboard.fill")
                        .bighelpFont(.sectionTitle)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(Array(summary.plan.enumerated()), id: \.element.id) { index, item in
                        planRow(item)
                        if index < summary.plan.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func budgetMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(title)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .bighelpFont(.screenTitle)
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func planRow(_ item: PlanItem) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: BighelpTokens.space12) {
                planText(item)
                Spacer(minLength: BighelpTokens.space12)
                Text(item.time)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                planText(item)
                Text(item.time)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func planText(_ item: PlanItem) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text(item.title)
                .bighelpFont(.label)
                .foregroundStyle(theme.primaryText)
            Text(item.detail)
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
        }
    }

    @BighelpThemeReader private var theme

}

struct WeatherAndTasksView: View {
    let content: WeatherAndTasks

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            weatherCard
            tasksCard
        }
    }

    private var weatherCard: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: BighelpTokens.space16) {
                        weatherSummary
                        Spacer(minLength: BighelpTokens.space12)
                        temperatureSummary
                    }
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        weatherSummary
                        temperatureSummary
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: BighelpTokens.space12) {
                        ForEach(content.hourly) { hour in
                            VStack(spacing: BighelpTokens.space8) {
                                Text(hour.time)
                                Image(systemName: hour.systemImage)
                                    .foregroundStyle(theme.warning)
                                    .accessibilityHidden(true)
                                Text("\(hour.temperature)°")
                                    .monospacedDigit()
                            }
                            .bighelpFont(.metadata, weight: .semibold)
                            .foregroundStyle(theme.primaryText)
                            .frame(minWidth: 64, minHeight: 88)
                            .background(theme.raisedSurface, in: .rect(cornerRadius: BighelpTokens.radius12))
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(hour.time), \(hour.condition), \(hour.temperature) degrees")
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("card.weather")
    }

    private var weatherSummary: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Label(content.city, systemImage: "location.fill")
                .bighelpFont(.sectionTitle)
                .foregroundStyle(theme.primaryText)
            Text(content.condition)
                .bighelpFont(.body)
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var temperatureSummary: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            Text("\(content.currentTemperature)°")
                .bighelpFont(.display)
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
            Text("High \(content.highTemperature)° · Low \(content.lowTemperature)°")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var tasksCard: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                Label("Priority tasks", systemImage: "checklist")
                    .bighelpFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)

                ForEach(Array(content.tasks.enumerated()), id: \.element.id) { index, task in
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        Image(systemName: index == 0 ? "exclamationmark.circle.fill" : "circle.fill")
                            .font(.system(size: index == 0 ? 18 : 8, weight: .semibold))
                            .foregroundStyle(index == 0 ? theme.warning : theme.tertiaryText)
                            .frame(width: 20, height: 20)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                            Text(task.priority)
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(index == 0 ? theme.warning : theme.secondaryText)
                            Text(task.title)
                                .bighelpFont(.label)
                                .foregroundStyle(theme.primaryText)
                            Text(task.detail)
                                .bighelpFont(.body)
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if index < content.tasks.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .accessibilityIdentifier("card.tasks")
    }

    @BighelpThemeReader private var theme

}

struct ApprovalRequestPreview: View {
    let request: ApprovalRequest
    let onOpen: (ApprovalRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            Label("Needs your approval", systemImage: "exclamationmark.triangle.fill")
                .bighelpFont(.sectionTitle)
                .foregroundStyle(theme.warning)
                .accessibilityAddTraits(.isHeader)

            Text(request.action)
                .bighelpFont(.screenTitle)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                fact("Requester", request.requester)
                fact("Vendor", request.vendor)
                fact("Amount", request.amount)
                fact("Due date", request.dueDate)
                fact("Category", request.category)
                fact("Source invoice", request.sourceInvoice)
            }

            Divider()

            Text(request.consequence)
                .bighelpFont(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Review approval") {
                onOpen(request)
            }
            .bighelpProminentButtonStyle()
            .tint(theme.action)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            .accessibilityHint("Opens the authorized approval choices. No decision is made by opening details.")

            Text("Reviewing this request does not submit a decision.")
                .bighelpFont(.metadata)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(BighelpTokens.space16)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius16))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius16)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer(minLength: BighelpTokens.space12)
                Text(value)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(label)
                    .foregroundStyle(.secondary)
                Text(value)
                    .foregroundStyle(.primary)
            }
        }
        .bighelpFont(.body)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme

}
