#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Narrow or crowded margin notes remain individually readable and explicitly selectable. On a
/// narrow column (iPhone, Slide Over) handwritten notes from the text show as icons and open here
/// too (owner decision 2026-10-02, BF-074).
struct MarginNoteSheet: View {
    let notes: [InkNote]
    let chapter: String?
    var edit: ((InkNote) async -> Bool)? = nil
    /// Deletes a note as one undo step; false when the reader could not (busy, read-only).
    var delete: ((InkNote) -> Bool)? = nil
    let dismiss: () -> Void
    @State private var editing: String?
    @State private var viewing: InkNote?
    @State private var errorMessage: String?
    @State private var confirmingDelete: InkNote?
    @State private var deleted: Set<String> = []

    private var shown: [InkNote] { notes.filter { !deleted.contains($0.id) } }
    private var onlyMargin: Bool { notes.allSatisfy(\.isMarginNote) }

    var body: some View {
        let notes = shown
        NavigationStack {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "Note not found",
                        systemImage: "pencil.slash",
                        description: Text("This note may have been erased on another device.")
                    )
                } else {
                    List {
                        if notes.count > 1 {
                            Text(
                                onlyMargin
                                    ? "These notes share a crowded margin. Each drawing remains attached to its own passage."
                                    : "These notes are close together. Each drawing remains attached to its own passage."
                            )
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(notes) { note in
                            Section {
                                StrokeThumbnail(strokes: note.strokes)
                                    .frame(maxWidth: .infinity).frame(height: 200)
                                    .accessibilityLabel(
                                        note.isMarginNote
                                            ? "Handwritten margin note" : "Handwritten note"
                                    )
                                Text("Near “\(note.anchor.exact)”")
                                if note.strokes.isEmpty {
                                    Text("Empty writing area").foregroundStyle(.secondary)
                                } else {
                                    Button("View Full Drawing") { viewing = note }
                                }
                                if let edit, note.isMarginNote {
                                    Button(
                                        editing == note.id
                                            ? "Preparing Preview…" : "Move into Text…"
                                    ) {
                                        editing = note.id
                                        Task {
                                            if !(await edit(note)) {
                                                errorMessage =
                                                    "This note couldn’t be previewed. It may need passage repair, or the reader has unsaved changes. Close and try again after resolving them."
                                            }
                                            editing = nil
                                        }
                                    }
                                    .disabled(editing != nil)
                                }
                                if delete != nil {
                                    Button("Delete Note", role: .destructive) {
                                        confirmingDelete = note
                                    }
                                    .disabled(editing != nil)
                                }
                            }
                        }
                        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss).disabled(editing != nil)
                }
            }
        }
        .confirmationDialog(
            "Delete this handwritten note?",
            isPresented: Binding(
                get: { confirmingDelete != nil },
                set: { if !$0 { confirmingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingDelete
        ) { note in
            Button("Delete Note", role: .destructive) { remove(note) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The drawing will be removed from this book.")
        }
        .sheet(item: $viewing) { note in
            NavigationStack {
                VStack(alignment: .leading) {
                    Text("Near “\(note.anchor.exact)”").padding(.horizontal)
                    Text("Pinch to zoom; scroll to see the full drawing.").font(.footnote)
                        .foregroundStyle(.secondary).padding(.horizontal)
                    if let drawing = InkVisualExport.drawing(note.strokes, maxWidth: 720) {
                        SVGPreviewSurface(data: Data(drawing.svg.utf8))
                    }
                }
                .navigationTitle(note.isMarginNote ? "Margin Drawing" : "Handwritten Drawing")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { viewing = nil } }
                }
            }
        }
        .interactiveDismissDisabled(editing != nil)
        .presentationDetents(detents)
    }

    /// iPad opens the whole sheet: notes too tall for the margin open here (owner decision
    /// 2026-10-03), and a half-height sheet hid their passage and buttons below the drawing.
    private var detents: Set<PresentationDetent> {
        // A sheet's own size class is compact even on iPad, so ask the device.
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad { return [.large] }
        #endif
        return [.medium, .large]
    }

    private var title: String {
        let kind = onlyMargin ? "Margin notes" : "Handwritten notes"
        return chapter.map { "\(kind) · \($0)" } ?? kind
    }

    private func remove(_ note: InkNote) {
        confirmingDelete = nil
        guard let delete, delete(note) else {
            errorMessage = "This note couldn’t be deleted right now. Try again in a moment."
            return
        }
        errorMessage = nil
        deleted.insert(note.id)
        if shown.isEmpty { dismiss() }
    }
}
#endif
