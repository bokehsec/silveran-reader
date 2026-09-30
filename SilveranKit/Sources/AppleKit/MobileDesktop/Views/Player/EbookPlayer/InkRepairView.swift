#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Shown above the reader while some handwriting in the loaded chapters no longer finds its words
/// (usually after the book was replaced by a different edition). Nothing is lost: the ink is kept
/// and waits for the person to review it.
struct InkRepairBanner: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        if count > 0 {
            HStack(spacing: 12) {
                Label(message, systemImage: "pencil.and.list.clipboard")
                Spacer(minLength: 8)
                Button("Review", action: review)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }

    private var message: String {
        count == 1
            ? "1 annotation couldn’t find its place in this edition"
            : "\(count) annotations couldn’t find their place in this edition"
    }
}

/// Lists orphaned ink with the place the reader suggests for each. The person accepts a
/// suggestion, looks at it first, attaches the note to the page they are on, keeps it for later,
/// or deletes it. Every change is one undo step (P5.1, suggest-then-confirm).
struct InkRepairSheet: View {
    let viewModel: EbookPlayerViewModel
    let dismiss: () -> Void

    @State private var answers: [String: [InkRepairAnswer]] = [:]
    @State private var isLoading = true
    @State private var pendingDelete: Item?
    @State private var notice: String?

    struct Item: Identifiable, Hashable {
        let href: String
        let answer: InkRepairAnswer
        var id: String { "\(href)|\(answer.id)" }
    }

    private var session: InkSession { viewModel.inkSession }

    private var hrefs: [String] {
        answers.keys.sorted {
            (findSectionIndex(for: $0, in: viewModel.bookStructure) ?? .max)
                < (findSectionIndex(for: $1, in: viewModel.bookStructure) ?? .max)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Looking for where your notes belong…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if answers.values.allSatisfy(\.isEmpty) {
                    ContentUnavailableView(
                        "Everything is in place",
                        systemImage: "checkmark.circle",
                        description: Text("All handwriting in the open chapters has found its words.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Annotations to place")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
        .task(id: viewModel.inkOrphanCount) { await load() }
        .confirmationDialog(
            "Delete this handwriting?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) {
                if session.deleteInk(href: item.href, id: item.answer.id) { remove(item) }
            }
        } message: { _ in
            Text("You can undo this in the reader.")
        }
        .alert(
            "Can’t attach here",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var list: some View {
        List {
            Section {
                Text(
                    "These annotations were made in a different edition of the book. Check each suggested place and attach it there, or go to the right page and attach a note to that page."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            ForEach(hrefs, id: \.self) { href in
                if let rows = answers[href], !rows.isEmpty {
                    Section(viewModel.chapterLabel(forHref: href) ?? "Chapter") {
                        ForEach(rows, id: \.id) { answer in
                            row(Item(href: href, answer: answer))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let answer = item.answer
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                preview(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(item)).font(.headline)
                    if let suggestion = answer.suggestion {
                        excerpt(suggestion.excerpt)
                        Text(confidence(suggestion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No similar passage was found in this chapter.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            actions(item)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func preview(_ item: Item) -> some View {
        let section = session.section(item.href)
        if let note = section.notes.first(where: { $0.id == item.answer.id }) {
            StrokeThumbnail(strokes: note.strokes)
                .frame(width: 72, height: 54)
                .accessibilityLabel("Handwritten note")
        } else {
            Image(systemName: "highlighter")
                .font(.title2)
                .frame(width: 72, height: 54)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
    }

    private func title(_ item: Item) -> String {
        let section = session.section(item.href)
        if let mark = section.marks.first(where: { $0.id == item.answer.id }) {
            return switch mark.kind {
                case .underline: "Underline"
                case .strike: "Strike-through"
                case .circle: "Circled words"
                case .bracket: "Bracket"
                case .highlight: "Highlight"
            }
        }
        return "Handwritten note"
    }

    private func excerpt(_ excerpt: InkRepairExcerpt) -> some View {
        (Text(excerpt.before) + Text(excerpt.match).bold().foregroundColor(.accentColor)
            + Text(excerpt.after))
            .font(.subheadline)
            .lineLimit(4)
    }

    private func confidence(_ suggestion: InkRepairSuggestion) -> String {
        if suggestion.isRepeatedPassage {
            return
                "These words appear \(suggestion.candidates) times in the chapter; this is the one nearest where the note was."
        }
        if suggestion.score >= 1 { return "Same words as before." }
        return "Close match: \(Int((suggestion.score * 100).rounded()))% of the words around the note are here."
    }

    @ViewBuilder
    private func actions(_ item: Item) -> some View {
        let isNote = item.answer.kind == "note"
        ViewThatFits(in: .horizontal) {
            HStack { buttons(item, isNote: isNote) }
            VStack(alignment: .leading) { buttons(item, isNote: isNote) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func buttons(_ item: Item, isNote: Bool) -> some View {
        if let suggestion = item.answer.suggestion {
            Button("Attach here") {
                if session.acceptRepair(href: item.href, answer: item.answer) { remove(item) }
            }
            .buttonStyle(.borderedProminent)
            if let cfi = suggestion.cfi {
                Button("Show in book") {
                    dismiss()
                    Task { await viewModel.showInkRepairPlace(cfi: cfi) }
                }
            }
        }
        if isNote {
            Button("Attach to current page") {
                Task { await attachToPage(item) }
            }
        }
        Button("Delete", role: .destructive) { pendingDelete = item }
    }

    private func attachToPage(_ item: Item) async {
        switch await session.attachNoteToCurrentPage(href: item.href, noteID: item.answer.id) {
            case .attached:
                remove(item)
            case .otherSection:
                notice =
                    "The page you’re on is in a different chapter. Go to a page in \(viewModel.chapterLabel(forHref: item.href) ?? "the note’s chapter") first."
            case .noText:
                notice = "There are no words on the page you’re on to attach the note to."
            case .unchanged:
                break
        }
    }

    private func remove(_ item: Item) {
        answers[item.href]?.removeAll { $0.id == item.answer.id }
    }

    private func load() async {
        var loaded: [String: [InkRepairAnswer]] = [:]
        for href in session.orphans.keys {
            // "missing" means the page no longer has it (already fixed or deleted).
            loaded[href] = await session.repairSuggestions(href: href).filter { $0.kind != "missing" }
        }
        answers = loaded
        isLoading = false
    }
}
#endif
