import SwiftUI
import UniformTypeIdentifiers

/// Explicit PDF-as-pages picker. It prepares a local draft only; no Hermes RPC
/// and no prompt submission occurs until the owning chat handles explicit Send.
struct ChatPDFPagesAttachmentView: View {
    let target: DirectHermesPDFAttachmentTarget
    let isCurrent: @MainActor (DirectHermesPDFAttachmentTarget) -> Bool
    let onAddToDraft: @MainActor (DirectHermesPDFPageSelection) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isImporterPresented = false
    @State private var imported: DirectHermesPDFPageSelection?
    @State private var firstPage = 1
    @State private var lastPage = 1
    @State private var importTask: Task<Void, Never>?
    @State private var importGeneration = UUID()
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let imported {
                    documentSection(imported)
                    pageRangeSection(imported)
                    Section {
                        Button {
                            addToDraft(imported)
                        } label: {
                            Label(
                                "Add \(selectedPageCount) page\(selectedPageCount == 1 ? "" : "s") to draft",
                                systemImage: "photo.stack"
                            )
                            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                        }
                        .disabled(importTask != nil || !isCurrent(target))
                        .accessibilityIdentifier("chat.pdf-pages.add")
                    } footer: {
                        Text("Pages are queued on this exact Hermes session only after you press Send. The PDF file itself is not added by this choice.")
                    }
                } else if importTask != nil {
                    Section {
                        HStack(spacing: LoopdyTokens.space12) {
                            ProgressView()
                            Text("Reading PDF")
                            Spacer()
                            Button("Cancel", role: .cancel) { cancelImport() }
                        }
                        .frame(minHeight: LoopdyTokens.hitTarget)
                        .accessibilityIdentifier("chat.pdf-pages.loading")
                    }
                } else {
                    Section {
                        ContentUnavailableView(
                            "Choose a PDF",
                            systemImage: "doc.richtext",
                            description: Text("Select up to 25 consecutive pages for Hermes image understanding.")
                        )
                        Button("Choose PDF") { isImporterPresented = true }
                            .frame(maxWidth: .infinity, minHeight: LoopdyTokens.hitTarget)
                            .accessibilityIdentifier("chat.pdf-pages.choose")
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("chat.pdf-pages.error")
                    }
                }
            }
            .navigationTitle("PDF as pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelImport()
                        dismiss()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            onCompletion: importPDF
        )
        .onDisappear { cancelImport() }
    }

    private func documentSection(
        _ selection: DirectHermesPDFPageSelection
    ) -> some View {
        Section("Document") {
            LabeledContent("Name", value: selection.attachment.fileName)
            LabeledContent("Pages", value: String(selection.documentPageCount))
            LabeledContent(
                "Size",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(selection.attachment.data.count),
                    countStyle: .file
                )
            )
            Button("Choose another PDF") { isImporterPresented = true }
                .accessibilityIdentifier("chat.pdf-pages.choose-another")
        }
    }

    private func pageRangeSection(
        _ selection: DirectHermesPDFPageSelection
    ) -> some View {
        Section {
            Stepper(
                "First page: \(firstPage)",
                value: firstPageBinding(for: selection),
                in: 1...selection.documentPageCount
            )
            .accessibilityIdentifier("chat.pdf-pages.first-page")

            Stepper(
                "Last page: \(lastPage)",
                value: lastPageBinding(for: selection),
                in: firstPage...maximumLastPage(for: selection)
            )
            .accessibilityIdentifier("chat.pdf-pages.last-page")
        } header: {
            Text("Page range")
        } footer: {
            Text("Page numbers are one-based and inclusive. One request can contain at most 25 consecutive pages.")
        }
    }

    private var selectedPageCount: Int {
        max(0, lastPage - firstPage + 1)
    }

    private func maximumLastPage(
        for selection: DirectHermesPDFPageSelection
    ) -> Int {
        min(
            selection.documentPageCount,
            firstPage + DirectHermesPDFAttachmentLimits.maximumPagesPerRequest - 1
        )
    }

    private func firstPageBinding(
        for selection: DirectHermesPDFPageSelection
    ) -> Binding<Int> {
        Binding(
            get: { firstPage },
            set: { value in
                firstPage = value
                lastPage = min(max(lastPage, value), maximumLastPage(for: selection))
            }
        )
    }

    private func lastPageBinding(
        for selection: DirectHermesPDFPageSelection
    ) -> Binding<Int> {
        Binding(
            get: { lastPage },
            set: { value in
                lastPage = min(max(value, firstPage), maximumLastPage(for: selection))
            }
        )
    }

    private func importPDF(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard urls.count == 1, let url = urls.first else {
                errorMessage = DirectHermesPDFAttachmentError.invalidPDF.localizedDescription
                return
            }
            beginImport(url)
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            errorMessage = DirectHermesPDFAttachmentError.invalidPDF.localizedDescription
        }
    }

    private func beginImport(_ url: URL) {
        importTask?.cancel()
        let generation = UUID()
        importGeneration = generation
        imported = nil
        errorMessage = nil
        importTask = Task { @MainActor in
            defer {
                if importGeneration == generation { importTask = nil }
            }
            do {
                let selection = try await DirectHermesPDFImportPreparer.prepare(
                    url: url,
                    target: target
                )
                try Task.checkCancellation()
                guard importGeneration == generation, isCurrent(target) else {
                    throw DirectHermesPDFAttachmentError.targetChanged
                }
                imported = selection
                firstPage = selection.pageRange.firstPage
                lastPage = selection.pageRange.lastPage
            } catch is CancellationError {
                return
            } catch {
                guard importGeneration == generation else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? DirectHermesPDFAttachmentError.invalidPDF.localizedDescription
            }
        }
    }

    private func addToDraft(_ selection: DirectHermesPDFPageSelection) {
        do {
            guard isCurrent(target) else {
                throw DirectHermesPDFAttachmentError.targetChanged
            }
            let range = try DirectHermesPDFPageRange(
                firstPage: firstPage,
                lastPage: lastPage
            )
            try onAddToDraft(selection.selecting(range))
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "The PDF pages could not be added to this draft."
        }
    }

    private func cancelImport() {
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
    }
}
