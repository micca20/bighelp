import SwiftUI

struct GenerativeUICardView: View {
    let card: GenerativeUICard
    let messageID: String

    init(card: GenerativeUICard, messageID: String = "") {
        self.card = card
        self.messageID = messageID
    }

    var body: some View {
        BighelpCard {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                header
                content
                if let provenance = card.provenance {
                    provenanceView(provenance)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityIdentifier("chat.generative-ui.\(card.component.rawValue)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            Image(systemName: componentSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(width: 38, height: 38)
                .background(theme.action.opacity(0.11), in: .rect(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .bighelpFont(.sectionTitle)
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = card.subtitle {
                    Text(subtitle)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: 0)
            Text(cardBadge)
                .bighelpFont(.metadata, weight: .bold)
                .foregroundStyle(theme.action)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.action.opacity(0.09), in: .capsule)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch card.component {
        case .summary:
            Text(card.document["body"]?.string ?? "")
                .bighelpFont(.body)
                .foregroundStyle(theme.primaryText)
        case .metrics:
            metricGrid(card.document["metrics"]?.object ?? [:])
        case .list:
            simpleRows(card.document["items"]?.array ?? [], numbered: false)
        case .timeline:
            simpleRows(card.document["steps"]?.array ?? [], numbered: true)
        case .weatherForecast:
            weather
        case .sportsGame:
            sports
        case .stockQuote:
            stock
        case .chart:
            GenerativeUIChartView(data: card.data)
        case .dashboard:
            dashboard
        case .form:
            GenerativeUIFormPreview(card: card)
        case .checklist:
            GenerativeUIChecklistView(card: card, messageID: messageID)
        case .selection:
            GenerativeUISelectionView(card: card, messageID: messageID)
        case .automation:
            GenerativeUIAutomationView(card: card)
        }
    }

    private func metricGrid(_ metrics: [String: BighelpJSONValue]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
            ForEach(metrics.keys.sorted(), id: \.self) { key in
                metricTile(
                    label: key.replacingOccurrences(of: "_", with: " ").capitalized,
                    value: metrics[key]?.displayText ?? "—",
                    status: nil
                )
            }
        }
    }

    private func simpleRows(_ rows: [BighelpJSONValue], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, value in
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(numbered ? "\(index + 1)" : "•")
                        .bighelpFont(.metadata, weight: .bold)
                        .foregroundStyle(theme.action)
                        .frame(minWidth: 18)
                    Text(rowText(value))
                        .bighelpFont(.body)
                        .foregroundStyle(theme.primaryText)
                }
            }
        }
    }

