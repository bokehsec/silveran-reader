#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Narrow or crowded margin notes remain individually readable and explicitly selectable.
struct MarginNoteSheet: View {
    let notes: [InkNote]
    let chapter: String?
    var edit: ((InkNote) async -> Bool)? = nil
    let dismiss: () -> Void
    @State private var editing: String?
    @State private var viewing: InkNote?
    @State private var errorMessage: String?

    var body: some View {
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
                                "These notes share a crowded margin. Each drawing remains attached to its own passage."
                            )
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(notes) { note in
                            Section {
                                StrokeThumbnail(strokes: note.strokes)
                                    .frame(maxWidth: .infinity).frame(height: 200)
                                    .accessibilityLabel("Handwritten margin note")
                                Text("Near “\(note.anchor.exact)”")
                                Button("View Full Drawing") { viewing = note }
                                if let edit {
                                    Button(
                                        editing == note.id ? "Opening…" : "Edit This Note in Margin"
                                    ) {
                                        editing = note.id
                                        Task {
                                            if !(await edit(note)) {
                                                errorMessage =
                                                    "The page changed or the reader is busy. Close and tap the note group again."
                                            }
                                            editing = nil
                                        }
                                    }
                                    .disabled(editing != nil)
                                }
                            }
                        }
                        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(chapter.map { "Margin notes · \($0)" } ?? "Margin notes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss).disabled(editing != nil)
                }
            }
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
                .navigationTitle("Margin Drawing")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { viewing = nil } }
                }
            }
        }
        .interactiveDismissDisabled(editing != nil)
        .presentationDetents([.medium, .large])
    }
}
#endif
