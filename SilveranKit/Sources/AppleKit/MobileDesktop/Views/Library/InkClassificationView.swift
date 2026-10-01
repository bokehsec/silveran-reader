#if os(iOS) || os(macOS)
import SwiftUI

/// Classification edits join the existing book owner; the view owns no durable state.
struct InkClassificationView: View {
    let entry: AnnotationEntry
    @Environment(\.dismiss) private var dismiss
    @State private var session: InkSession?
    @State private var original: InkMark?
    @State private var choice = ""
    @State private var loading = true
    @State private var saving = false
    @State private var pendingSave = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("Loading handwriting…") }
                if let mark = original {
                    Section("Original handwriting") {
                        if !mark.stroke.points.isEmpty {
                            StrokeThumbnail(strokes: [mark.stroke]).frame(height: 120)
                        }
                        Text("Near “\(entry.quote ?? mark.start.exact)”")
                    }
                    Section("Treat this drawing as") {
                        Picker("Annotation type", selection: $choice) {
                            Text("Handwritten Note").tag("note")
                                .disabled(mark.stroke.points.isEmpty)
                            Text("Underline").tag("underline")
                            Text("Strike-through").tag("strike")
                            Text("Circle").tag("circle")
                            Text("Bracket").tag("bracket")
                            Text("Highlight").tag("highlight")
                        }
                        .disabled(saving || pendingSave)
                        Text(
                            "The attached passage and original stroke samples stay kept. A note appears before these words. Changes can be undone in the reader."
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                        if mark.stroke.points.isEmpty {
                            Text(
                                "This older mark has no original handwriting samples. You can change its mark type, but its original drawing cannot be recovered."
                            )
                            .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                        if pendingSave {
                            Button("Retry Save") { Task { await save(retry: true) } }
                                .disabled(saving)
                        }
                    }
                }
                if saving { ProgressView("Saving…") }
            }
            .navigationTitle("Correct Handwriting Type")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Change") { Task { await save(retry: false) } }
                        .disabled(
                            saving || pendingSave || original == nil
                                || choice == original?.kind.rawValue
                        )
                }
            }
            .task { await load() }
            .onDisappear {
                if let session {
                    ReadingSessionStore.shared.releaseInkIfSaved(
                        for: entry.bookID,
                        session: session
                    )
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func load() async {
        let owner = ReadingSessionStore.shared.inkSession(for: entry.bookID)
        session = owner
        await owner.open(bookID: entry.bookID)
        guard owner.canEdit, await owner.flush() else {
            loading = false
            errorMessage =
                "Handwriting needs recovery or has unsaved changes. Retry saving in the reader before editing its type."
            return
        }
        original = owner.section(entry.href).marks.first { $0.id == entry.id }
        choice = original?.kind.rawValue ?? ""
        if original == nil {
            errorMessage = "This mark changed or was deleted. Close and reopen it from Annotations."
        }
        loading = false
    }

    private func save(retry: Bool) async {
        guard let session, let original, !saving else { return }
        saving = true
        defer { saving = false }
        if retry {
            if await session.retrySave() {
                pendingSave = false
                dismiss()
            } else {
                errorMessage =
                    "Still couldn't save. The edit remains in this book; retry here or in the reader."
            }
            return
        }
        guard await session.flush(),
            session.correctMark(
                href: entry.href,
                expected: original,
                kind: choice == "note" ? nil : InkMarkKind(rawValue: choice)
            )
        else {
            errorMessage =
                "The mark changed or the reader is busy. Close and reopen it before making this change."
            return
        }
        if await session.flush() {
            dismiss()
        } else {
            pendingSave = true
            errorMessage =
                "Couldn't save yet. Your edit is retained in this book. Retry Save before relying on it after restart."
        }
    }
}
#endif