    private var weather: some View {
        let current = card.data["current"]?.object ?? [:]
        let unit = card.data["units"]?.string == "metric" ? "C" : "F"
        return VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            HStack(spacing: BighelpTokens.space16) {
                Image(systemName: weatherSymbol(current["condition_code"]?.string))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 44))
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.data["location"]?.string ?? "")
                        .bighelpFont(.metadata, weight: .semibold)
                        .foregroundStyle(theme.secondaryText)
                    Text(temperature(current["temperature"]?.number, unit: unit))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.primaryText)
                    Text(current["condition_label"]?.string ?? "")
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if let humidity = current["humidity_percent"]?.integer {
                        Label("\(humidity)%", systemImage: "humidity")
                    }
                    if let wind = current["wind_speed"]?.number {
                        Label("\(wind.formatted(.number.precision(.fractionLength(0...1))))", systemImage: "wind")
                    }
                }
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
            }
            if let periods = card.data["periods"]?.array {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(periods.enumerated()), id: \.offset) { _, value in
                            if let period = value.object {
                                VStack(spacing: 5) {
                                    Text(period["label"]?.string ?? "")
                                        .bighelpFont(.metadata, weight: .semibold)
                                    Image(systemName: weatherSymbol(period["condition_code"]?.string))
                                        .symbolRenderingMode(.multicolor)
                                    Text(periodTemperature(period, unit: unit))
                                        .bighelpFont(.label)
                                        .monospacedDigit()
                                }
                                .foregroundStyle(theme.primaryText)
                                .padding(10)
                                .frame(minWidth: 88)
                                .background(theme.raisedSurface, in: .rect(cornerRadius: 12))
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var sports: some View {
        let status = card.data["status"]?.string ?? "scheduled"
        let teams = card.data["teams"]?.array ?? []
        return VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack {
                Text((card.data["league_label"]?.string ?? card.data["league"]?.string ?? "").uppercased())
                    .bighelpFont(.metadata, weight: .bold)
                Spacer()
                Text(status.replacingOccurrences(of: "_", with: " ").uppercased())
                    .bighelpFont(.metadata, weight: .bold)
                    .foregroundStyle(status == "live" ? theme.danger : theme.secondaryText)
            }
            ForEach(Array(teams.enumerated()), id: \.offset) { _, value in
                if let team = value.object {
                    HStack(spacing: BighelpTokens.space12) {
                        Text(team["abbreviation"]?.string ?? "")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                            .frame(width: 48, height: 38)
                            .background(theme.action.opacity(0.10), in: .rect(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(team["name"]?.string ?? "")
                                .bighelpFont(.label)
                            if let record = team["record"]?.string {
                                Text(record).bighelpFont(.metadata)
                            }
                        }
                        Spacer()
                        Text(team["score"]?.displayText ?? "—")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(theme.primaryText)
                }
            }
            if let period = card.data["period_label"]?.string {
                Text([period, card.data["clock"]?.string].compactMap { $0 }.joined(separator: " · "))
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var stock: some View {
        let change = card.data["change"]?.number ?? 0
        let percent = card.data["change_percent"]?.number ?? 0
        let currency = card.data["currency"]?.string ?? ""
        return VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.data["symbol"]?.string ?? "")
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Text(card.data["company_name"]?.string ?? "")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(stockPrice(card.data["price"]?.number, currency: currency))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("\(signed(change))  \(signed(percent))%")
                        .bighelpFont(.metadata, weight: .bold)
                        .foregroundStyle(change >= 0 ? theme.success : theme.danger)
                }
            }
            Divider()
            HStack {
                stockFact("Open", card.data["session_open"]?.number)
                Spacer()
                stockFact("Low", card.data["day_low"]?.number)
                Spacer()
                stockFact("High", card.data["day_high"]?.number)
            }
        }
        .foregroundStyle(theme.primaryText)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            if let description = card.data["description"]?.string {
                Text(description)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            let metrics = card.data["metrics"]?.array ?? []
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, value in
                    if let metric = value.object {
                        metricTile(
                            label: metric["label"]?.string ?? "",
                            value: metric["value_text"]?.string ?? "—",
                            status: metric["status_label"]?.string
                        )
                    }
                }
            }
            ForEach(Array((card.data["charts"]?.array ?? []).enumerated()), id: \.offset) { _, value in
                if let chart = value.object {
                    GenerativeUIChartView(data: chart)
                }
            }
        }
    }

    private func metricTile(label: String, value: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
            if let status {
                Text(status)
                    .bighelpFont(.metadata, weight: .semibold)
                    .foregroundStyle(theme.success)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BighelpTokens.space12)
        .background(theme.raisedSurface, in: .rect(cornerRadius: 12))
    }

    private func provenanceView(_ value: [String: BighelpJSONValue]) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.seal")
            Text(value["source_name"]?.string ?? "Verified source")
            if let cache = value["cache_status"]?.string {
                Text("· \(cache.capitalized)")
            }
        }
        .bighelpFont(.metadata)
        .foregroundStyle(theme.tertiaryText)
    }

    private func rowText(_ value: BighelpJSONValue) -> String {
        if let text = value.displayText { return text }
        if let object = value.object {
            for key in ["title", "label", "body", "text", "name", "value"] {
                if let text = object[key]?.displayText { return text }
            }
            return object.keys.sorted().compactMap { object[$0]?.displayText }.joined(separator: " · ")
        }
        return ""
    }

    private func temperature(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(0))))°\(unit)"
    }

    private func periodTemperature(_ period: [String: BighelpJSONValue], unit: String) -> String {
        let high = period["high"]?.number.map { temperature($0, unit: unit) }
        let low = period["low"]?.number.map { temperature($0, unit: unit) }
        return [high, low].compactMap { $0 }.joined(separator: " / ")
    }

    private func weatherSymbol(_ code: String?) -> String {
        switch code {
        case "clear": "sun.max.fill"
        case "partly_cloudy": "cloud.sun.fill"
        case "cloudy": "cloud.fill"
        case "rain": "cloud.rain.fill"
        case "snow": "cloud.snow.fill"
        case "sleet": "cloud.sleet.fill"
        case "storm": "cloud.bolt.rain.fill"
        case "fog", "smoke": "cloud.fog.fill"
        case "wind": "wind"
        default: "cloud.fill"
        }
    }

    private func stockPrice(_ value: Double?, currency: String) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number.precision(.fractionLength(2)))) \(currency)"
    }

    private func signed(_ value: Double) -> String {
        let prefix = value > 0 ? "+" : ""
        return prefix + value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func stockFact(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            Text(value?.formatted(.number.precision(.fractionLength(2))) ?? "—")
                .bighelpFont(.label).monospacedDigit()
        }
    }

    private var componentSymbol: String {
        switch card.component {
        case .summary: "sparkles"
        case .metrics: "square.grid.2x2"
        case .list: "list.bullet"
        case .timeline: "point.topleft.down.to.point.bottomright.curvepath"
        case .weatherForecast: "cloud.sun.fill"
        case .sportsGame: "sportscourt.fill"
        case .stockQuote: "chart.line.uptrend.xyaxis"
        case .chart: "chart.xyaxis.line"
        case .dashboard: "rectangle.3.group.fill"
        case .form: "checklist"
        case .checklist: "checklist"
        case .selection: "checkmark.circle"
        case .automation: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        }
    }

    private var cardBadge: String {
        switch card.component {
        case .checklist, .selection: "LOCAL"
        case .automation: "SNAPSHOT"
        default: "LIVE"
        }
    }

    @BighelpThemeReader private var theme

}

