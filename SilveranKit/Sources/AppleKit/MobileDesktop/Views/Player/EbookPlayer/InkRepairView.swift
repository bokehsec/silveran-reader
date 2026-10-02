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

/// Lists annotations that lost their words (handwriting and typed highlights) with the place the
/// reader suggests for each. The person accepts a suggestion, looks at it first, attaches a note
/// to the page they are on, keeps it for later, or deletes it (P5.1, suggest-then-confirm).
/// Handwriting changes are undo steps in the reader.
struct InkRepairSheet: View {
    let viewModel: EbookPlayerViewModel
    let dismiss: () -> Void

    @State private var items: [String: [Item]] = [:]
    @State private var isLoading = true
    @State private var pendingDelete: Item?
    @State private var notice: String?
    @State private var pendingInkRepair: Item?
    @State private var isCommitting = false
    /// The last load found nothing to list, as opposed to the person having resolved every row.
    @State private var loadFoundNothing = false

    /// One annotation to place, in the chapter with section href `href`.
    struct Item: Identifiable, Hashable {
        enum Kind: Hashable {
            case ink(InkRepairAnswer)
            case highlight(UUID, HighlightRepairAnswer)
        }
        let href: String
        let kind: Kind
        var checkedInk: SectionInk? = nil
        var checkedHighlight: Highlight? = nil
        var id: String {
            switch kind {
                case .ink(let answer): "ink|\(href)|\(answer.id)"
                case .highlight(let id, _): "highlight|\(id)"
            }
        }
    }

    private var session: InkSession { viewModel.inkSession }

