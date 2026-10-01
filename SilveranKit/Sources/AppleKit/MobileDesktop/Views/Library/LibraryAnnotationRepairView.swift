#if os(iOS) || os(macOS)
import SwiftUI

/// Library-wide placement review; quotations preview each proposed target before confirmation.
struct LibraryAnnotationRepairView: View {
    let book: AnnotationBookSummary
    let title: String
    let category: LocalMediaCategory
    let onReviewed: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: AnnotationPlacementReview?
    @State private var inspector = AnnotationBookInspector()
    @State private var issues: [AnnotationPlacementIssue] = []
    @State private var checking = true
    @State private var checked = 0
    @State private var total = 0
    @State private var errorMessage: String?
    @State private var saving: String?
    @State private var generation = 0
    @State private var manualHighlight: Highlight?
    /// Chapter names by href from the edition's spine/TOC, for section headers.
    @State private var chapterNames: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if checking {
                    VStack(spacing: 16) {
                        ProgressView(
                            total > 0
                                ? "Checking chapters \(checked) of \(total)…" : "Preparing book…"
                        )
                        Text("Your reading position and annotations stay unchanged while checking.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(
                                .center
                            )
                    }.padding()
                } else if issues.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        "All Annotations Are Placed",
                        systemImage: "checkmark.circle",
                        description: Text("Checked every annotated chapter in \(title).")
                    )
                } else {
                    List {
                        Section {
                            Text(
                                "Review each passage before attaching. Annotations with no suggested place stay kept for later."
                            )
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(issues) { issue in
                            Section {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(
                                        issue.kind == "note"
                                            ? "Handwritten note"
                                            : issue.kind == "mark"
                                                ? "Ink mark" : "Highlight or bookmark"
                                    )
                                    .font(.headline)
                                    if issue.verificationRequired == true {
                                        Text(
                                            "This older annotation has no verified edition. Confirm its passage to preserve verified placement for future editions."
                                        )
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    if let original = book.entries.first(where: {
                                        $0.id == issue.id || $0.id.hasSuffix(issue.id)
                                    }) {
                                        if !original.strokes.isEmpty {
                                            StrokeThumbnail(strokes: original.strokes)
                                                .frame(maxWidth: .infinity).frame(height: 90)
                                                .accessibilityLabel("Original handwriting")
                                        }
                                        if let quote = original.quote, !quote.isEmpty {
                                            Text("Original: \(quote)").font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let note = original.note, !note.isEmpty {
                                            Text(note).font(.subheadline)
                                        }
                                    }
                                    if let excerpt = issue.excerpt {
                                        Text("Suggested passage").font(.caption).foregroundStyle(
                                            .secondary
                                        )
                                        (Text(excerpt.before) + Text(excerpt.match).bold()
                                            + Text(excerpt.after))
                                            .textSelection(.enabled)
                                        if issue.candidates > 1 {
                                            Label(
                                                "This passage occurs \(issue.candidates) times. Verify the surrounding words.",
                                                systemImage: "exclamationmark.triangle"
                                            )
                                            .font(.subheadline).foregroundStyle(.orange)
                                        }
                                        Button(
                                            issue.verificationRequired == true
                                                ? "Confirm This Passage" : "Attach to This Passage"
                                        ) {
                                            Task { await accept(issue) }
                                        }
                                        .disabled(saving != nil)
                                    } else {
                                        Text(
                                            issue.missingChapter == true
                                                ? "This chapter isn't in the downloaded edition. The annotation is kept."
                                                : issue.kind == "highlight"
                                                    ? "No reliable suggestion found. Choose a chapter and passage; the original annotation is kept."
                                                    : "No reliable suggestion found. The annotation is kept; open the book to choose a passage manually."
                                        )
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    if issue.kind == "highlight",
                                        let original = review?.highlights.first(where: {
                                            $0.id.uuidString == issue.id
                                        })
                                    {
                                        Button("Choose a Chapter and Passage…") {
                                            manualHighlight = original
                                        }
                                        .disabled(saving != nil)
                                    }
                                    if saving == issue.id { ProgressView("Saving repair…") }
                                }.padding(.vertical, 4)
                            } header: {
                                Text(chapterHeader(issue.href))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Check & Repair")
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage).font(.subheadline).foregroundStyle(.red)
                        HStack {
                            Button("Check Again") { generation += 1 }
                                .disabled(saving != nil)
                            if review?.pendingRepairID != nil {
                                Button("Retry Save") { Task { await retrySave() } }
                                    .disabled(saving != nil)
                            }
                        }
                    }.padding().background(.regularMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(checking ? "Cancel" : "Done") { dismiss() }
                        .disabled(saving != nil)
                }
            }
            .task(id: generation) { await check() }
            .sheet(item: $manualHighlight) { original in
                AnnotationPassageChoiceView(original: original, category: category) {
                    issue,
                    destination in
                    try await save(issue, confirmingDestinationHref: destination)
                }
            }
            .onDisappear {
                inspector.close()
                review?.close()
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 520)
        #endif
    }

    private func check() async {
        checking = true
        checked = 0
        total = 0
        errorMessage = nil
        issues = []
        let owner = review ?? AnnotationPlacementReview(bookID: book.bookID, category: category)
        review = owner
        do {
            try await owner.prepare()
            let chapters = try await inspector.open(bookID: book.bookID, category: category)
            let order = Dictionary(uniqueKeysWithValues: chapters.map { ($0.href, $0.index) })
            chapterNames = Dictionary(chapters.map { ($0.href, $0.displayName) }) { first, _ in first }
            let hrefs = owner.hrefs.sorted {
                (order[$0] ?? Int.max, $0) < (order[$1] ?? Int.max, $1)
            }
            total = hrefs.count
            var found: [AnnotationPlacementIssue] = []
            for href in hrefs {
                try Task.checkCancellation()
                let answer = try await inspector.inspect(
                    href: href,
                    ink: owner.ink.sections[href] ?? SectionInk(),
                    highlights: owner.highlights.filter { $0.locator.href == href }
                )
                found += answer.missing ? owner.missingChapter(href) : answer.items
                checked += 1
            }
            try Task.checkCancellation()
            issues = found
            onReviewed(found.count)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        inspector.close()
        checking = false
    }

    /// The chapter's name in this edition; otherwise the name saved with the annotation, marked
    /// as missing, and only then the file name.
    private func chapterHeader(_ href: String) -> String {
        if let name = chapterNames[href] { return name }
        let file = href.removingPercentEncoding ?? href
        let saved = review?.highlights.first { $0.locator.href == href }?.locator.title
        if let saved, !saved.isEmpty { return "\(saved) (not in this edition)" }
        return chapterNames.isEmpty ? file : "\(file) (not in this edition)"
    }

    private func accept(_ issue: AnnotationPlacementIssue) async {
        do { try await save(issue) } catch { errorMessage = error.localizedDescription }
    }

    private func save(
        _ issue: AnnotationPlacementIssue,
        confirmingDestinationHref: String? = nil
    ) async throws {
        guard let review else {
            throw AnnotationPersistenceFailure(message: "Check placement again before attaching.")
        }
        saving = issue.id
        defer { saving = nil }
        try await review.accept(issue, confirmingDestinationHref: confirmingDestinationHref)
        issues.removeAll { $0.id == issue.id }
        errorMessage = nil
        onReviewed(issues.count)
    }

    private func retrySave() async {
        guard let review, let id = review.pendingRepairID else { return }
        saving = id
        defer { saving = nil }
        if await review.retrySave() {
            issues.removeAll { $0.id == id }
            errorMessage = nil
            onReviewed(issues.count)
        }
    }
}
#endif