private struct GenerativeUIChecklistView: View {
    let card: GenerativeUICard
    let messageID: String
    @State private var completed: [String: Bool] = [:]
    @Environment(\.chatCardInteractions) private var interactions

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            if let description = card.data["description"]?.string {
                Text(description).bighelpFont(.body).foregroundStyle(theme.secondaryText)
            }
            ForEach(items, id: \.id) { item in
                Button { toggle(item) } label: {
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        Image(systemName: isCompleted(item) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isCompleted(item) ? theme.success : theme.secondaryText)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label)
                                .bighelpFont(.body)
                                .strikethrough(isCompleted(item))
                            if let detail = item.detail {
                                Text(detail).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(interactions?.isCurrent != true || messageID.isEmpty)
                .accessibilityLabel(item.label)
                .accessibilityValue(isCompleted(item) ? "Completed on this device" : "Not completed")
                .accessibilityHint("Changes only this device; it does not update Reminders or Hermes.")
            }
        }
        .onAppear(perform: restore)
    }

    private struct Item: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let initial: Bool
    }

    private var items: [Item] {
        (card.data["items"]?.array ?? []).compactMap { raw in
            guard let value = raw.object, let id = value["id"]?.string,
                  let label = value["label"]?.string,
                  let initial = value["completed"]?.boolean else { return nil }
            return Item(id: id, label: label, detail: value["detail"]?.string, initial: initial)
        }
    }

    private func isCompleted(_ item: Item) -> Bool { completed[item.id] ?? item.initial }

    private func restore() {
        guard let interactions, interactions.isCurrent else { return }
        let initial = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.initial) })
        completed = interactions.store.checklistState(for: identity(interactions), defaults: initial)
    }

    private func toggle(_ item: Item) {
        guard let interactions, interactions.isCurrent else { return }
        completed[item.id] = !isCompleted(item)
        interactions.store.setChecklistState(
            completed,
            for: identity(interactions),
            allowedItemIDs: Set(items.map(\.id))
        )
    }

    private func identity(_ handler: ChatCardInteractionHandler) -> ChatCardInteractionIdentity {
        .init(scope: handler.scope, messageID: messageID, cardID: card.id)
    }

    @BighelpThemeReader private var theme
}

