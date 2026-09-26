import SwiftUI

/// One bottom-anchored suggestion surface, shared by compact and expanded source.
/// Provider previews are inline, so browsing never steals the native responder.
struct ReferenceHubDrawer: View {
    let hub: ReferenceHubStore
    let commands: SlashCommandCatalogModel?
    var skills: SkillsAndToolsStore? = nil
    var agentID: String? = nil
    var reservesResultsSpace = false
    @State private var inspectedCommand: SlashCommandDescriptor?
    @State private var inspectedSkill: HermesSkillSummary?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @BighelpThemeReader private var theme

    private var term: String { hub.query?.query ?? "" }
    private var matchingCommands: [SlashCommandDescriptor] {
        (commands?.commands ?? []).filter { command in
            let categoryMatches = hub.category == .all || (hub.category == .skills && command.source == .skill)
                || (hub.category == .commands && command.source != .skill)
            return categoryMatches && (term.isEmpty || command.name.localizedCaseInsensitiveContains(term)
                || command.description.localizedCaseInsensitiveContains(term)
                || command.aliases.contains { $0.localizedCaseInsensitiveContains(term) })
        }.sorted { lhs, rhs in
            if (lhs.source == .skill) != (rhs.source == .skill) {
                return lhs.source == .skill
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    private var matchingSkills: [HermesSkillSummary] {
        guard hub.category == .skills || hub.category == .all,
              let catalog = skills?.catalog, catalog.agentID == agentID else { return [] }
        let commandNames = Set((commands?.commands ?? []).filter { $0.source == .skill }.map(\.name))
        return catalog.skills.filter {
            !commandNames.contains($0.name) && (term.isEmpty || $0.name.localizedCaseInsensitiveContains(term)
                || $0.description.localizedCaseInsensitiveContains(term))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if verticalSizeClass != .compact {
                HStack(spacing: BighelpTokens.space8) {
                    Text("Skills & commands").font(.headline)
                    if hub.isLoading || hub.isResolving || commands?.isLoading == true { ProgressView().accessibilityLabel("Loading skills and commands") }
                    Spacer(minLength: 0)
                    Button("Dismiss references", systemImage: "xmark") { hub.dismiss() }
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("reference-hub.dismiss")
                }
            }
            ScrollView(.horizontal) {
                HStack(spacing: BighelpTokens.space8) {
                    if verticalSizeClass == .compact {
                        Button("Dismiss references", systemImage: "xmark") { hub.dismiss() }
                            .labelStyle(.iconOnly).frame(width: 44, height: 44)
                            .accessibilityIdentifier("reference-hub.dismiss")
                        if hub.isLoading || hub.isResolving || commands?.isLoading == true { ProgressView().accessibilityLabel("Loading skills and commands") }
                    }
                    ForEach([ReferenceCategory.skills, .commands], id: \.rawValue) { category in
                        Button(category.label) {
                            inspectedCommand = nil
                            inspectedSkill = nil
                            hub.selectCategory(category)
                        }
                        .font(.subheadline.weight(hub.category == category ? .semibold : .regular))
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(minHeight: 44)
                        .background(hub.category == category ? theme.raisedSurface : theme.surface, in: .capsule)
                        .accessibilityAddTraits(hub.category == category ? .isSelected : [])
                        .accessibilityIdentifier("reference-hub.filter.\(category.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    if let preview = hub.preview {
                        providerPreview(preview)
                    } else if let command = inspectedCommand {
                        commandPreview(command)
                    } else if let skill = inspectedSkill {
                        Text(skill.name).font(.headline)
                        Text(skill.description).font(.body)
                        Text(skill.isEnabled ? "Installed skill" : "Disabled skill").font(.caption)
                        Text("This skill has no discoverable slash invocation. Browsing it does not run or enable it.")
                            .font(.caption).foregroundStyle(theme.secondaryText)
                        Button("Back to results") { inspectedSkill = nil }.frame(minHeight: 44)
                    } else {
                        resultRows
                    }
                }
                .padding(.vertical, BighelpTokens.space8)
            }
            .scrollDismissesKeyboard(.never)
            .frame(
                minHeight: reservesResultsSpace ? (verticalSizeClass == .compact ? 60 : 120) : nil,
                maxHeight: reservesResultsSpace ? (verticalSizeClass == .compact ? 60 : 120)
                    : (verticalSizeClass == .compact ? 60 : 240)
            )
        }
        .padding(.horizontal, BighelpTokens.space12)
        .foregroundStyle(theme.primaryText)
        .bighelpNavigationGlass(in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(theme.border, lineWidth: BighelpTokens.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reference-hub.drawer")
        .task(id: hub.isPresented) {
            guard hub.isPresented else { return }
            // Existing host catalog request only after deliberate slash entry.
            await commands?.loadIfNeeded(for: "/")
        }
        .task(id: hub.category) {
            guard hub.category == .skills, let skills, let agentID,
                  skills.catalog?.agentID != agentID else { return }
            await skills.load(agentID: agentID)
        }
        .onChange(of: hub.draftID) { _, _ in
            inspectedCommand = nil
            inspectedSkill = nil
        }
        .onChange(of: hub.query) { _, _ in
            inspectedCommand = nil
            inspectedSkill = nil
        }
    }

    @ViewBuilder private var resultRows: some View {
        ForEach(hub.results) { result in
            HStack(spacing: 8) {
                Button { hub.select(result) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.body.weight(.medium))
                        Text([result.category.label, result.subtitle, result.state, result.isCached ? "Cached" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(theme.secondaryText)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Insert this reference and continue typing. Does not send.")
                .accessibilityIdentifier("reference-hub.result.\(result.id)")
                Button("Inspect \(result.title)", systemImage: "info.circle") { hub.inspect(result) }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityHint("Review content and choose what to include")
                    .accessibilityIdentifier("reference-hub.inspect.\(result.id)")
            }
        }
        ForEach(matchingCommands) { command in
            HStack(spacing: 8) {
                Button { hub.insertCatalogToken(name: command.name) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("/\(command.name)").font(.body.weight(.medium))
                        Text(command.description).font(.caption).foregroundStyle(theme.secondaryText)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Insert text and continue typing. Does not execute this command.")
                .accessibilityIdentifier("reference-hub.command.\(command.name)")
                Button("Inspect /\(command.name)", systemImage: "info.circle") {
                    hub.beginLocalInspection()
                    inspectedCommand = command
                }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
                    .accessibilityIdentifier("reference-hub.inspect-command.\(command.name)")
            }
        }
        ForEach(matchingSkills) { skill in
            Button {
                hub.beginLocalInspection()
                inspectedSkill = skill
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name).font(.body)
                    Text(skill.description).font(.caption).foregroundStyle(theme.secondaryText)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
        }
        if hub.results.isEmpty && matchingCommands.isEmpty && matchingSkills.isEmpty {
            Text(term.isEmpty ? "Choose a category or type to search available sources." : "No matching references or commands.")
                .font(.subheadline).foregroundStyle(theme.secondaryText)
            if [.repos, .issues, .prs, .wiki].contains(hub.category), !hub.isCategoryConfigured {
                Text("This optional source is not connected.").font(.caption).foregroundStyle(theme.secondaryText)
                if hub.canConnectCategory {
                    Button("Connect source") { hub.connectCategory() }.frame(minHeight: 44)
                        .accessibilityIdentifier("reference-hub.connect")
                }
            }
        }
        ForEach(hub.providerNotices.keys.sorted(), id: \.self) { key in
            Text(hub.providerNotices[key] ?? "").font(.caption).foregroundStyle(theme.secondaryText)
        }
        ForEach(hub.providerErrors.keys.sorted(), id: \.self) { key in
            Text(hub.providerErrors[key] ?? "").font(.caption).foregroundStyle(theme.secondaryText)
            Button("Retry source search") { hub.refreshSearch() }.frame(minHeight: 44)
        }
        if hub.category == .all || hub.category == .commands || hub.category == .skills {
            if let error = commands?.errorMessage {
                Text(error).font(.caption).foregroundStyle(theme.secondaryText)
                Button("Retry commands") { Task { await commands?.retry() } }.frame(minHeight: 44)
            }
        }
    }

    private func commandPreview(_ command: SlashCommandDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("/\(command.name)").font(.headline)
            Text(command.description).font(.body)
            if !command.argsHint.isEmpty { Text(command.argsHint).font(.caption.monospaced()) }
            Text("Inserts text only. A leading slash command runs only when you explicitly Send; inside prose it remains text.")
                .font(.caption).foregroundStyle(theme.secondaryText)
            Button("Insert /\(command.name)") {
                if hub.insertCatalogToken(name: command.name) { inspectedCommand = nil }
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("reference-hub.command.insert")
            Button("Back to results") { inspectedCommand = nil }.frame(minHeight: 44)
        }
    }

    private func providerPreview(_ preview: ReferenceHubPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(preview.result.title).font(.headline)
            Text(preview.sourceKindLabel).font(.caption)
            Text("Selected content is shared with this conversation, its model provider and paired account key holders. Credentials are never included.")
                .font(.caption).foregroundStyle(theme.secondaryText)
            ForEach(preview.options) { option in
                VStack(alignment: .leading, spacing: 8) {
                    Text(option.label).font(.subheadline.weight(.semibold))
                    ReferenceSnapshotSource(snapshot: option.snapshot)
                    Button("Insert \(option.label)") { hub.insert(option) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("reference-hub.insert.\(option.id)")
                }
                Divider()
            }
            Button("Back to results") { hub.closePreview() }.frame(minHeight: 44)
        }
    }
}

extension ReferenceCategory {
    var label: String {
        switch self {
        case .all: "All"
        case .repos: "Repos"
        case .issues: "Issues"
        case .prs: "PRs"
        case .wiki: "Wiki"
        case .skills: "Skills"
        case .commands: "Commands"
        }
    }
}

/// Inert source text, not a Markdown renderer that could load remote images or
/// run provider links. Every outgoing byte can be selected and inspected.
struct ReferenceSnapshotSource: View {
    let snapshot: ReferenceSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snapshot.qualifiedLocation).font(.subheadline)
            Text(snapshot.title).font(.body)
            Text(snapshot.selectedContent.isEmpty ? "Metadata only. Description not included." : snapshot.selectedContent)
                .font(.body.monospaced()).textSelection(.enabled)
            Text("Revision: \(snapshot.sourceRevision)").font(.caption.monospaced())
            if snapshot.isTruncated { Text("This selected snapshot is truncated.").font(.caption.weight(.semibold)) }
        }
        .accessibilityElement(children: .contain)
    }
}

struct ReferenceDraftStrip: View {
    let hub: ReferenceHubStore
    @State private var inspectedID: UUID?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(hub.selected) { value in
                        HStack(spacing: 0) {
                            Button {
                                hub.dismiss()
                                inspectedID = inspectedID == value.id ? nil : value.id
                            } label: {
                                Label(value.snapshot.displayLabel, systemImage: "link")
                                    .font(.subheadline).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 44)
                            }.accessibilityLabel("Inspect reference \(value.snapshot.displayLabel)")
                            Button("Remove reference", systemImage: "xmark") { hub.remove(value) }
                                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                                .accessibilityLabel("Remove reference \(value.snapshot.displayLabel)")
                                .accessibilityIdentifier("reference-hub.remove.\(value.id)")
                        }.bighelpSurface(.capsuleControl)
                    }
                }
            }
            if let value = hub.selected.first(where: { $0.id == inspectedID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(value.sourceKindLabel).font(.caption)
                        ReferenceSnapshotSource(snapshot: value.snapshot)
                    }
                }
                    .frame(maxHeight: verticalSizeClass == .compact ? 60 : 160).scrollDismissesKeyboard(.never)
            }
            if !hub.pendingChanges.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("References changed. Review before sending.").font(.headline)
                        ForEach(hub.pendingChanges) { change in
                            Text("Previously selected").font(.subheadline.weight(.semibold))
                            ReferenceSnapshotSource(snapshot: change.original.snapshot)
                            Text("Current source").font(.subheadline.weight(.semibold))
                            ReferenceSnapshotSource(snapshot: change.current)
                        }
                        Button("Use reviewed updates — send separately") { hub.acceptRevalidationChanges() }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("reference-hub.confirm-changes")
                    }
                }.frame(maxHeight: verticalSizeClass == .compact ? 80 : 200).scrollDismissesKeyboard(.never)
            }
            if let message = hub.message {
                HStack {
                    Text(message).font(.caption)
                    Button("Dismiss message", systemImage: "xmark") { hub.clearMessage() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reference-hub.selected")
    }
}
