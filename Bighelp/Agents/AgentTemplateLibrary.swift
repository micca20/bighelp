import Foundation
import Observation
import SwiftUI

/// An agent's setup saved to reuse later: its role, description, instructions
/// and look. New agents made from it still start from the host's usual setup
/// (skills, memory and settings copied from the default agent).
struct SavedAgentTemplate: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var role: String
    var summary: String
    var instructions: String
    var avatar: AgentAvatar?
    let sourceAgentName: String
    let createdAt: Date
}

/// Saved on this iPhone, so a template works with any of the person's computers.
@MainActor @Observable
final class AgentTemplateLibrary {
    static let shared = AgentTemplateLibrary()

    private(set) var templates: [SavedAgentTemplate] = []
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        load()
    }

    static var defaultFileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return folder.appendingPathComponent("agent-templates.json")
    }

    @discardableResult
    func save(from agent: AgentProfile, now: Date = .now) -> SavedAgentTemplate {
        let template = SavedAgentTemplate(
            id: UUID(), title: uniqueTitle(agent.name), role: agent.role, summary: agent.summary,
            instructions: agent.instructions, avatar: agent.avatar, sourceAgentName: agent.name, createdAt: now
        )
        templates.insert(template, at: 0)
        persist()
        return template
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].title = String(trimmed.prefix(80))
        persist()
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        persist()
    }

    private func uniqueTitle(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Agent" : name
        let taken = Set(templates.map(\.title))
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedAgentTemplate].self, from: data) else { return }
        templates = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(templates).write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            // A failed write keeps the in-memory list; the next change retries.
        }
    }
}

/// Pick a saved template to start a new agent from. Swipe to delete, hold to rename.
struct AgentTemplatePickerView: View {
    @Bindable var library: AgentTemplateLibrary
    let onBlank: () -> Void
    let onPick: (SavedAgentTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: SavedAgentTemplate?
    @State private var renameText = ""
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        dismiss()
                        onBlank()
                    } label: {
                        Label("Blank agent", systemImage: "plus")
                    }
                    .accessibilityIdentifier("agent-templates.blank")
                }
                .listRowBackground(theme.surface)
                Section {
                    ForEach(library.templates) { template in
                        Button {
                            dismiss()
                            onPick(template)
                        } label: {
                            row(template)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("agent-templates.\(template.id.uuidString)")
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(template.id) }
                        }
                        .contextMenu {
                            Button("Rename", systemImage: "pencil") { renameText = template.title; renaming = template }
                            Button("Delete", systemImage: "trash", role: .destructive) { library.delete(template.id) }
                        }
                    }
                } header: {
                    Text("Templates")
                } footer: {
                    Text("Templates are saved on this iPhone. Each keeps an agent's role, description, instructions and look. Save one from an agent's Edit screen or by holding it in Agents.")
                }
                .listRowBackground(theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("Rename template", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let template = renaming { library.rename(template.id, to: renameText) }
                    renaming = nil
                }
            }
        }
    }

    private func row(_ template: SavedAgentTemplate) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Image(systemName: "person.crop.square")
                .font(.title3)
                .foregroundStyle(theme.action)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).foregroundStyle(theme.primaryText)
                Text(template.role.isEmpty ? "From \(template.sourceAgentName)" : template.role)
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: BighelpTokens.hitTarget)
        .contentShape(.rect)
    }
}
