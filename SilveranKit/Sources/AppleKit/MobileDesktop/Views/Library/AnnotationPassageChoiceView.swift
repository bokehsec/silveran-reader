#if os(iOS) || os(macOS)
import SwiftUI

/// Explicit within-book chapter choice. Inspection proposes; the existing review owner commits.
struct AnnotationPassageChoiceView: View {
    let original: Highlight
    let category: LocalMediaCategory
    let confirm: (AnnotationPlacementIssue, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inspector = AnnotationBookInspector()
    @State private var chapters: [AnnotationBookInspector.Chapter] = []
    @State private var destination: String?
    @State private var quotation = ""
    @State private var proposal: AnnotationPlacementIssue?
    @State private var checking = true
    @State private var saving = false
    @State private var message: String?
    @State private var work: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("Original Annotation") {
                    if !original.text.isEmpty { Text(original.text).textSelection(.enabled) }
                    if let note = original.note, !note.isEmpty { Text(note) }
                    Text("The original passage is kept in the annotation's history after repair.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Choose a Passage") {
                    Picker("Chapter", selection: $destination) {
                        Text("Choose a chapter").tag(String?.none)
                        ForEach(chapters, id: \.href) { chapter in
                            Text(chapter.displayName).tag(Optional(chapter.href))
                        }
                    }
                    .disabled(checking || saving)
                    TextField("Words from the passage", text: $quotation, axis: .vertical)
                        .lineLimit(1...5)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { startSearch() }
                        .disabled(checking || saving)
                        .accessibilityHint(
                            "Enter words from the destination passage, including context for repeated phrases."
                        )
                    Button("Find Passage") { startSearch() }
                        .disabled(
                            destination == nil
                                || quotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || checking || saving
                        )
                    if checking {
                        ProgressView(chapters.isEmpty ? "Preparing chapters…" : "Finding passage…")
                    }
                }
                if let proposal, let excerpt = proposal.excerpt, let destination {
                    Section("Suggested Passage") {
                        Text(
                            chapters.first(where: { $0.href == destination })?.displayName
                                ?? destination
                        )
                        .font(.subheadline).foregroundStyle(.secondary)
                        (Text(excerpt.before) + Text(excerpt.match).bold() + Text(excerpt.after))
                            .textSelection(.enabled)
                        if proposal.candidates > 1 {
                            Label(
                                "This passage occurs \(proposal.candidates) times. Check the context, or enter more surrounding words to find another occurrence.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.subheadline).foregroundStyle(.orange)
                        }
                        Button("Attach to This Passage") {
                            startConfirmation(proposal, destination: destination)
                        }
                        .disabled(checking || saving)
                        if saving { ProgressView("Saving repair…") }
                    }
                }
                if let message {
                    Section {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                        if chapters.isEmpty {
                            Button("Try Again") {
                                work?.cancel()
                                work = Task { await load() }
                            }.disabled(checking || saving)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Choose Annotation Passage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .task {
                quotation = original.text
                await load()
            }
            .onChange(of: destination) {
                proposal = nil
                startSearch()
            }
            .onChange(of: quotation) {
                proposal = nil
                message = nil
            }
            .onDisappear {
                work?.cancel()
                inspector.close()
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    private func load() async {
        checking = true
        message = nil
        defer { checking = false }
        do {
            let result = try await inspector.open(bookID: original.bookID, category: category)
            try Task.checkCancellation()
            chapters = result
            if result.isEmpty {
                message = "This edition has no chapters to inspect. The annotation is kept."
            }
        } catch is CancellationError { return } catch { message = error.localizedDescription }
    }

    private func startSearch() {
        guard let destination, !checking, !saving else { return }
        work?.cancel()
        proposal = nil
        message = nil
        checking = true
        let words = quotation
        work = Task {
            defer { checking = false }
            do {
                let result = try await inspector.suggestPlacement(
                    for: original,
                    in: destination,
                    quotation: words
                )
                try Task.checkCancellation()
                proposal = result
                if result == nil {
                    message =
                        "No reliable passage was found. Try words from this chapter, or choose another chapter. Your annotation is kept."
                }
            } catch is CancellationError { return } catch { message = error.localizedDescription }
        }
    }

    private func startConfirmation(_ issue: AnnotationPlacementIssue, destination: String) {
        guard !checking, !saving else { return }
        work?.cancel()
        saving = true
        message = nil
        work = Task {
            defer { saving = false }
            do {
                try await confirm(issue, destination)
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}
#endif
