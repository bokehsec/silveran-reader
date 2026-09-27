#if os(iOS) || os(macOS)
import SwiftUI

/// Shown at the top of a book's details when its server no longer has it. The downloaded copy
/// stays readable; the notice explains that progress no longer syncs and offers the two ways
/// forward: find the book's current version on the server, or remove the stale copy.
struct SourceRemovedNotice: View {
    let item: BookMetadata
    let onOpenReplacement: (BookMetadata) -> Void
    let onRemovedFromLibrary: () -> Void

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var showingReplacementPicker = false
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("No longer on your server")
                    .font(.headline)
            } icon: {
                Image(systemName: "icloud.slash.fill")
                    .foregroundStyle(.orange)
            }

            Text(
                "This book was removed or replaced on your Storyteller server. Your downloaded copy and reading position are kept on this device, but progress no longer syncs."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Find on Server") {
                    showingReplacementPicker = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button("Remove Download", role: .destructive) {
                    confirmingRemoval = true
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .sheet(isPresented: $showingReplacementPicker) {
            SourceReplacementPicker(removedBook: item) { replacement in
                showingReplacementPicker = false
                onOpenReplacement(replacement)
            }
            .environment(mediaViewModel)
        }
        .confirmationDialog(
            "Remove the downloaded copy?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible,
        ) {
            Button("Remove Download", role: .destructive) {
                mediaViewModel.removeAllDownloads(for: item)
                onRemovedFromLibrary()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The book and your reading position will be removed from this device. This can't be undone."
            )
        }
    }
}

/// Lets the user choose which book on the server is the current version of a removed book,
/// then optionally carries their reading position across. The choice is always the user's:
/// the server keeps no record of what a removed book became.
private struct SourceReplacementPicker: View {
    let removedBook: BookMetadata
    let onOpen: (BookMetadata) -> Void

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var pendingChoice: BookMetadata?
    @State private var moveFailed = false

    init(removedBook: BookMetadata, onOpen: @escaping (BookMetadata) -> Void) {
        self.removedBook = removedBook
        self.onOpen = onOpen
        _query = State(initialValue: SourceReplacementSearch.suggestedQuery(for: removedBook))
    }

    private var candidates: [BookMetadata] {
        SourceReplacementSearch.candidates(
            for: removedBook,
            in: mediaViewModel.library.bookMetaData,
            query: query,
        )
    }

    private var removedProgress: Double {
        mediaViewModel.progress(for: removedBook.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search your server", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                }
                Section {
                    if candidates.isEmpty {
                        Text("No matching books on your server.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        Button {
                            choose(candidate)
                        } label: {
                            CandidateRow(
                                book: candidate,
                                progress: mediaViewModel.progress(for: candidate.id),
                            )
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Choose the book that replaced \u{201C}\(removedBook.title)\u{201D}.")
                }
            }
            .navigationTitle("Find on Server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .confirmationDialog(
                "Continue where you left off?",
                isPresented: Binding(
                    get: { pendingChoice != nil },
                    set: { if !$0 { pendingChoice = nil } },
                ),
                titleVisibility: .visible,
                presenting: pendingChoice,
            ) { choice in
                Button("Move My Position") {
                    Task { await open(choice, movingPosition: true) }
                }
                Button("Keep Its Position") {
                    Task { await open(choice, movingPosition: false) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { choice in
                Text(
                    "You were \(percent(removedProgress)) through your copy. \u{201C}\(choice.title)\u{201D} is at \(percent(mediaViewModel.progress(for: choice.id))). If it's a different edition, your place may not line up exactly."
                )
            }
            .alert("Couldn't move your position", isPresented: $moveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your copy's reading position couldn't be read, so nothing was changed.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func choose(_ candidate: BookMetadata) {
        if removedProgress > 0 {
            pendingChoice = candidate
        } else {
            onOpen(candidate)
        }
    }

    private func open(_ choice: BookMetadata, movingPosition: Bool) async {
        if movingPosition {
            let moved = await mediaViewModel.movePosition(from: removedBook.id, to: choice.id)
            if !moved {
                moveFailed = true
                return
            }
        }
        onOpen(choice)
    }

    private func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }
}

private struct CandidateRow: View {
    let book: BookMetadata
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(book.title)
                .font(.body)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                if let author = book.authors?.first?.name {
                    Text(author)
                }
                if progress > 0 {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
#endif