    private var hrefs: [String] {
        items.keys.sorted {
            (findSectionIndex(for: $0, in: viewModel.bookStructure) ?? .max)
                < (findSectionIndex(for: $1, in: viewModel.bookStructure) ?? .max)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Looking for where your annotations belong…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if session.hasPendingChanges || pendingInkRepair != nil {
                    list
                } else if loadFoundNothing, viewModel.annotationRepairCount > 0 {
                    // The banner still counts annotations the page couldn't list just now. Never
                    // claim they are in place (BF-048).
                    ContentUnavailableView {
                        Label(
                            "Couldn’t list these annotations",
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(
                            "\(viewModel.annotationRepairCount) annotation(s) in the open chapters still need a place. They are kept; try again, or use Check & Repair in Annotations."
                        )
                    } actions: {
                        Button("Try Again") {
                            isLoading = true
                            Task { await load() }
                        }
                    }
                } else if items.values.allSatisfy(\.isEmpty) {
                    ContentUnavailableView(
                        "Everything is in place",
                        systemImage: "checkmark.circle",
                        description: Text(
                            "All annotations in the open chapters have found their words."
                        )
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
        .task(id: viewModel.annotationRepairCount) { await load() }
        .confirmationDialog(
            deleteTitle,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { Task { await delete(item) } }
        } message: { item in
            if case .ink = item.kind {
                Text("You can undo this in the reader.")
            } else {
                Text("This can’t be undone.")
            }
        }
        .alert(
            "Annotation update",
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
    }

    private var deleteTitle: String {
        if case .highlight = pendingDelete?.kind { return "Delete this highlight?" }
        return "Delete this handwriting?"
    }

    private var list: some View {
        List {
            if pendingInkRepair != nil || session.hasPendingChanges {
                Section {
                    Text("This change has not been saved. Your edit is retained in the reader.")
                    Button("Retry Save") { Task { await retrySave() } }
                        .disabled(isCommitting)
                }
            }
            Section {
                Text(
                    "These annotations were made in a different edition of the book. Check each suggested place and attach it there, or go to the right page and attach a note to that page."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            ForEach(hrefs, id: \.self) { href in
                if let rows = items[href], !rows.isEmpty {
                    Section(viewModel.chapterLabel(forHref: href) ?? "Chapter") {
                        ForEach(rows) { row($0) }
                    }
                }
            }
        }
    }

    // MARK: Rows

    private struct Shown {
        let excerpt: InkRepairExcerpt
        let score: Double
        let candidates: Int
    }

    private func suggestion(_ item: Item) -> Shown? {
        switch item.kind {
            case .ink(let answer):
                answer.suggestion.map {
                    Shown(excerpt: $0.excerpt, score: $0.score, candidates: $0.candidates)
                }
            case .highlight(_, let answer):
                answer.suggestion.map {
                    Shown(excerpt: $0.excerpt, score: $0.score, candidates: $0.candidates)
                }
        }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                preview(item)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(item)).font(.headline)
                    if case .highlight(let id, _) = item.kind,
                        let old = viewModel.highlights.first(where: { $0.id == id })
                    {
                        Text("Was: “\(old.displayText)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let shown = suggestion(item) {
                        excerpt(shown.excerpt)
                        Text(confidence(shown))
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
        switch item.kind {
            case .ink(let answer):
                if let note = session.section(item.href).notes.first(where: { $0.id == answer.id })
                {
                    StrokeThumbnail(strokes: note.strokes)
                        .frame(width: 72, height: 54)
                        .accessibilityLabel("Handwritten note")
                } else {
                    symbol("highlighter")
                }
            case .highlight(let id, _):
                let color = viewModel.highlights.first(where: { $0.id == id })?.color
                symbol("character.textbox")
                    .overlay(alignment: .bottom) {
                        if let color {
                            Capsule()
                                .fill(
                                    Color(hex: viewModel.settingsVM.hexColor(for: color)) ?? .yellow
                                )
                                .frame(height: 6)
                                .padding(8)
                        }
                    }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.title2)
            .frame(width: 72, height: 54)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }

    private func title(_ item: Item) -> String {
        switch item.kind {
            case .highlight:
                return "Highlight"
            case .ink(let answer):
                if let mark = session.section(item.href).marks.first(where: { $0.id == answer.id })
                {
                    return switch mark.kind {
                        case .underline: "Handwritten underline"
                        case .strike: "Handwritten strike-through"
                        case .circle: "Circled words"
                        case .bracket: "Handwritten bracket"
                        case .highlight: "Handwritten highlight"
                    }
                }
                return "Handwritten note"
        }
    }

    private func excerpt(_ excerpt: InkRepairExcerpt) -> some View {
        (Text(excerpt.before) + Text(excerpt.match).bold().foregroundColor(.accentColor)
            + Text(excerpt.after))
            .font(.subheadline)
            .lineLimit(4)
    }

    private func confidence(_ shown: Shown) -> String {
        if shown.candidates > 1 {
            return
                "These words appear \(shown.candidates) times in the chapter; this is the one nearest where it was."
        }
        if shown.score >= 1 { return "Same words as before." }
        return "Close match: \(Int((shown.score * 100).rounded()))% of the words are here."
    }

    @ViewBuilder
    private func actions(_ item: Item) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons(item) }
            VStack(alignment: .leading) { buttons(item) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isCommitting || pendingInkRepair != nil || session.hasPendingChanges)
    }

    @ViewBuilder
    private func buttons(_ item: Item) -> some View {
        if suggestion(item) != nil {
            Button("Attach here") { Task { await accept(item) } }
                .buttonStyle(.borderedProminent)
            Button("Show in book") {
                dismiss()
                Task {
                    // Let the sheet close first so the marked words are visible.
                    try? await Task.sleep(for: .milliseconds(350))
                    await show(item)
                }
            }
        }
        if case .ink(let answer) = item.kind, answer.kind == "note" {
            Button("Attach to current page") {
                Task { await attachToPage(item, noteID: answer.id) }
            }
        }
        Button("Delete", role: .destructive) { pendingDelete = item }
    }

    // MARK: Actions

    private func accept(_ item: Item) async {
        guard !isCommitting, pendingInkRepair == nil else { return }
        isCommitting = true
        defer { isCommitting = false }
        switch item.kind {
            case .ink(let answer):
                guard let original = item.checkedInk else { return }
                // Keep the row through renderer-driven reloads while the write is outstanding.
                pendingInkRepair = item
                do {
                    switch try await AnnotationRepairCommands.commitInk(
                        session: session, href: item.href, answer: answer, expected: original
                    ) {
                        case .saved:
                            pendingInkRepair = nil
                            remove(item)
                        case .pending(let failure): notice = failure.message
                    }
                } catch {
                    pendingInkRepair = nil
                    notice = error.localizedDescription
                }
            case .highlight(let id, let answer):
                guard let suggestion = answer.suggestion, let checked = item.checkedHighlight
                else { return }
                if await viewModel.relocateHighlight(id: id, to: suggestion, checked: checked) {
                    remove(item)
                } else {
                    notice = viewModel.highlightPersistenceError
                }
        }
    }

    private func retrySave() async {
        guard !isCommitting else { return }
        let item = pendingInkRepair
        isCommitting = true
        defer { isCommitting = false }
        guard await session.retrySave() else {
            notice = "The change could not be saved. Your edit is still retained; retry or export recovery from the reader."
            return
        }
        pendingInkRepair = nil
        if let item { remove(item) }
        notice = nil
    }

    private func finishInkChange(_ item: Item) async {
        guard await session.flush() else {
            notice = "The change could not be saved. Your edit is retained. Retry Save or export recovery from the reader."
            return
        }
        pendingInkRepair = nil
        remove(item)
    }

    private func show(_ item: Item) async {
        switch item.kind {
            case .ink(let answer):
                guard let suggestion = answer.suggestion,
                    let start = suggestion.anchor ?? suggestion.start
                else { return }
                await viewModel.showRepairPlace(
                    href: item.href,
                    start: start,
                    end: suggestion.end,
                    cfi: suggestion.cfi
                )
            case .highlight(_, let answer):
                guard let suggestion = answer.suggestion else { return }
                await viewModel.showRepairPlace(
                    href: suggestion.href ?? item.href,
                    start: suggestion.start,
                    end: suggestion.end,
                    cfi: suggestion.cfi
                )
        }
    }

    private func delete(_ item: Item) async {
        guard !isCommitting, pendingInkRepair == nil else { return }
        isCommitting = true
        defer { isCommitting = false }
        switch item.kind {
            case .ink(let answer):
                pendingInkRepair = item
                if session.deleteInk(href: item.href, id: answer.id) {
                    await finishInkChange(item)
                } else { pendingInkRepair = nil }
            case .highlight(let id, _):
                guard let highlight = viewModel.highlights.first(where: { $0.id == id }) else {
                    return
                }
                await viewModel.deleteHighlight(highlight)
                if !viewModel.hasPendingHighlightChanges,
                    !viewModel.highlights.contains(where: { $0.id == id })
                { remove(item) }
        }
    }

    private func attachToPage(_ item: Item, noteID: String) async {
        guard !isCommitting, pendingInkRepair == nil else { return }
        isCommitting = true
        defer { isCommitting = false }
        pendingInkRepair = item
        switch await session.attachNoteToCurrentPage(href: item.href, noteID: noteID) {
            case .attached:
                await finishInkChange(item)
            case .otherSection:
                pendingInkRepair = nil
                notice =
                    "The page you’re on is in a different chapter. Go to a page in \(viewModel.chapterLabel(forHref: item.href) ?? "the note’s chapter") first."
            case .noText:
                pendingInkRepair = nil
                notice = "There are no words on the page you’re on to attach the note to."
            case .unchanged:
                pendingInkRepair = nil
        }
    }

    private func remove(_ item: Item) {
        items[item.href]?.removeAll { $0.id == item.id }
    }

    private func load() async {
        var loaded: [String: [Item]] = [:]
        for href in session.orphans.keys {
            // "missing" means the page no longer has it (already fixed or deleted).
            let checked = session.section(href)
            loaded[href, default: []] += await session.repairSuggestions(href: href)
                .filter { $0.kind != "missing" }
                .map { Item(href: href, kind: .ink($0), checkedInk: checked) }
        }
        let checkedHighlights = viewModel.highlights
        for (sectionIndex, answers) in await viewModel.highlightRepairSuggestions() {
            guard let href = viewModel.bookStructure[safe: sectionIndex]?.id else { continue }
            loaded[href, default: []] += answers.compactMap { answer in
                UUID(uuidString: answer.id).map { id in
                    Item(href: href, kind: .highlight(id, answer),
                         checkedHighlight: checkedHighlights.first(where: { $0.id == id }))
                }
            }
        }
        if let pendingInkRepair {
            loaded[pendingInkRepair.href, default: []].removeAll { $0.id == pendingInkRepair.id }
            loaded[pendingInkRepair.href, default: []].append(pendingInkRepair)
        }
        items = loaded
        loadFoundNothing = loaded.values.allSatisfy(\.isEmpty)
        isLoading = false
    }
}
#endif