private struct GenerativeUISelectionView: View {
    let card: GenerativeUICard
    let messageID: String
    @State private var selection = Set<String>()
    @State private var stagedText = ""
    @State private var showingDraftChoice = false
    @State private var confirmation: String?
    @Environment(\.chatCardInteractions) private var interactions

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let description = card.data["description"]?.string {
                Text(description).bighelpFont(.body).foregroundStyle(theme.secondaryText)
            }
            VStack(spacing: 1) {
                ForEach(options) { option in
                    Button { choose(option) } label: {
                        HStack(alignment: .top, spacing: BighelpTokens.space12) {
                            Image(systemName: selection.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selection.contains(option.id) ? theme.action : theme.secondaryText)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label).bighelpFont(.body)
                                if let detail = option.detail {
                                    Text(detail).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(option.enabled ? theme.primaryText : theme.tertiaryText)
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(minHeight: 48)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.enabled || interactions?.isCurrent != true || messageID.isEmpty)
                    .accessibilityValue(option.enabled ? (selection.contains(option.id) ? "Selected" : "Not selected") : "Unavailable")
                }
            }
            .background(theme.raisedSurface, in: .rect(cornerRadius: 12))

            Button(action: prepareStaging) {
                Label(card.data["submit_label"]?.string ?? "Use selection", systemImage: "text.cursor")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .bighelpProminentButtonStyle()
            .tint(theme.action)
            .disabled(selection.isEmpty || interactions?.isCurrent != true)
            .accessibilityHint("Adds text to the composer for review. Nothing is sent.")

            if let confirmation {
                Text(confirmation).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            }
        }
        .onAppear(perform: restore)
        .confirmationDialog("The composer already contains text", isPresented: $showingDraftChoice) {
            Button("Add to Draft") { commit(.append) }
            Button("Replace Draft", role: .destructive) { commit(.replace) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose how to stage this selection. Nothing will be sent.")
        }
    }

    private struct Option: Identifiable {
        let id: String
        let label: String
        let detail: String?
        let enabled: Bool
        let stageText: String
    }

    private var options: [Option] {
        (card.data["options"]?.array ?? []).compactMap { raw in
            guard let value = raw.object, let id = value["id"]?.string,
                  let label = value["label"]?.string,
                  let enabled = value["enabled"]?.boolean,
                  let stageText = value["stage_text"]?.string else { return nil }
            return Option(id: id, label: label, detail: value["detail"]?.string,
                          enabled: enabled, stageText: stageText)
        }
    }

    private var isMultiple: Bool { card.data["mode"]?.string == "multiple" }
    private var maximum: Int { isMultiple ? (card.data["max_selected"]?.integer ?? options.count) : 1 }

    private func restore() {
        guard let interactions, interactions.isCurrent else { return }
        selection = interactions.store.selection(
            for: identity(interactions),
            allowedOptionIDs: Set(options.map(\.id)),
            maximum: maximum
        )
    }

    private func choose(_ option: Option) {
        guard let interactions, interactions.isCurrent else { return }
        if isMultiple {
            if selection.contains(option.id) { selection.remove(option.id) }
            else if selection.count < maximum { selection.insert(option.id) }
        } else {
            selection = [option.id]
        }
        interactions.store.setSelection(
            selection,
            for: identity(interactions),
            allowedOptionIDs: Set(options.map(\.id)),
            maximum: maximum
        )
        confirmation = nil
    }

    private func prepareStaging() {
        guard let interactions, interactions.isCurrent else { return }
        stagedText = options.filter { selection.contains($0.id) }.map(\.stageText).joined(separator: "\n")
        guard !stagedText.isEmpty else { return }
        if interactions.currentDraft().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commit(.replace)
        } else {
            showingDraftChoice = true
        }
    }

    private func commit(_ strategy: ChatCardComposerMergeStrategy) {
        guard let interactions, !stagedText.isEmpty else { return }
        do {
            try interactions.stage(stagedText, strategy: strategy)
            confirmation = "Added to the composer for review."
        } catch {
            confirmation = "This card no longer belongs to the open conversation."
        }
        stagedText = ""
    }

    private func identity(_ handler: ChatCardInteractionHandler) -> ChatCardInteractionIdentity {
        .init(scope: handler.scope, messageID: messageID, cardID: card.id)
    }

    @BighelpThemeReader private var theme
}

private struct GenerativeUIAutomationView: View {
    let card: GenerativeUICard
    @State private var status: ScheduledTaskStatus
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showingRunConfirmation = false
    @State private var pendingStageText = ""
    @State private var showingDraftChoice = false
    @Environment(\.chatCardInteractions) private var interactions

