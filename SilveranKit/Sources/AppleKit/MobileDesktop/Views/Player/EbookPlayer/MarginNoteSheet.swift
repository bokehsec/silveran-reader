#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// A margin note shown on its own, where the screen is too narrow for a margin beside the text
/// (P5.2): tapping its icon on the page opens it here.
struct MarginNoteSheet: View {
    let strokes: [InkStroke]
    let chapter: String?
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if strokes.isEmpty {
                    ContentUnavailableView(
                        "Note not found",
                        systemImage: "pencil.slash",
                        description: Text("This note may have been erased on another device.")
                    )
                } else {
                    StrokeThumbnail(strokes: strokes)
                        .frame(maxWidth: .infinity)
                        .frame(height: 260)
                        .accessibilityLabel("Handwritten margin note")
                }
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle(chapter.map { "Margin note · \($0)" } ?? "Margin note")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
#endif
