import SwiftUI

/// A group chat in the all-hosts list: its name, host and who's in it.
struct FleetGroupRow: View {
    let group: FleetGroup
    let fleet: FleetStore

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(width: SessionRow.avatarSize, height: SessionRow.avatarSize)
                .background(theme.action.opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(group.name)
                        .font(.bighelp(.callout).weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if fleet.showsHostNames { FleetHostTag(name: fleet.hostName(group.hostID)) }
                    Spacer(minLength: BighelpTokens.space4)
                    Text(SessionRow.compactTimestamp(group.updatedAt))
                        .font(.bighelp(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(group.isWorking ? "Agents are working" : "Group chat")
                    .font(.bighelp(.footnote).weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Text(ListFormatter.localizedString(byJoining: group.memberNames))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @BighelpThemeReader private var theme
}

/// A section's name over its rows, with its own Rename and Delete.
struct FleetSectionHeader: View {
    let title: String
    let count: Int
    var onRename: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: "folder")
                .foregroundStyle(theme.secondaryText)
                .accessibilityHidden(true)
            Text(title)
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Text("\(count)")
                .font(.bighelp(.footnote))
                .monospacedDigit()
                .foregroundStyle(theme.secondaryText)
            Spacer(minLength: BighelpTokens.space8)
            if let onRename, let onDelete {
                Menu {
                    Button("Rename section", systemImage: "pencil", action: onRename)
                        .accessibilityIdentifier("fleet.section.rename")
                    if let onMoveUp { Button("Move up", systemImage: "arrow.up", action: onMoveUp) }
                    if let onMoveDown { Button("Move down", systemImage: "arrow.down", action: onMoveDown) }
                    Button("Delete section", systemImage: "trash", role: .destructive, action: onDelete)
                        .accessibilityIdentifier("fleet.section.delete")
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: BighelpTokens.hitTarget, height: 32)
                        .contentShape(.rect)
                }
                .foregroundStyle(theme.secondaryText)
                .accessibilityLabel("\(title) options")
                .accessibilityIdentifier("fleet.section.menu.\(title)")
            }
        }
        .textCase(nil)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fleet.section.\(title)")
    }

    @BighelpThemeReader private var theme
}

/// What a name prompt in the all-hosts list is for.
enum FleetNamePrompt: Equatable {
    /// A new section, optionally with an item to file into it.
    case newSection(filing: FleetListItem?)
    case renameSection(FleetSection)
    case renameGroup(FleetGroup)

    var title: String {
        switch self {
        case .newSection: "New section"
        case .renameSection: "Rename section"
        case .renameGroup: "Rename group"
        }
    }

    var confirmTitle: String {
        switch self {
        case .newSection: "Create"
        case .renameSection, .renameGroup: "Rename"
        }
    }
}

/// The all-hosts list's prompts: names, deleting a group, a save that
/// didn't work, and Undo after deleting a section.
struct FleetListPrompts: ViewModifier {
    let fleet: FleetStore
    @Binding var namePrompt: FleetNamePrompt?
    @Binding var deletingGroup: FleetGroup?
    @Binding var deletedSection: FleetSectionDeletion?
    let onGroupAction: ((FleetGroup, FleetGroupAction) -> Void)?
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: namePrompt) { _, prompt in
                switch prompt {
                case .renameSection(let section)?: name = section.name
                case .renameGroup(let group)?: name = group.name
                default: name = ""
                }
            }
            .alert(namePrompt?.title ?? "", isPresented: Binding(
                get: { namePrompt != nil }, set: { if !$0 { namePrompt = nil } })) {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("fleet.name-prompt.field")
                Button("Cancel", role: .cancel) { namePrompt = nil }
                Button(namePrompt?.confirmTitle ?? "OK") { submit() }
                    .disabled(FleetSection.cleanName(name) == nil)
                    .accessibilityIdentifier("fleet.name-prompt.confirm")
            }
            .confirmationDialog("Delete this group?", isPresented: Binding(
                get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }), titleVisibility: .visible) {
                Button("Delete group", role: .destructive) {
                    if let group = deletingGroup { onGroupAction?(group, .delete) }
                    deletingGroup = nil
                }
                .accessibilityIdentifier("fleet.group.delete.confirm")
            } message: { Text("This permanently deletes the group on Hermes and stops its active work.") }
            .alert("Couldn't save", isPresented: Binding(
                get: { fleet.placementError != nil }, set: { if !$0 { fleet.placementError = nil } })) {
                Button("OK", role: .cancel) { fleet.placementError = nil }
            } message: { Text(fleet.placementError ?? "") }
            .overlay(alignment: .bottom) { undoBanner }
            .task(id: deletedSection?.section.id) {
                guard deletedSection != nil else { return }
                try? await Task.sleep(for: .seconds(8))
                deletedSection = nil
            }
    }

    @ViewBuilder
    private var undoBanner: some View {
        if let deletion = deletedSection {
            HStack(spacing: BighelpTokens.space12) {
                Text("Deleted “\(deletion.section.name)”. Its agents are still here.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Undo") {
                    fleet.undoDeleteSection(deletion)
                    deletedSection = nil
                }
                .font(.bighelp(.subheadline).weight(.semibold))
                .accessibilityIdentifier("fleet.section.undo")
            }
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.vertical, BighelpTokens.space12)
            .background(theme.surface, in: .rect(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, BighelpTokens.space16)
            .padding(.bottom, 96)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("fleet.section.undo-banner")
        }
    }

    private func submit() {
        guard let prompt = namePrompt, let clean = FleetSection.cleanName(name) else { return }
        namePrompt = nil
        switch prompt {
        case .newSection(let filing):
            guard let section = fleet.createSection(named: clean) else { return }
            switch filing {
            case .agent(let agent)?: Task { try? await fleet.file(agent, in: section.id) }
            case .group(let group)?: fleet.file(group, in: section.id)
            case nil: break
            }
        case .renameSection(let section):
            Task { await fleet.renameSection(section.id, to: clean) }
        case .renameGroup(let group):
            onGroupAction?(group, .rename(clean))
        }
    }

    @BighelpThemeReader private var theme
}