    init(card: GenerativeUICard) {
        self.card = card
        _status = State(initialValue: ScheduledTaskStatus(rawValue: card.data["state"]?.string ?? "") ?? .failed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let description = card.data["description"]?.string {
                Text(description).bighelpFont(.body).foregroundStyle(theme.secondaryText)
            }
            detail("Status", status.title)
            detail("Schedule", card.data["schedule"]?.string ?? "Unavailable")
            detail("Delivery", card.data["delivery"]?.string ?? "Unavailable")
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .bighelpFont(.metadata).foregroundStyle(theme.danger)
            }
            HStack(spacing: BighelpTokens.space8) {
                ForEach(operations, id: \.rawValue) { operation in
                    Button(operationTitle(operation)) { request(operation) }
                        .buttonStyle(.bordered)
                        .disabled(isWorking || interactions?.scheduledTasks == nil || interactions?.isCurrent != true)
                }
            }
            if let stageText = card.data["stage_text"]?.string {
                Button("Edit in Composer") { stage(stageText) }
                    .buttonStyle(.bordered)
                    .disabled(interactions?.isCurrent != true)
                    .accessibilityHint("Adds text to the composer for review. Nothing is sent.")
            }
            Text("Historical snapshot · actions re-check the current task before changing Hermes.")
                .bighelpFont(.metadata).foregroundStyle(theme.tertiaryText)
        }
        .confirmationDialog("Run this paused task now?", isPresented: $showingRunConfirmation) {
            Button("Run Now") { perform(.run) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Hermes may resume the task as part of running it.")
        }
        .confirmationDialog("The composer already contains text", isPresented: $showingDraftChoice) {
            Button("Add to Draft") { commitStage(.append) }
            Button("Replace Draft", role: .destructive) { commitStage(.replace) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose how to stage this edit. Nothing will be sent.")
        }
    }

    private var operations: [ChatCardAutomationAction] {
        (card.data["operations"]?.array ?? []).compactMap { raw in
            raw.string.flatMap(ChatCardAutomationAction.init(rawValue:))
        }
    }

    private func request(_ action: ChatCardAutomationAction) {
        if action == .run && status == .paused { showingRunConfirmation = true }
        else { perform(action) }
    }

    private func perform(_ action: ChatCardAutomationAction) {
        guard let interactions, let snapshot else { return }
        isWorking = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let confirmed = try await interactions.perform(action, snapshot: snapshot)
                status = confirmed.status
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Hermes did not confirm this change. Try again."
            }
            isWorking = false
        }
    }

    private var snapshot: ChatCardAutomationSnapshot? {
        guard let jobID = card.data["job_id"]?.string,
              let profile = card.data["profile"]?.string else { return nil }
        return .init(jobID: jobID, profileID: profile, status: status)
    }

    private func stage(_ text: String) {
        guard let interactions, interactions.isCurrent else { return }
        pendingStageText = text
        if interactions.currentDraft().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitStage(.replace)
        } else {
            showingDraftChoice = true
        }
    }

    private func commitStage(_ strategy: ChatCardComposerMergeStrategy) {
        guard let interactions, !pendingStageText.isEmpty else { return }
        do {
            try interactions.stage(pendingStageText, strategy: strategy)
        } catch {
            errorMessage = "This card no longer belongs to the open conversation."
        }
        pendingStageText = ""
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            Spacer(minLength: BighelpTokens.space12)
            Text(value).bighelpFont(.body).foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.trailing)
        }
    }

    private func operationTitle(_ action: ChatCardAutomationAction) -> String {
        switch action { case .pause: "Pause"; case .resume: "Resume"; case .run: "Run Now" }
    }

    @BighelpThemeReader private var theme
}

private struct GenerativeUIChartView: View {
    let data: [String: BighelpJSONValue]

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let description = data["description"]?.string {
                Text(description)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            GeometryReader { geometry in
                ZStack(alignment: .bottomLeading) {
                    ForEach(0..<4, id: \.self) { index in
                        Rectangle()
                            .fill(theme.border.opacity(0.65))
                            .frame(height: BighelpTokens.hairline)
                            .offset(y: CGFloat(index) * geometry.size.height / 3)
                    }
                    if chartType == "bar" {
                        barChart(size: geometry.size)
                    } else {
                        lineChart(size: geometry.size)
                    }
                }
            }
            .frame(height: 154)
            legend
        }
        .padding(BighelpTokens.space12)
        .background(theme.raisedSurface, in: .rect(cornerRadius: 14))
    }

    private var chartType: String { data["chart_type"]?.string ?? "line" }
    private var series: [[String: BighelpJSONValue]] {
        (data["series"]?.array ?? []).compactMap(\.object)
    }

    private var values: [Double] {
        series.flatMap { ($0["points"]?.array ?? []).compactMap { $0.object?["y"]?.number } }
    }

    private var range: ClosedRange<Double> {
        let minimum = data["y_axis"]?.object?["min"]?.number ?? values.min() ?? 0
        let maximum = data["y_axis"]?.object?["max"]?.number ?? values.max() ?? 1
        return minimum...(maximum > minimum ? maximum : minimum + 1)
    }

    private func lineChart(size: CGSize) -> some View {
        ZStack {
            ForEach(Array(series.enumerated()), id: \.offset) { seriesIndex, item in
                let points = item["points"]?.array ?? []
                Path { path in
                    for (index, point) in points.enumerated() {
                        guard let value = point.object?["y"]?.number else { continue }
                        let x = points.count <= 1 ? size.width / 2 : CGFloat(index) / CGFloat(points.count - 1) * size.width
                        let y = yPosition(value, height: size.height)
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(seriesColor(seriesIndex), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func barChart(size: CGSize) -> some View {
        let flattened = series.enumerated().flatMap { seriesIndex, item in
            (item["points"]?.array ?? []).compactMap { value -> (Int, Double)? in
                guard let number = value.object?["y"]?.number else { return nil }
                return (seriesIndex, number)
            }
        }
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(flattened.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 4)
                    .fill(seriesColor(value.0))
                    .frame(height: max(3, size.height - yPosition(value.1, height: size.height)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var legend: some View {
        ScrollView(.horizontal) {
            HStack(spacing: BighelpTokens.space12) {
                ForEach(Array(series.enumerated()), id: \.offset) { index, item in
                    Label {
                        Text(item["label"]?.string ?? "Series \(index + 1)")
                    } icon: {
                        Circle().fill(seriesColor(index)).frame(width: 8, height: 8)
                    }
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func yPosition(_ value: Double, height: CGFloat) -> CGFloat {
        let progress = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return height - CGFloat(min(max(progress, 0), 1)) * height
    }

    private func seriesColor(_ index: Int) -> Color {
        let accents = theme.backgroundAccents
        return [
            theme.action,
            accents.indices.contains(1) ? accents[1] : theme.information,
            accents.indices.contains(2) ? accents[2] : theme.focus,
            theme.success,
            theme.warning,
            theme.danger,
        ][index % 6]
    }

    @BighelpThemeReader private var theme

}

private struct GenerativeUIFormPreview: View {
    let card: GenerativeUICard

    @State private var showingForm = false

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let description = card.data["description"]?.string {
                Text(description)
                    .bighelpFont(.body)
                    .foregroundStyle(theme.secondaryText)
            }
            ForEach(Array((card.data["fields"]?.array ?? []).enumerated()), id: \.offset) { _, value in
                if let field = value.object {
                    HStack(alignment: .top, spacing: BighelpTokens.space12) {
                        Image(systemName: fieldSymbol(field["kind"]?.string))
                            .foregroundStyle(theme.action)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(field["label"]?.string ?? "")
                                .bighelpFont(.label)
                                .foregroundStyle(theme.primaryText)
                            if let help = field["help_text"]?.string {
                                Text(help)
                                    .bighelpFont(.metadata)
                                    .foregroundStyle(theme.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                        if field["required"]?.boolean == true {
                            Text("Required")
                                .bighelpFont(.metadata, weight: .semibold)
                                .foregroundStyle(theme.action)
                        }
                    }
                    .padding(BighelpTokens.space12)
                    .background(theme.raisedSurface, in: .rect(cornerRadius: 12))
                }
            }
            Button {
                showingForm = true
            } label: {
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "hand.tap.fill")
                    Text(card.data["submit_label"]?.string ?? "Respond")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .bighelpFont(.label)
                .foregroundStyle(theme.action)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: 44)
                .background(theme.action.opacity(0.09), in: .rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showingForm) {
            GenerativeUIFormSheet(card: card)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func fieldSymbol(_ kind: String?) -> String {
        switch kind {
        case "select", "multi_select": "list.bullet.circle"
        case "toggle": "switch.2"
        case "integer", "decimal": "number"
        case "date": "calendar"
        default: "text.cursor"
        }
    }

    @BighelpThemeReader private var theme

}

private struct GenerativeUIFormSheet: View {
    private struct Option: Identifiable {
        let id: String
        let label: String
    }

    private struct Field: Identifiable {
        let id: String
        let kind: String
        let label: String
        let helpText: String?
        let required: Bool
        let options: [Option]
        let maximumSelected: Int?
        let defaultValue: BighelpJSONValue?

        init?(_ value: BighelpJSONValue) {
            guard
                let object = value.object,
                let id = object["id"]?.string,
                let kind = object["kind"]?.string,
                let label = object["label"]?.string,
                let required = object["required"]?.boolean
            else { return nil }
            self.id = id
            self.kind = kind
            self.label = label
            helpText = object["help_text"]?.string
            self.required = required
            options = (object["options"]?.array ?? []).compactMap { candidate in
                guard
                    let option = candidate.object,
                    let id = option["id"]?.string,
                    let label = option["label"]?.string
                else { return nil }
                return Option(id: id, label: label)
            }
            maximumSelected = object["max_selected"]?.integer
            defaultValue = object["default"]
        }
    }

    private struct ActionContext {
        let requestID: String
        let profile: String
        let sessionID: String
        let expiresAt: Date

        init?(card: GenerativeUICard) {
            guard
                let action = card.action,
                action["kind"]?.string == "submit_form",
                let requestID = action["request_id"]?.string,
                let owner = action["owner"]?.object,
                let profile = owner["profile"]?.string,
                let sessionID = owner["session_id"]?.string,
                let expires = action["expires_at"]?.string,
                let expiresAt = ISO8601DateFormatter().date(from: expires)
            else { return nil }
            self.requestID = requestID
            self.profile = profile
            self.sessionID = sessionID
            self.expiresAt = expiresAt
        }
    }

    let card: GenerativeUICard
    private let fields: [Field]
    private let action: ActionContext?

    @State private var textValues: [String: String]
    @State private var toggleValues: [String: Bool]
    @State private var multipleValues: [String: Set<String>]
    @State private var isSubmitting = false
    @State private var resultMessage: String?
    @State private var resultSucceeded = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.generativeUIFormMessaging) private var messaging

    init(card: GenerativeUICard) {
        self.card = card
        let fields = (card.data["fields"]?.array ?? []).compactMap(Field.init)
        self.fields = fields
        action = ActionContext(card: card)
        var text: [String: String] = [:]
        var toggles: [String: Bool] = [:]
        var multiples: [String: Set<String>] = [:]
        for field in fields {
            switch field.kind {
            case "toggle":
                toggles[field.id] = field.defaultValue?.boolean ?? false
            case "multi_select":
                multiples[field.id] = Set(
                    (field.defaultValue?.array ?? []).compactMap(\.string)
                )
            case "date":
                text[field.id] = field.defaultValue?.string
                    ?? Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            default:
                text[field.id] = field.defaultValue?.displayText ?? ""
            }
        }
        _textValues = State(initialValue: text)
        _toggleValues = State(initialValue: toggles)
        _multipleValues = State(initialValue: multiples)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let description = card.data["description"]?.string {
                    Section { Text(description).foregroundStyle(.secondary) }
                }

                Section("Response") {
                    ForEach(fields) { field in
                        fieldView(field)
                    }
                }

                if let resultMessage {
                    Section {
                        Label(
                            resultMessage,
                            systemImage: resultSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                        )
                        .foregroundStyle(resultSucceeded ? Color.green : theme.danger)
                    }
                }

                Section {
                    Button {
                        submit()
                    } label: {
                        HStack {
                            if isSubmitting {
                                ProgressView()
                                    .accessibilityHidden(true)
                            }
                            Text(card.data["submit_label"]?.string ?? "Submit")
                                .frame(maxWidth: .infinity)
                        }
                        .frame(minHeight: BighelpTokens.hitTarget)
                    }
                    .bighelpProminentButtonStyle()
                    .tint(theme.action)
                    .disabled(isSubmitting || resultSucceeded || messaging == nil || isExpired)

                    if messaging == nil {
                        Text("Connect to your Hermes host to send this response.")
                            .foregroundStyle(.secondary)
                    } else if isExpired {
                        Text("This response card has expired. Ask the agent to create a fresh one.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(card.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldView(_ field: Field) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: 5) {
                Text(field.label)
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                if field.required {
                    Text("Required")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.action)
                }
            }
            switch field.kind {
            case "textarea":
                TextEditor(text: textBinding(field.id))
                    .bighelpFont(.body)
                    .frame(minHeight: 110)
                    .padding(8)
                    .background(theme.raisedSurface, in: .rect(cornerRadius: 12))
            case "select":
                Picker(field.label, selection: textBinding(field.id)) {
                    Text("Choose…").tag("")
                    ForEach(field.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            case "multi_select":
                VStack(spacing: 1) {
                    ForEach(field.options) { option in
                        Button {
                            toggle(option.id, in: field)
                        } label: {
                            HStack {
                                Text(option.label)
                                Spacer()
                                Image(
                                    systemName: selected(option.id, in: field)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .foregroundStyle(
                                    selected(option.id, in: field) ? theme.action : theme.secondaryText
                                )
                            }
                            .bighelpFont(.body)
                            .foregroundStyle(theme.primaryText)
                            .padding(BighelpTokens.space12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(theme.raisedSurface, in: .rect(cornerRadius: 12))
            case "toggle":
                Toggle(field.label, isOn: toggleBinding(field.id))
                    .labelsHidden()
                    .tint(theme.action)
            case "integer":
                TextField("0", text: textBinding(field.id))
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
            case "decimal":
                TextField("0", text: textBinding(field.id))
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
            case "date":
                DatePicker(
                    field.label,
                    selection: dateBinding(field.id),
                    displayedComponents: .date
                )
                .labelsHidden()
                .tint(theme.action)
            default:
                TextField("Enter a response", text: textBinding(field.id))
                    .textFieldStyle(.roundedBorder)
            }
            if let helpText = field.helpText {
                Text(helpText)
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private func submit() {
        guard let messaging, let action else {
            resultSucceeded = false
            resultMessage = "This response can’t be sent right now."
            return
        }
        do {
            let request = try BighelpLinkGenerativeUIFormSubmission(
                requestID: action.requestID,
                sessionID: action.sessionID,
                profile: action.profile,
                values: try submissionValues(),
                submittedAt: Int(Date.now.timeIntervalSince1970)
            )
            isSubmitting = true
            resultMessage = nil
            Task { @MainActor in
                do {
                    let result = try await messaging.submit(request)
                    resultSucceeded = result.state == .success
                    resultMessage = result.message
                } catch {
                    resultSucceeded = false
                    resultMessage = "The response didn’t reach your agent. Try again."
                }
                isSubmitting = false
            }
        } catch {
            resultSucceeded = false
            resultMessage = "Complete the required fields with valid values."
        }
    }

    private func submissionValues() throws -> [String: BighelpJSONValue] {
        var result: [String: BighelpJSONValue] = [:]
        for field in fields {
            switch field.kind {
            case "toggle":
                result[field.id] = .boolean(toggleValues[field.id] ?? false)
            case "multi_select":
                result[field.id] = .array(
                    (multipleValues[field.id] ?? []).sorted().map(BighelpJSONValue.string)
                )
            case "integer":
                let raw = (textValues[field.id] ?? "").trimmingCharacters(in: .whitespaces)
                if raw.isEmpty, !field.required { continue }
                guard let value = Int(raw) else { throw BighelpLinkWireError.invalidValue }
                result[field.id] = .integer(value)
            case "decimal":
                let raw = (textValues[field.id] ?? "").trimmingCharacters(in: .whitespaces)
                if raw.isEmpty, !field.required { continue }
                guard let value = Double(raw), value.isFinite else {
                    throw BighelpLinkWireError.invalidValue
                }
                result[field.id] = .number(value)
            default:
                let value = textValues[field.id] ?? ""
                if value.isEmpty, !field.required { continue }
                guard !value.isEmpty || !field.required else {
                    throw BighelpLinkWireError.invalidValue
                }
                result[field.id] = .string(value)
            }
        }
        return result
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(
            get: { textValues[id] ?? "" },
            set: { textValues[id] = $0 }
        )
    }

    private func toggleBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { toggleValues[id] ?? false },
            set: { toggleValues[id] = $0 }
        )
    }

    private func dateBinding(_ id: String) -> Binding<Date> {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return Binding(
            get: { formatter.date(from: textValues[id] ?? "") ?? .now },
            set: { textValues[id] = formatter.string(from: $0) }
        )
    }

    private func selected(_ option: String, in field: Field) -> Bool {
        multipleValues[field.id]?.contains(option) == true
    }

    private func toggle(_ option: String, in field: Field) {
        var selection = multipleValues[field.id] ?? []
        if selection.contains(option) {
            selection.remove(option)
        } else if selection.count < (field.maximumSelected ?? field.options.count) {
            selection.insert(option)
        }
        multipleValues[field.id] = selection
    }

    private var isExpired: Bool {
        guard let action else { return true }
        return action.expiresAt <= .now
    }

    @BighelpThemeReader private var theme
}
